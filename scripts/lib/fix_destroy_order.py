#!/usr/bin/env python3
"""Add `module.vpc` to the depends_on of the Kubernetes-layer roots in the
vendored aws-samples/sample-genai-on-eks Terraform.

WHY
---
`terraform destroy` tore down module.vpc's NAT gateway, public subnets and
internet gateway *concurrently* with `kubernetes_namespace_v1.monitoring`, then
failed:

    kubernetes_namespace_v1.monitoring: Still destroying... [04m50s elapsed]
    Error: context deadline exceeded

Terraform destroys in reverse dependency order, but its graph is per-resource,
not per-module. Upstream, every cluster-facing resource roots at `module.eks`,
and module.eks depends only on module.vpc's *subnets*. The NAT gateway, EIP,
IGW and public subnets have no dependents at all, so Terraform treats them as
leaves and destroys them immediately -- in parallel with a Kubernetes layer that
is still making API calls through them. Pulling a cluster's egress out from
under a namespace that is still finalizing is what produced the timeout.

Adding the edge inverts to: every Kubernetes-layer resource is destroyed before
ANY VPC resource. Five roots cover all 31 cluster-facing resources transitively
(see ROOTS below).

Direction matters: it MUST be k8s-resource -> module.vpc. The reverse is a
cycle, since module.eks already depends on module.vpc and all of these depend
on module.eks.

WHY NOT AN OVERRIDE FILE
------------------------
The obvious approach -- a `*_override.tf` -- does not work. Terraform rejects it
outright: "The depends_on argument may not be overridden." So the vendored files
are edited in place instead, which means the edit must be re-applied after every
re-clone (00-clone-terraform.sh does this) and must be safe to re-run.

SAFETY
------
Each resource's CURRENT upstream depends_on is asserted before editing. If the
pinned tag moves and upstream changes one of these lists, this fails loudly
rather than patching something it no longer understands. Idempotent: a list that
already contains module.vpc is left alone.

Usage: fix_destroy_order.py <terraform dir>
Exit 0 = patched or already patched, 1 = upstream drifted.
"""
import glob
import os
import re
import sys

ADDED = "module.vpc"

# A second, INDEPENDENT destroy race, measured 2026-09-04 on the first real
# teardown (DIAGNOSTICS9.md, Postscript 10). The module.vpc edges above worked --
# no VPC resource was destroyed alongside the namespace this time -- but the run
# still ended in `context deadline exceeded`, from a different cause:
#
#   kubectl_manifest.karpenter_node_pool_gpu: Still destroying... [05m38s elapsed]
#   kubernetes_namespace_v1.monitoring:       Still destroying... [04m50s elapsed]
#   Error: context deadline exceeded
#
# Deleting the GPU NodePool drains and terminates its node. kube-prometheus-stack
# runs node-exporter as a DaemonSet, so there is a pod on that node, and a pod
# whose node disappears mid-termination can sit in Terminating indefinitely --
# observed at 103 minutes. The namespace cannot finalize while any pod remains,
# so it blew Terraform's 5-minute delete timeout.
#
# Fix: destroy the namespace BEFORE the NodePool, so its DaemonSet pods terminate
# on live nodes. Terraform destroys in reverse dependency order, so "namespace
# first" means the namespace must DEPEND ON the nodepool. Acyclic: the nodepool
# depends only on module.eks.
EXTRA = {
    ("kubernetes_namespace_v1", "monitoring"):
        ["kubectl_manifest.karpenter_node_pool_gpu"],
}

# resource address -> the exact depends_on we expect upstream to have.
ROOTS = {
    ("kubernetes_namespace_v1", "monitoring"):
        ["module.eks", "module.eks.cluster_addons"],
    ("kubectl_manifest", "mistral_model_pv"):
        ["module.eks", "module.eks.cluster_addons",
         "aws_s3_bucket.model_storage", "aws_s3_object.model_prefix"],
    ("kubectl_manifest", "model_storage_service_account"):
        ["module.eks", "module.eks.cluster_addons"],
    ("kubectl_manifest", "ingress_class_params"):
        ["module.eks"],
    ("kubectl_manifest", "eks_node_class_gpu"):
        ["module.eks", "module.eks.cluster_addons"],
}


def find_block(text, kind, name):
    """Return (body_start, body_end) of the named resource block, or None."""
    m = re.search(r'resource\s+"%s"\s+"%s"\s*\{' % (kind, name), text)
    if not m:
        return None
    i, depth = m.end(), 1
    while depth and i < len(text):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    return m.end(), i - 1


def main():
    tf_dir = sys.argv[1]
    files = [f for f in glob.glob(os.path.join(tf_dir, "*.tf"))]
    problems, patched, already = [], [], []

    for (kind, name), expected in ROOTS.items():
        label = f"{kind}.{name}"
        hit = None
        for f in files:
            text = open(f).read()
            span = find_block(text, kind, name)
            if span:
                hit = (f, text, span)
                break
        if not hit:
            problems.append(f"  {label}: not found upstream (renamed or removed)")
            continue

        path, text, (bs, be) = hit
        body = text[bs:be]
        d = re.search(r"depends_on\s*=\s*\[(.*?)\]", body, re.S)
        if not d:
            problems.append(f"  {label}: has no depends_on block to extend")
            continue
        deps = [p.strip() for p in d.group(1).split(",") if p.strip()]

        wanted = [ADDED] + EXTRA.get((kind, name), [])
        if all(w in deps for w in wanted):
            already.append(label)
            continue
        if deps != expected:
            problems.append(
                f"  {label}:\n"
                f"      expected upstream = {expected}\n"
                f"      found             = {deps}"
            )
            continue

        new_list = "depends_on = [\n    " + ",\n    ".join(deps + wanted) + ",\n  ]"
        new_body = body[:d.start()] + new_list + body[d.end():]
        open(path, "w").write(text[:bs] + new_body + text[be:])
        patched.append(f"{label} ({os.path.basename(path)}) += {', '.join(wanted)}")

    if problems:
        print("Destroy-order patch does not match upstream:", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        print("Reconcile scripts/lib/fix_destroy_order.py against the pinned tag.",
              file=sys.stderr)
        return 1

    for p in patched:
        print(f"  + {p}")
    if already:
        print(f"  ({len(already)} already patched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
