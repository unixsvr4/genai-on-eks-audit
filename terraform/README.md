# terraform/ — why this directory is (mostly) empty

This repo **vendors AWS's own Terraform** for the base infrastructure rather than reimplementing it. Two reasons:

1. **Accuracy.** The workshop's self-paced path already ships a Terraform module tree (`github.com/aws-samples/sample-genai-on-eks/terraform`) that provisions the exact VPC + EKS Auto Mode cluster + GPU NodePool/NodeClass + observability stack + S3 model bucket this whole reproduction depends on. Rewriting that from scratch risks drifting from what the workshop (and this repo's `RESEARCH.md`) actually verified.
2. **Staying in sync.** AWS maintains and patches that module tree. Vendoring by reference (pinned tag, cloned at deploy time) means security fixes and Auto Mode API changes upstream reach this repo without us maintaining a fork.

`scripts/00-clone-terraform.sh` clones it into `.deploy/sample-genai-on-eks/` (gitignored — not committed to this repo) at a **pinned tag**, and every deploy script afterward operates against that clone plus this repo's own `manifests/` fetches (also curl'd at pinned tags — see `RESEARCH.md` for the tag used by each specific manifest).

## What this repo adds on top of the vendored Terraform

- `scripts/01-deploy-infra.sh` — runs `terraform apply`, then (unlike the plain self-paced instructions) creates the GPU ODCR with `--end-date-type limited` by default so it self-expires, and patches the GPU NodeClass to use it — see [`docs/COST.md`](../docs/COST.md) for why this matters.
- `scripts/02` through `scripts/10` — reproduce each workshop module in the exact order and with the exact tag-pinned manifest URLs verified live in `RESEARCH.md`, with inline comments calling out every gotcha from [`docs/GOTCHAS.md`](../docs/GOTCHAS.md) at the point it applies.
- `scripts/99-destroy-all.sh` — the real teardown, including things the workshop's own at-event cleanup couldn't do (cancel the ODCR — see `docs/COST.md` for why that failed in the live event and why it won't fail here).

## Pinned tag

```
TERRAFORM_TAG=v2.5.2
```

Set in `scripts/lib/env.sh`. This is the newest tag referenced anywhere in the live session's manifest fetches (`RESEARCH.md` records tags from `v2.3.1` through `v2.5.2` used across different modules — see `docs/GOTCHAS.md` "General workshop-repo hygiene" for why that inconsistency exists upstream). If you bump this tag, **re-check every manifest URL in `scripts/`** against the new tag's directory layout before running anything — the upstream repo has reorganized its manifest paths between the tags seen in this workshop (e.g. `100-vllm/` vs `600-finetuning/` vs `500-lmcache/` are not all guaranteed stable across tags).

## Manual alternative

If you'd rather not run `terraform apply` unattended, the exact manual commands are in `RESEARCH.md` §1 "Getting Started → Self-paced path" — same clone, same `terraform init && terraform apply`, same `aws eks update-kubeconfig`.
