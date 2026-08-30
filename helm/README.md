# conduit-platform/helm

Helm chart installs for the platform layer, managed by **Helmfile**,
deliberately kept **separate from Terraform** - Terraform owns AWS
resources (including the EKS cluster and each add-on's IRSA role);
Helmfile owns what actually runs on the cluster. Neither tool touches the
other's state.

```
helm/
  helmfile.yaml.gotmpl   # entry point - composes the six releases below
  environments.yaml      # dev/staging/prod, matching the Terraform workspaces
  common.yaml             # values shared by every environment
  dev.yaml, staging.yaml, prod.yaml   # static per-environment values
  *.generated.yaml        # gitignored - apply-time values from Terraform, see scripts/
  backend-chart/          # the backend's own Helm chart (Deployment/HPA/PDB/NetworkPolicy/...)
  frontend-chart/         # same shape, for the frontend
  helm-charts/
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
add-ons - `backend`/`frontend` point at the local `../../*-chart`
sources instead) and `helmfile.yaml.gotmpl` (the release itself,
`bases:`-merged with the repository file) plus `values.yaml.gotmpl`
(templated against the environment's merged values). Adding a new
release means adding one such directory and one line in the top-level
`helmfile.yaml.gotmpl`'s `helmfiles:` list - not editing a single
growing file. `backend` and `frontend` each install into their own
namespace (`conduit-backend`/`conduit-frontend`, `createNamespace: true`)
rather than `default` - see `docs/design-decisions.md` for why.

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

```bash
# 1. After `terraform apply` in terraform/live (or whenever its outputs
#    might have changed), bridge them into this environment's values:
./scripts/generate-terraform-values.sh dev

# 2. Then, same as any Helmfile project:
helmfile -e dev diff     # needs a live cluster (kubectl context set via
helmfile -e dev apply    # `aws eks update-kubeconfig --name <cluster>`)

# Verify without a live cluster at all:
helmfile -e dev lint
helmfile -e dev template
```
