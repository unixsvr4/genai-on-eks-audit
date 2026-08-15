# Cost Estimate — Full 4-Hour Reproduction

**This is a rough estimate, not a quote.** AWS pricing varies by region and changes over time; the figures below are approximate on-demand rates for `us-east-2` (Ohio, the workshop's own region) based on general pricing knowledge, not a live pricing-API lookup. **Before running anything, verify current rates with the [AWS Pricing Calculator](https://calculator.aws)** and your account's actual quotas/discounts (Savings Plans, EDP, credits, etc. all change this).

This repo will **not** run on the AWS Free Tier — it requires a GPU instance, which the Free Tier does not cover at all.

## Line-item estimate, all 8 modules run once, ~4 hours total wall-clock

| Item | Approx. on-demand rate | 4-hr line cost | Notes |
|---|---|---|---|
| EKS control plane | $0.10/hr | ~$0.40 | Flat per-cluster rate regardless of node count. |
| GPU node — `g6e.2xlarge` (1x NVIDIA L40S, 46GB VRAM), ODCR-backed | ~$2.20–2.30/hr | ~$9.00 | See **"How the ODCR actually bills"** below — this is the dominant cost. |
| CPU nodes — Auto Mode `system`/`general-purpose` pools (2 small instances, auto-sized) | ~$0.10–0.20/hr combined | ~$0.50 | Auto Mode picks instance types; typically small (t3/m5 class) for control-plane-adjacent workloads. |
| `m5.xlarge` nodes — Open WebUI / RAG Gradio UI (CPU, on-demand) | ~$0.192/hr, up to 2 concurrent | ~$1.00 | Only one is usually up at a time in this workshop's sequencing. |
| NAT Gateway (if your VPC routes S3 traffic through it rather than an S3 gateway endpoint) | $0.045/hr + $0.045/GB processed | ~$0.50–2.00 | Model weights are ~10GB; route S3 traffic via a **gateway VPC endpoint** instead to avoid this almost entirely — see gotcha below. |
| ALBs — up to 3 concurrent (Open WebUI, Grafana, RAG Gradio) | ~$0.0225/hr + LCU-hours each | ~$0.30–0.60 | Delete each Ingress as soon as you're done with that module instead of leaving all 3 up for the full 4 hours. |
| ElastiCache Serverless (Valkey) — "External KV Cache" module only | usage-based (GB-hour stored + ECPU-hours) | ~$1–5 | Only exists for the ~15–20 min this one lab needs; **run its own `cleanup-valkey.sh` immediately after**, don't wait for the final teardown. |
| S3 storage (model weights ~10GB, RAG data, S3 Vectors index) | ~$0.023/GB-month | <$0.10 | Trivial at this timescale. |
| ECR storage (Strands agent image) | ~$0.10/GB-month | <$0.05 | Trivial at this timescale. |
| **Estimated total, full run** | | **~$12–20** | Excludes data egress beyond light demo traffic, and assumes you're already within default GPU quota (see below). |

## How the ODCR actually bills (read this before you panic about "double paying")

An **On-Demand Capacity Reservation (ODCR)** for `g6e.2xlarge` bills you the **same on-demand hourly rate for the reserved capacity, whether or not an instance is actually running in it** — but you are **not double-charged** when a matching GPU node *is* running: the instance's own usage billing satisfies the reservation, you don't pay twice. So in practice:

> **Total GPU cost ≈ (hours the ODCR is active) × (g6e.2xlarge on-demand rate)** — regardless of how much of that window the GPU node sits idle between labs.

This means the single biggest cost lever is **how long the ODCR stays active**, not how efficiently you use the GPU within that window. Two mitigations, both already built into `scripts/`:
1. `scripts/01-deploy-infra.sh` creates the ODCR with `--end-date-type limited --end-date "<now + 4h>"` by default (not `unlimited`) — it self-expires even if you forget to cancel it.
2. `scripts/99-destroy-all.sh` cancels it explicitly the moment you're done, same as the workshop's own final cleanup.

**Reminder from the live workshop run** (`RESEARCH.md`, Cleanup): in the *workshop's own* AWS-hosted event, the ODCR lived in a separate AWS-operator account and attendees couldn't cancel it themselves (`UnauthorizedOperation`) — that restriction does **not** apply here, since in your own account you create and own the ODCR, so `cancel-capacity-reservation` will actually work.

## GPU quota — check this before you start

`g6e.2xlarge` requires available quota for the relevant EC2 instance family in your account/region. A brand-new or rarely-used account may default to **0** for GPU instance families. Request an increase (EC2 → Service Quotas → "Running On-Demand G and VT instances" or the specific `g6e` family quota) **before** starting the clock — quota approval can take minutes to hours and isn't something you want burning your 4-hour cost/time window.

## Cheapest way to run this if you just want the "showboat" artifacts, not every lab

You don't need all 8 modules live simultaneously to get good screenshots/demo material:
- **Serve a Model** + **Optimize Inference's DCGM/Grafana dashboards** + **Agentic App** gets you the core "LLM on GPU on EKS" story with real metrics — skip RAG/Customize-Model/Inference-Frameworks if you're short on time or budget, since each spins up its own extra ALB/PV/S3 resources.
- The **External KV Cache (Valkey)** module is the single most expensive optional lab relative to its demo value — its ElastiCache Serverless cost accrues the whole time it exists, independent of the GPU. Run it last, right before final teardown, and tear its own resources down first via `scripts/09-teardown-external-kv-cache.sh`.

## Checking what you're actually spending mid-run

Everything above is a *pre-run estimate* for a clean 4-hour pass. If you've hit failures and spent real time troubleshooting (see `DIAGNOSTICS0.md`-`DIAGNOSTICS4.md` for a real example — a multi-hour live debugging session, not a 4-hour demo), run `scripts/real_cost_of_cluster.sh` for a live number: it reads actual resource creation timestamps (EKS cluster, GPU ODCR, EC2 instances, NAT Gateways, ALBs) and multiplies by the same approximate rates used above, so it reflects how long things have *actually* been running, not a hypothetical. It's read-only and safe to run anytime. For the authoritative (but delayed, usually 8-24h) number, it also prints the AWS Cost Explorer command at the end.

## Full-teardown safety net

`scripts/99-destroy-all.sh` runs the exact reverse of every deploy script, then `terraform destroy` for the base infrastructure. `scripts/schedule-auto-destroy.sh` sets a local `at`-based timer as a **best-effort** backstop (see its header comment for why this is not a substitute for the ODCR's own `--end-date-type limited` expiry, and not a substitute for you actually watching the clock — a local timer only fires if your machine stays on and awake).
