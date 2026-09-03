# GenAI on Amazon EKS — full reproduction, gotchas, and cost breakdown

A complete, scripted reproduction of AWS's hands-on workshop **"Building and Scaling GenAI Workloads with Amazon EKS"** (catalog title: *Generative AI on Amazon EKS using NVIDIA GPU*, complexity 400) — plus everything the workshop *doesn't* tell you: the exact failure modes hit along the way, a real cost estimate, and a from-scratch deploy path for your own AWS account.

This isn't a slide-deck summary. Every command in this repo's `scripts/` was verified against real command output from a live 4-hour run of the workshop, captured verbatim in [`RESEARCH.md`](./RESEARCH.md) — including the parts that broke.

![Complete architecture](./images/14-architecture-complete-7-agentic.png)

## What this actually deploys

Ministral-3-8B-Instruct-2512 served on vLLM via **EKS Auto Mode**, on the same `g6e.2xlarge` (1x NVIDIA L40S, 46GB VRAM) instance type the workshop uses — streamed straight from S3, no manual GPU driver install, no manually-picked AMI (Auto Mode selects its own Bottlerocket GPU variant, same as the workshop). On top of that:

- **Real GPU observability**: DCGM Exporter + Grafana, not just `nvidia-smi`
- **KV-cache tiering with LMCache**: CPU-RAM L1 (3.2x TTFT win) and a cross-pod L2 via ElastiCache Serverless Valkey (proved a cache hit survives `kubectl delete pod`)
- **An agentic tool-calling app** (Strands) calling the model's OpenAI-compatible tool-calling API
- **Load-tested to its actual saturation point** — not a guess: TTFT roughly doubles once you cross ~17-20 req/s on one GPU, verified live
- **LoRA fine-tuning** (successful) and LoRA serving (a real, documented failure mode — see below)
- **RAG** using **Amazon S3 Vectors** as a fully-managed vector store, no self-hosted vector DB
- **Ray Serve/KubeRay** as an alternative serving framework behind the *exact same* API contract — proved by redeploying Open WebUI unmodified against it

## Start here

| Doc | What it's for |
|---|---|
| [`RESEARCH.md`](./RESEARCH.md) | The ground truth — every command + real output from the live 4-hour run, module by module. Everything else in this repo is derived from this file. |
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | The workshop's own presenter diagrams (captured live), annotated against what was actually verified running. |
| [`docs/COST.md`](./docs/COST.md) | Line-item cost estimate (~$12–20 for a full 4-hour run) + how ODCR billing actually works, since it's not intuitive. **Read before running anything — this is not free-tier eligible.** |
| [`docs/GOTCHAS.md`](./docs/GOTCHAS.md) | Every non-obvious failure mode hit live, with citations. |
| [`docs/FIRST_RUN.md`](./docs/FIRST_RUN.md) | Real timing + a live gotcha from actually running `01-deploy-infra.sh` against a fresh account — a quota check `00-prereqs.sh` misses. |
| [`DIAGNOSTICS0.md`](./DIAGNOSTICS0.md) → [`DIAGNOSTICS7.md`](./DIAGNOSTICS7.md) | The full blow-by-blow live debugging trail behind the fresh-account gotcha below — eight rounds from first symptom to root cause to confirmed fix, ending with both account blockers cleared. `00-prereqs.sh` and `01-deploy-infra.sh` now check for these automatically, but read these if you want the whole story or hit something they don't catch. |
| [`PUBLICATION.md`](./PUBLICATION.md) | What was swept from this repo before it was made public, and the two process mistakes that sweep caught. |

## New or Free Tier AWS account? Read this before you start the clock

Most people cloning this will be on a new or lightly-used AWS account, and this repo hit **two separate account-level blockers** on its own first live run — both now caught automatically by `scripts/00-prereqs.sh`, but worth knowing about up front:

1. **GPU instance quota (`g6e.2xlarge`) usually defaults to 0** on a fresh account. `00-prereqs.sh` checks this and, if it's too low, prints the exact command to request an increase:
   ```bash
   aws service-quotas request-service-quota-increase --region us-east-2 --service-code ec2 --quota-code L-DB2E81BA --desired-value 8
   ```
   GPU-family quotas commonly open an AWS Support case for manual review rather than auto-approving instantly — on the account that hit this, it moved to `CASE_OPENED` within a minute and took hours, not minutes. Request it as early as possible.

2. **A separate, undocumented-by-AWS restriction can block launching *any* non-Free-Tier-eligible instance type at all** — not just GPU instances. This one is nastier because it's invisible at the Kubernetes/Terraform layer: `01-deploy-infra.sh` times out after 20 minutes with the S3 CSI driver addon stuck `DEGRADED` and the `kube-prometheus-stack` Helm install hanging, because Karpenter's `general-purpose` NodePool (plain `c5`/`m5`-class instances, nothing GPU-related) churns forever without ever producing a node. The real cause only shows up in a raw CloudTrail `CreateFleet` event body: `errorCode: InvalidParameterCombination`, `"not eligible for Free Tier"`. `00-prereqs.sh` now runs an EC2 dry-run to detect this *before* you start the 20-minute wait. If it fires, there's nothing to fix on your end — it clears via an automatic AWS account-validation process (AWS emails you when it does; took under two hours on the account that hit this). Just wait and re-run `00-prereqs.sh` periodically.

   The full real-time debugging trail — including how genuinely hard this was to pin down (four rounds of diagnostics, three ruled-out wrong hypotheses, before a raw CloudTrail event body revealed the real error) — is in [`DIAGNOSTICS0.md`](./DIAGNOSTICS0.md) through [`DIAGNOSTICS4.md`](./DIAGNOSTICS4.md), plus the summarized version in [`docs/GOTCHAS.md`](./docs/GOTCHAS.md#reproducing-this-repo-in-a-fresh-aws-account).

3. **An interrupted `terraform apply` leaves a Helm release Terraform can't see.** If either blocker above (or anything else) kills an apply partway, Helm may already hold a `kube-prometheus-stack` release record that never made it into Terraform state. The next apply then fails with `Error: installation failed ... cannot re-use a name that is still in use`, which looks like a Terraform bug and isn't. This bit the repo three times; as of `DIAGNOSTICS7.md`, `01-deploy-infra.sh` detects the orphan (failed/pending release **and** absent from `terraform state list`) and clears it automatically. A release Terraform *does* track is deliberately left alone. Manual equivalent:
   ```bash
   helm uninstall kube-prometheus-stack -n monitoring
   ```

**Both account-level blockers above cleared on the reference account on 2026-09-03** — `L-DB2E81BA` granted at 16 vCPUs (two `g6e.2xlarge`), and `c5.large`/`g6e.2xlarge` dry-runs both returning `DryRunOperation`. See [`DIAGNOSTICS7.md`](./DIAGNOSTICS7.md) for the verification commands, and note that the Helm symptom recurred there *without* the Free Tier hold — same surface error, different cause.

## Quickstart

Requires: `aws` CLI (authenticated), `kubectl`, `helm`, `terraform`, `docker`, `jq`, `envsubst`, `curl`, `git`.

```bash
cd scripts
./00-prereqs.sh              # checks tooling + quota, makes no changes
./00-clone-terraform.sh      # vendors AWS's own Terraform at a pinned tag — see terraform/README.md
./01-deploy-infra.sh         # VPC + EKS Auto Mode cluster + GPU NodePool — ~20-25 min, billing starts here
./02-gpu-infrastructure.sh   # ODCR (auto-expires in 4h by default) + GPU NodeClass + nvidia-smi proof
./03-serve-model.sh          # vLLM + Ministral-3-8B, streamed from S3
./04-observability.sh        # DCGM + Grafana + vLLM ServiceMonitor
./05-agentic-app.sh          # Strands weather agent — run BEFORE benchmarking tears down vLLM
./06-benchmarking.sh         # baseline + saturation load tests, then tears down the model deployment
./07-lmcache-cpu.sh          # KV-cache L1 (CPU RAM) — self-contained
./08-lmcache-valkey.sh       # KV-cache L2 (Valkey) — THE ONE MODULE WITH ITS OWN AWS BILL, self-tears-down at the end
./09-customize-model-lora.sh # LoRA fine-tune (works) + LoRA serving (known failure mode, documented, non-blocking)
./10-rag.sh                  # S3 Vectors + RAG service + Gradio comparison UI
./11-inference-frameworks-ray.sh  # Ray Serve/KubeRay, redeploys Open WebUI unchanged against it

# When you're done showboating:
./99-destroy-all.sh          # full teardown, including things the workshop's own at-event
                              # cleanup couldn't do (cancel the ODCR, terraform destroy)
```

Every script's full terminal output is also written to a same-named `.out.txt` in `outputs/` (e.g. `02-gpu-infrastructure.sh` → `outputs/02-gpu-infrastructure.out.txt`, via `scripts/lib/env.sh`) — so a run can be reviewed or shared (e.g. walked through with students) without re-running anything live. Gitignored by default since it captures your own account IDs/ARNs/IPs; commit specific ones deliberately with `git add -f` if you want them in the repo. A rerun overwrites the previous file for that script name — copy or rename one out first if you need to keep it.

Optional safety net: `./schedule-auto-destroy.sh` sets a local timer as a best-effort backstop — **not** a substitute for the ODCR's own `--end-date-type limited` auto-expiry (the real cost safety net, on by default) or for you actually watching the clock. See its header comment.

Want to know what you're actually spending right now, mid-run? `./real_cost_of_cluster.sh` reads live AWS resource timestamps (not a hypothetical 4-hour estimate) and prints a running total — useful after a long troubleshooting session, not just a clean 4-hour demo.

## Repo layout

```
RESEARCH.md              live-session debug trail — the source of truth for everything else
docs/
  ARCHITECTURE.md         workshop diagrams + verified architecture
  COST.md                 line-item estimate + ODCR billing explainer
  GOTCHAS.md              every failure mode, with citations
images/                  14 captured presenter slides (2 excluded — 1 blank, 1 showed a live access code)
terraform/README.md      why we vendor AWS's Terraform instead of rewriting it
scripts/                 numbered deploy scripts, one per module, run in order
  real_cost_of_cluster.sh live cost estimate from actual resource timestamps (read-only)
  schedule-auto-destroy.sh local best-effort auto-teardown timer (see its own header comment)
  lib/env.sh              shared config (region, instance type, tags — override via env vars)
outputs/                 gitignored (except README.md) — every script's full terminal
                          output, same basename as the script that produced it (see below)
manifests/               populated at runtime by the scripts (gitignored — fetched fresh, tag-pinned, each run)
```

## What this repo deliberately does NOT do

- **It doesn't run anything for you.** No `terraform apply` has been executed as part of building this repo — every script here is meant for *you* to run, in *your* AWS account, on *your* schedule, so you control exactly when the cost clock starts. See `docs/COST.md` first.
- **It doesn't vendor AWS's Terraform code.** `scripts/00-clone-terraform.sh` clones it fresh at a pinned tag instead — see `terraform/README.md`.
- **It doesn't hide the failures.** The LoRA-serving step has a real, documented failure mode (an IAM-credential dependency baked into how the Mountpoint-for-S3 CSI driver mounts a PersistentVolume) — `scripts/09-customize-model-lora.sh` runs it anyway and tells you exactly what to check if it hangs, rather than quietly working around it.

## Credit

Built on AWS's own `aws-samples/sample-genai-on-eks` workshop content and Terraform. This repo adds: the live-verified debug trail, cost analysis, gotcha documentation, and orchestration scripts — not a reimplementation of AWS's underlying infrastructure code.
