#!/usr/bin/env python3
"""Annotate the model-download Job's pod with karpenter.sh/do-not-disrupt in the
vendored aws-samples/sample-genai-on-eks Terraform.

WHY
---
Measured live on 2026-09-04 (DIAGNOSTICS9.md). Six minutes into a 9.7GB
HuggingFace pull, Karpenter consolidated the node out from under it:

    DisruptionTerminating  node/i-<redacted>         Disrupting Node: Underutilized
    Evicted                pod/model-download-gf247  Evicted pod: Underutilized
    Killing                pod/model-download-gf247  Stopping container download
    SuccessfulCreate       job/model-download        Created pod: model-download-d79px

...to save $0.20/hr.

The Job's pod template mounts nothing:

    Mounts:  <none>
    Volumes: <none>

so the model is written to the container's ephemeral filesystem. Eviction
therefore destroys ALL progress, and the replacement pod restarts the download
from zero. This is not a slow path -- it is an unwinnable loop:

  * the download needs tens of minutes on an unauthenticated HF pull
    (the Job sets no HF_TOKEN, so it is rate-limited by design)
  * a node running one batch pod looks "Underutilized" to consolidation within
    a few minutes
  * `activeDeadlineSeconds: 3600` is measured from JOB creation, not pod start,
    so every restart is charged against the same one-hour budget

Left alone, the Job churns pods until the deadline kills it. Nothing about this
looks like a failure while it happens: `kubectl get job` reads `Running 0/1` the
entire time, and the pod reads `1/2 NotReady`, which is also what a healthy run
looks like.

THE FIX
-------
`karpenter.sh/do-not-disrupt: "true"` on the POD (not the node) is the
documented way to tell Karpenter not to voluntarily disrupt a workload. It is
scoped to this pod, it does not disable consolidation for the cluster, and it
stops applying the moment the Job's pod terminates -- so the node is free to be
consolidated as soon as the download is done. The annotation goes on the Job's
pod TEMPLATE so that every retry pod inherits it.

Upstream has no `do-not-disrupt` anywhere in its Terraform, and the Job's pod
template has no `metadata:` block at all -- so this inserts one.

Note this fixes only the VOLUNTARY disruption. A spot interruption or a node
failure would still lose the download, because the real structural fix is a
volume that outlives the pod. That is a larger change to upstream's storage
model and is deliberately out of scope here.

SAFETY
------
The exact upstream shape is asserted before editing: a `template:` line followed
IMMEDIATELY by `spec:` (i.e. no existing metadata block to merge into). If the
pinned tag moves and upstream adds pod metadata -- including adding this
annotation themselves -- this fails loudly rather than producing a duplicate or
malformed key. Idempotent: a template that already carries the annotation is
left alone.

Usage: fix_download_disruption.py <terraform dir>
Exit 0 = patched or already patched, 1 = upstream drifted.
"""
import glob
import os
import sys

TEMPLATE = "      template:"
SPEC = "        spec:"
ANNOTATION = '            karpenter.sh/do-not-disrupt: "true"'
INSERT = ["        metadata:", "          annotations:", ANNOTATION]

# Only touch the file that holds the model-download Job.
JOB_MARKER = "      name: model-download"


def patch(lines):
    """Return (new_lines, status). status: 'patched' | 'already' | reason string."""
    if ANNOTATION in lines:
        return lines, "already"
    if any("do-not-disrupt" in ln for ln in lines):
        return lines, ("a do-not-disrupt annotation already exists but not in the "
                       "expected form -- upstream may have fixed this differently")

    if TEMPLATE not in lines:
        return lines, f"no {TEMPLATE.strip()!r} line in the Job"
    t = lines.index(TEMPLATE)
    if lines.count(TEMPLATE) > 1:
        return lines, f"{TEMPLATE.strip()!r} appears more than once"
    if t + 1 >= len(lines) or lines[t + 1] != SPEC:
        found = lines[t + 1].strip() if t + 1 < len(lines) else "<end of file>"
        return lines, (f"expected {SPEC.strip()!r} immediately after "
                       f"{TEMPLATE.strip()!r}, found {found!r} -- the pod template "
                       f"already has metadata to merge into")

    return lines[:t + 1] + INSERT + lines[t + 1:], "patched"


def main():
    if len(sys.argv) != 2:
        print("Usage: fix_download_disruption.py <terraform dir>", file=sys.stderr)
        return 1
    tf_dir = sys.argv[1]

    hits = []
    for f in sorted(glob.glob(os.path.join(tf_dir, "*.tf"))):
        lines = open(f).read().split("\n")
        if JOB_MARKER in lines:
            hits.append((f, lines))

    def drift(msg):
        print("Download-disruption patch does not match upstream:", file=sys.stderr)
        print(f"  {msg}", file=sys.stderr)
        print("Reconcile scripts/lib/fix_download_disruption.py against the pinned tag.",
              file=sys.stderr)
        return 1

    if not hits:
        return drift(f"no .tf file in {tf_dir} contains the model-download Job "
                     f"(looked for the line {JOB_MARKER.strip()!r})")
    if len(hits) > 1:
        return drift(f"expected exactly one model-download Job, found {len(hits)}: "
                     f"{[os.path.basename(f) for f, _ in hits]}")

    path, lines = hits[0]
    new_lines, status = patch(lines)

    if status == "already":
        print("  (model-download pod already annotated do-not-disrupt)")
        return 0
    if status != "patched":
        return drift(f"{os.path.basename(path)}: {status}")

    open(path, "w").write("\n".join(new_lines))
    print(f"  + karpenter.sh/do-not-disrupt -> model-download pod template "
          f"({os.path.basename(path)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
