# conduit-platform/helm

Helm chart installs for the platform layer, managed by **Helmfile**,
deliberately kept **separate from Terraform** - Terraform owns AWS
resources (including the EKS cluster and each add-on's IRSA role);
Helmfile owns what actually runs on the cluster. Neither tool touches the
other's state.

**Contents**
- [Why not SOPS](#why-not-sops)
- [Usage](#usage)

```
helm/
  helmfile.yaml.gotmpl   # entry point - composes the seven releases below
  environments.yaml      # dev/staging/prod, matching the Terraform workspaces
  common.yaml             # values shared by every environment
  dev.yaml, staging.yaml, prod.yaml   # static per-environment values
  *.generated.yaml        # gitignored - apply-time values from Terraform, see scripts/
  backend-chart/          # the backend's own Helm chart (Deployment/HPA/PDB/NetworkPolicy/...)
  frontend-chart/         # same shape, for the frontend
  cluster-storage-chart/  # one static StorageClass (gp3) - see helm-charts/cluster-storage/
  helm-charts/
    cluster-storage/      # release wrapper around ../../cluster-storage-chart, applied first
    aws-load-balancer-controller/
    external-secrets/
    cluster-autoscaler/
    monitoring/           # kube-prometheus-stack - installed here; dashboards/alerts are a later phase
    backend/              # release wrapper around ../../backend-chart, ns conduit-backend
    frontend/             # release wrapper around ../../frontend-chart, ns conduit-frontend
  scripts/
    generate-terraform-values.sh
```

Each `helm-charts/<name>/` is a self-contained mini-Helmfile:
`repositories.yaml.gotmpl` (that chart's repo, for the four third-party
add-ons - `backend`/`frontend`/`cluster-storage` point at their own local
`../../*-chart` sources instead) and `helmfile.yaml.gotmpl` (the release
itself, `bases:`-merged with the repository file) plus, where the chart
actually needs one, `values.yaml.gotmpl` (templated against the
environment's merged values - `cluster-storage` skips this file entirely,
since its one `StorageClass` object is fully static). Adding a new
release means adding one such directory and one line in the top-level
`helmfile.yaml.gotmpl`'s `helmfiles:` list - not editing a single
growing file. `backend` and `frontend` each install into their own
namespace (`conduit-backend`/`conduit-frontend`, `createNamespace: true`)
rather than `default` - see [`docs/design-decisions.md`](../docs/design-decisions.md) for why.
`cluster-storage` is listed first, deliberately: `monitoring`'s
Prometheus PVC needs the `gp3` `StorageClass` it creates to already
exist, and nested `helmfiles:` entries apply in the order listed.

## Why not SOPS

Some Helmfile setups encrypt secret values in-repo with SOPS
(`<env>.yaml` / `<env>-enc.yaml` pairs). Deliberately not used here:
none of the four third-party add-ons need a secret sitting in a Helm
values file at all - they authenticate to AWS via IRSA (the role ARN in
a values file isn't a secret) - and `backend`/`frontend`'s actual
application secrets flow through Secrets Manager/SSM Parameter Store via
External Secrets Operator instead, never landing in a values file
either. Worth reintroducing if a future chart genuinely needs a
credential in its values.

## Usage

**Never run a bare `helmfile apply` (or `diff`) against `backend`/`frontend`.** Both releases need `image.tag` set via `--set image.tag=<git-sha>` - only `deploy-backend.yml`/`deploy-frontend.yml` do that; a local apply with no `-l` filter re-applies them anyway, silently falling back to each chart's own `image.tag: "latest"` default, a tag that's never actually pushed to ECR (only `sha-<commit>` tags are). Hit live exactly this way - see [`docs/design-decisions.md`](../docs/design-decisions.md)'s bug list. Scope any local command to the add-ons only, the same way [`docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md)'s own step 6 does:
```bash
helmfile -e dev -l name!=conduit-backend -l name!=conduit-frontend apply
```

```bash
# 1. After `terraform apply` in terraform/live (or whenever its outputs
#    might have changed), bridge them into this environment's values -
#    every time, not just the first time; a stale generated file with a
#    genuinely wrong value (not just a missing one) is exactly what
#    caused the incident linked above:
./scripts/generate-terraform-values.sh dev

# 2. Then, same as any Helmfile project (see the warning above for
#    backend/frontend specifically):
helmfile -e dev diff     # needs a live cluster (kubectl context set via
helmfile -e dev apply    # `aws eks update-kubeconfig --name <cluster>`)

# Verify without a live cluster at all:
helmfile -e dev lint
helmfile -e dev template
```
