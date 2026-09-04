#!/usr/bin/env python3
"""Make `validate-pod-identity` an initContainer in the model-download Job of the
vendored aws-samples/sample-genai-on-eks Terraform.

WHY
---
Measured live on 2026-09-04 (DIAGNOSTICS9.md). The model-download pod came up as:

    default   model-download-n2mgs   1/2   Error   0   8m3s

and its validator said:

    aws: [ERROR]: An error occurred (NoCredentials): Unable to locate credentials.
    Expected role: genai-model-storage-role
    Current role:
    ERROR: Pod Identity not working. Using node role instead of Pod Identity role.
    Pod will be recreated to retry Pod Identity association.

The pod was NOT recreated. It ran for another 40 minutes and would have failed at
the very end, after downloading ~16GB.

THE RACE (which is NOT a missing depends_on)
--------------------------------------------
EKS Pod Identity injects credentials through a mutating admission webhook that
looks up an existing association AT POD ADMISSION. The injection is a one-shot
decision: a pod admitted before the association is visible never gets an
`eks-pod-identity-token` volume, and no amount of waiting inside that pod fixes
it. The broken pod's only volume was `kube-api-access-n86th`.

Upstream ALREADY has the dependency edge -- `aws_eks_pod_identity_association
.model_storage` is in the Job's depends_on -- so this is not the destroy-order
bug in a new costume. The edge is honored and still insufficient, because
CreatePodIdentityAssociation returns before the association is visible to the
admission path. Measured on the failing run:

    association createdAt   2026-09-04T14:46:23.141Z
    job/pod creationTimestamp 2026-09-04T14:46:23Z     (same second)

Terraform did the right thing in the right order and lost by milliseconds. There
is no ordering fix available in Terraform for an API that is eventually
consistent behind its own success response; the retry has to live in the Job.

WHY THE UPSTREAM RETRY CANNOT FIRE
----------------------------------
Upstream anticipated exactly this -- hence "Pod will be recreated to retry Pod
Identity association" and `backoffLimit: 10`. But `validate-pod-identity` is a
SIBLING container of `download` under `restartPolicy: Never`. A Job only creates
a replacement pod once the current pod FAILS, and a pod only fails when ALL of
its containers terminate. `download` keeps running for the length of a ~16GB
HuggingFace pull, so the pod stays Running, the Job never retries, and
`backoffLimit: 10` is dead code. The validator detects the fault correctly and
is structurally unable to act on it.

THE FIX
-------
Move the validator to `initContainers`. Two things then work:

  1. It GATES the download instead of racing beside it -- a pod with no
     credentials burns ~3 seconds, not ~40 minutes of bandwidth.
  2. Its exit 1 fails the POD, so the Job's existing backoffLimit: 10 finally
     does what it was written to do. Job backoff is 10s, 20s, 40s... which is
     orders of magnitude more than the propagation window needs, and stays well
     inside the Job's activeDeadlineSeconds: 3600.

No behavior is changed on a cluster that does not hit the race: the validator
still runs first, still checks the same thing, and still exits 0.

SAFETY
------
The exact upstream container ordering is asserted before editing (validator
first, download second, both under one `containers:` key). If the pinned tag
moves and upstream restructures the Job -- including fixing this themselves --
this fails loudly rather than patching something it no longer understands.
Idempotent: a manifest that already has initContainers is left alone.

Usage: fix_pod_identity_race.py <terraform dir>
Exit 0 = patched or already patched, 1 = upstream drifted.
"""
import glob
import os
import sys

# The exact upstream lines, in order. Anchors, not a regex, so any upstream
# restructuring of this Job trips the assertion instead of being silently
# mangled.
CONTAINERS = "          containers:"
VALIDATOR = "            - name: validate-pod-identity"
DOWNLOAD = "            - name: download"
INITCONTAINERS = "          initContainers:"


def patch(lines):
    """Return (new_lines, status). status: 'patched' | 'already' | reason string."""
    if INITCONTAINERS in lines:
        return lines, "already"

    for label, anchor in (("containers:", CONTAINERS),
                          ("the validator", VALIDATOR),
                          ("the download container", DOWNLOAD)):
        if anchor not in lines:
            return lines, f"{label} not found (expected the line {anchor.strip()!r})"
    c, v, d = lines.index(CONTAINERS), lines.index(VALIDATOR), lines.index(DOWNLOAD)

    # The validator must be the FIRST entry under containers:, and download must
    # come after it. Anything else means the Job was restructured upstream.
    if v != c + 1:
        return lines, (
            f"'{VALIDATOR.strip()}' is not the first entry under containers: "
            f"(containers: at line {c + 1}, validator at line {v + 1})"
        )
    if d <= v:
        return lines, "'- name: download' does not follow the validator"

    out = lines[:c] + [INITCONTAINERS] + lines[v:d] + [CONTAINERS] + lines[d:]
    return out, "patched"


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 1
    tf_dir = sys.argv[1]

    hits = []
    for f in sorted(glob.glob(os.path.join(tf_dir, "*.tf"))):
        lines = open(f).read().split("\n")
        if VALIDATOR in lines or (INITCONTAINERS in lines and DOWNLOAD in lines):
            hits.append((f, lines))

    if not hits:
        print("Pod-identity-race patch does not match upstream:", file=sys.stderr)
        print(f"  no .tf file in {tf_dir} contains "
              f"'{VALIDATOR.strip()}'", file=sys.stderr)
        print("Reconcile scripts/lib/fix_pod_identity_race.py against the pinned tag.",
              file=sys.stderr)
        return 1
    if len(hits) > 1:
        print("Pod-identity-race patch does not match upstream:", file=sys.stderr)
        print(f"  expected exactly one Job with this validator, found "
              f"{len(hits)}: {[os.path.basename(f) for f, _ in hits]}", file=sys.stderr)
        return 1

    path, lines = hits[0]
    new_lines, status = patch(lines)

    if status == "already":
        print("  (validate-pod-identity already an initContainer)")
        return 0
    if status != "patched":
        print("Pod-identity-race patch does not match upstream:", file=sys.stderr)
        print(f"  {os.path.basename(path)}: {status}", file=sys.stderr)
        print("Reconcile scripts/lib/fix_pod_identity_race.py against the pinned tag.",
              file=sys.stderr)
        return 1

    open(path, "w").write("\n".join(new_lines))
    print(f"  + validate-pod-identity -> initContainers "
          f"({os.path.basename(path)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
