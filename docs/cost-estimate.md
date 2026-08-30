# Cost Estimate

Rough, order-of-magnitude numbers for `us-east-1`, based on the instance sizes actually set in `terraform/live/main.tf`'s `env_config`. These are planning numbers, not a bill - actual cost depends on real traffic (data transfer, ALB LCUs, log volume) that can't be predicted from the Terraform alone. **Dev has been applied and tested end to end against real AWS** (staging/prod have not) - the dev column below reflects real spend actually incurred, not just a projection, including the EBS volume backing Prometheus's PVC and the logging additions below (all confirmed live - see `docs/design-decisions.md`).

**Contents**
- [What actually drives the difference between environments](#what-actually-drives-the-difference-between-environments)
- [Practical recommendation](#practical-recommendation)

| | dev | staging | prod |
|---|---:|---:|---:|
| EKS control plane | $73 | $73 | $73 |
| Nodes | $61 (2× t3.medium) | $61 (2× t3.medium) | $182 (3× t3.large) |
| NAT Gateway(s) | $33 (1 shared) | $33 (1 shared) | $99 (1 per AZ) |
| RDS | $15 (t4g.micro, single-AZ) | $28 (t4g.small, single-AZ) | $145 (t4g.medium, **Multi-AZ**) |
| ElastiCache | $12 (t4g.micro) | $24 (t4g.small) | $50 (t4g.medium) |
| ALB × 2 (backend + frontend) | $40 | $40 | $50 |
| EBS (Prometheus PVC, `gp3`) | ~$1 (10Gi) | ~$2 (20Gi) | ~$4 (50Gi) |
| VPC Flow Logs + ALB access logs (S3) | ~$1 | ~$2 | ~$3 |
| ECR (backend + frontend) + Secrets Manager + CloudWatch Logs | ~$12 | ~$12 | ~$15 |
| **Total (continuous)** | **~$248/mo (~$8/day)** | **~$275/mo (~$9/day)** | **~$621/mo (~$21/day)** |

Each tier gets its own ALB (see `docs/design-decisions.md` for why the frontend is containerized rather than served from a CDN) - a static-asset CDN would have been cheaper than a second load balancer, but wasn't what the take-home brief's literal wording called for. Frontend's own compute cost is close to zero on top of this - its pods (2× 50m CPU / 64Mi memory) run on node capacity the cluster already has for the backend, not new nodes. The EBS row is what backs Prometheus's actual metrics storage (see `docs/design-decisions.md`) - small in absolute terms next to everything else here, but a real, easy-to-miss line item once Prometheus stops using an ephemeral `emptyDir`. The flow-logs/access-logs row is a genuine estimate, not a measurement - both were confirmed actually delivering entries only minutes before this was written, not long enough to know real volume; REJECT-only flow logs and 30-day S3 lifecycle expiration on the access logs both keep whatever the real number turns out to be small.

**All three running simultaneously: ~$1,144/mo (~$38/day).** That number is the actual reason `terraform.yml` gates every `apply` behind a GitHub Environment approval rather than auto-applying on merge (see `docs/design-decisions.md`) - none of this should run continuously against a personal AWS account without a deliberate reason to. State itself is real and remote (S3, versioned, locked) regardless of which environments are actually up - that's a separate concern from whether the infrastructure those environments describe is running.

## What actually drives the difference between environments

- **Prod's node instance type and count** (`t3.large` × 3 vs `t3.medium` × 2) - more than doubles the compute line.
- **Prod's Multi-AZ RDS** - roughly doubles the database line for automatic failover.
- **Prod's one-NAT-per-AZ** vs dev/staging's single shared NAT - roughly triples that line, trading cost for not having one AZ's outage take down all outbound traffic.

All three are documented, deliberate trade-offs in `env_config` - not fixed costs of "having three environments," but the specific price of prod's stronger availability guarantees.

## Practical recommendation

- Keep **dev** running only while actively working with it; tear it down between sessions (`terraform destroy` in that workspace, or scale the node group to zero if only a short pause is needed - EKS control plane cost is flat either way).
- Never bring up **staging** or **prod** just to "have them running" - stand them up for an actual promotion/demo, then tear down.
- If demoing to the interviewer live, a single `dev` environment fully covers the architecture story; there's no need to have all three up at once to show the design works.
