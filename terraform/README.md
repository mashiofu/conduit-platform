# conduit-platform/terraform

**Contents**
- [Environments: Terraform workspaces, not directories](#environments-terraform-workspaces-not-directories)
  - [Using it](#using-it)
- [Bootstrapping remote state](#bootstrapping-remote-state)
- [Provider version pinning](#provider-version-pinning)
- [Testing](#testing)

```
terraform/
  bootstrap/   # one-time: the S3 bucket that live/ uses as its remote state backend
  modules/     # reusable building blocks (network, ecr, rds, elasticache, eks, iam-*)
  live/        # the actual deployable root module - one config, three workspaces
```

## Environments: Terraform workspaces, not directories

`live/` is a single root module, differentiated per environment (`dev` /
`staging` / `prod`) by **Terraform workspace**, not by one directory per
environment. That's a deliberate call, not the only reasonable one -
HashiCorp's own guidance leans toward directory-per-environment for strict
separation, since same-code-different-workspace means there's no
filesystem-level guardrail against planning against the wrong one. Given
that, three things in `live/main.tf` specifically exist to close that gap:

1. **`local.env_config`** - every prod-vs-dev difference (instance sizes,
   Multi-AZ, deletion protection, NAT redundancy, ...) lives in one map
   keyed by workspace name, not scattered
   `terraform.workspace == "prod" ? ... : ...` conditionals through the
   codebase. Adding a fourth environment means adding one key here.
2. **`terraform_data.workspace_guard`'s precondition** refuses to
   plan/apply at all against the `default` workspace (the one every
   Terraform config starts with and can never delete) - so there's no
   ambiguous, unlabeled environment real infrastructure can silently land
   in. (This is a resource `precondition`, not a `check` block - `check`
   block assertions are advisory warnings in Terraform and don't actually
   stop a plan/apply, which makes them the wrong tool here.)
3. **`prod`'s GitHub Actions role** trusts only GitHub's own `production`
   Environment (`github_environment = "prod"` in `env_config` - same name
   as the Terraform workspace, deliberately, to keep one vocabulary
   across Terraform/GitHub/Helmfile instead of two),
   not just "any push to this repo" - pair that with required
   reviewers/wait timers on that GitHub Environment for a real deploy
   gate. `dev`/`staging` stay on the simpler any-ref trust for faster
   iteration.

### Using it

```bash
cd live
terraform init                      # first time only, or after changing modules/backend

terraform workspace new dev         # first time only, per environment
terraform workspace new staging
terraform workspace new prod

terraform workspace select dev
terraform plan                      # or apply
```

A single S3 backend (once `bootstrap/` is applied - see below) serves all
three workspaces; Terraform namespaces state per workspace automatically
under the same backend key (`env:/<workspace>/<key>`), so there's nothing
per-environment to configure in the backend itself.

## Bootstrapping remote state

One-time, per AWS account - standing up the state bucket is itself a
real AWS action, deliberately separate from `live/`'s own apply (see
[`docs/design-decisions.md`](../docs/design-decisions.md)). See [`docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md) step 1 for the
full walkthrough; the commands themselves:

```bash
cd bootstrap
terraform init
terraform apply -var="state_bucket_name=<something-globally-unique>"
```

Then, in `live/`: copy `backend.hcl.example` to `backend.hcl`, fill in the
bucket name from that output, uncomment the `backend "s3" {}` block in
`versions.tf` (leave it **empty** - `versions.tf` is committed to git, so
every real value belongs in `backend.hcl` instead, never hardcoded here),
and run `terraform init -backend-config=backend.hcl -migrate-state`.

## Provider version pinning

Both root modules pin `hashicorp/aws` with `~> 6.0` (currently resolves to
v6.62.0) - a pessimistic constraint so patch/minor upgrades happen freely
but a jump to v7 requires a deliberate bump, not a surprise on the next
`terraform init`. Re-tighten this periodically rather than leaving it
wide open.

## Testing

`modules/network` has a `terraform test` suite (`modules/network/tests/`)
covering the single-vs-per-AZ NAT gateway logic and the `az_count`
validation bound. Run it with `terraform test` from that module's
directory - every `run` block uses `command = plan`, so it creates
nothing, but it does need AWS credentials configured (same profile as
everything else here) to resolve the `aws_availability_zones` data
source.
