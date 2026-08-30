# conduit-platform

The platform layer for **Conduit** (a RealWorld/"Medium clone" app) - Terraform, Helm/Helmfile, CI/CD, and observability for a Go backend and Angular frontend running on EKS. Built for a DevOps take-home; the app itself is explicitly not what's evaluated (see the task brief), so most of the interesting work here is making a demo app's infrastructure genuinely production-adjacent rather than the app code.

**Contents**
- [The three repos](#the-three-repos)
- [Layout](#layout)
- [Reproducing this from scratch](#reproducing-this-from-scratch)
- [Where to start reading](#where-to-start-reading)

## The three repos

| Repo | Owns |
|---|---|
| [`golang-gin-realworld-example-app`](https://github.com/mashiofu/golang-gin-realworld-example-app) (fork) | Backend API, its own Dockerfile, its own CI/CD |
| [`angular-realworld-example-app`](https://github.com/mashiofu/angular-realworld-example-app) (fork) | Frontend SPA, its own Dockerfile, its own CI/CD |
| `conduit-platform` (this repo) | Terraform, Helm chart + Helmfile, observability-as-code, docs, runbooks - the platform team's repo |

Each app repo owns its own build/test/deploy pipeline; **this repo is the only one with any credentials that touch the live cluster** (see `docs/design-decisions.md`). That split - app teams own their service, one platform repo owns the shared infra - is deliberate, not incidental.

## Layout

```
terraform/        AWS infrastructure - see terraform/README.md for the workspace workflow
helm/             Platform add-ons (Helmfile) + the backend/frontend Helm charts - see helm/README.md
scripts/          Cross-repo automation (GitHub Environment sync)
docs/
  DEPLOYMENT.md          the complete step-by-step guide to standing this up from scratch
  architecture.md        diagrams - runtime topology and CI/CD flow
  design-decisions.md    every deliberate trade-off and every real bug found along the way
  cost-estimate.md       real per-environment $ estimates
  runbooks/
    backup-restore.md
    incident-response.md
```

## Reproducing this from scratch

**Dev has been applied and tested end to end against real AWS** (staging/prod have not) - see `docs/design-decisions.md` for why the apply decision was made separately from, and after, validating the code, and `docs/cost-estimate.md` for what that actually cost. **`docs/DEPLOYMENT.md` is the complete, step-by-step guide** for standing this up in your own account - every command in order, including the manual GitHub steps (a fine-grained PAT for cross-repo dispatch) that can't be automated, and the teardown order that actually matters (Helm before Terraform, or the ALB the Load Balancer Controller created gets orphaned and blocks the VPC from deleting).

## Where to start reading

- **To actually stand this up**: `docs/DEPLOYMENT.md`
- **The architecture, visually**: `docs/architecture.md`
- **Why it's built this way, and what's still rough**: `docs/design-decisions.md` - this is the single most useful page in this repo if you're evaluating the reasoning, not just the result
- **What it costs to actually run**: `docs/cost-estimate.md`
- **What to do when something breaks**: `docs/runbooks/`
