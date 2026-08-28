#!/usr/bin/env bash
# Bridges Terraform outputs into GitHub Environment (and a couple of
# plain repo-level) variables, across all three repos, for one
# environment - same philosophy as helm/scripts/generate-terraform-values.sh,
# just one hop further: nobody hand-copies an IAM role ARN into a GitHub
# Environment's settings either.
#
# Run this once per environment after that environment's first
# `terraform apply` (or whenever its outputs change - e.g. a role ARN
# would change if that resource were ever replaced).
#
# Usage: scripts/sync-github-environments.sh <dev|staging|prod>
#
# Reads GITHUB_ORG, PLATFORM_REPO, BACKEND_REPO, FRONTEND_REPO from the
# environment - `source deploy.env` (see deploy.env.example) before
# running this, same as every other command in docs/DEPLOYMENT.md.
set -euo pipefail

ENV="${1:?usage: $0 <dev|staging|prod>}"
OWNER="${GITHUB_ORG:?GITHUB_ORG is not set - source deploy.env first (see deploy.env.example)}"
PLATFORM_REPO="${PLATFORM_REPO:?PLATFORM_REPO is not set - source deploy.env first}"
BACKEND_REPO="${BACKEND_REPO:?BACKEND_REPO is not set - source deploy.env first}"
FRONTEND_REPO="${FRONTEND_REPO:?FRONTEND_REPO is not set - source deploy.env first}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform/live"

for bin in gh jq terraform; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin is required" >&2; exit 1; }
done

(cd "$TF_DIR" && terraform workspace select "$ENV")
OUTPUTS_JSON="$(cd "$TF_DIR" && terraform output -json)"
val() { jq -r ".\"$1\".value" <<<"$OUTPUTS_JSON"; }

REGION="$(val aws_region)"
ENV_UPPER="$(echo "$ENV" | tr '[:lower:]' '[:upper:]')"

# The Terraform state bucket isn't a `live` output - it's an INPUT,
# produced by the separate `terraform/bootstrap` apply, whose own state
# lives wherever that apply ran (can't live inside the bucket it itself
# creates). backend.hcl is the practical, already-established local
# record of that value (see its own comment) - read it from there
# rather than re-pointing this script at bootstrap's state too.
BACKEND_HCL="$TF_DIR/backend.hcl"
[ -f "$BACKEND_HCL" ] || { echo "$BACKEND_HCL not found - copy it from backend.hcl.example and fill in bucket (from terraform/bootstrap's state_bucket_name output) first" >&2; exit 1; }
STATE_BUCKET="$(grep -E '^[[:space:]]*bucket[[:space:]]*=' "$BACKEND_HCL" | sed -E 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')"
[ -n "$STATE_BUCKET" ] || { echo "Could not parse a bucket value out of $BACKEND_HCL" >&2; exit 1; }

ensure_environment() {
  gh api -X PUT "repos/$OWNER/$1/environments/$2" >/dev/null
}

# Idempotent: PATCH an existing variable, or POST a new one if that 404s.
set_env_var() {
  local repo="$1" environment="$2" name="$3" value="$4"
  if ! gh api -X PATCH "repos/$OWNER/$repo/environments/$environment/variables/$name" -f "value=$value" >/dev/null 2>&1; then
    gh api -X POST "repos/$OWNER/$repo/environments/$environment/variables" -f "name=$name" -f "value=$value" >/dev/null
  fi
}

set_repo_var() {
  local repo="$1" name="$2" value="$3"
  if ! gh api -X PATCH "repos/$OWNER/$repo/actions/variables/$name" -f "value=$value" >/dev/null 2>&1; then
    gh api -X POST "repos/$OWNER/$repo/actions/variables" -f "name=$name" -f "value=$value" >/dev/null
  fi
}

echo "=== conduit-platform ($ENV) ==="
ensure_environment "$PLATFORM_REPO" "$ENV"
set_env_var "$PLATFORM_REPO" "$ENV" TERRAFORM_CI_ROLE_ARN "$(val github_actions_terraform_role_arn)"
set_env_var "$PLATFORM_REPO" "$ENV" PLATFORM_CI_ROLE_ARN "$(val github_actions_platform_role_arn)"
set_env_var "$PLATFORM_REPO" "$ENV" AWS_REGION "$REGION"
# Flat, repo-level (not environment-scoped) copy of the terraform-ci role
# ARN, suffixed per workspace - the PR-triggered plan job intentionally
# doesn't reference a GitHub Environment at all (see terraform.yml's
# comment on why), so it can't read environment-scoped variables.
set_repo_var "$PLATFORM_REPO" "TERRAFORM_CI_ROLE_ARN_${ENV_UPPER}" "$(val github_actions_terraform_role_arn)"
set_repo_var "$PLATFORM_REPO" AWS_REGION "$REGION"
# Same bucket for every workspace (dev/staging/prod) - not environment-
# specific, so this is a flat repo-level var like the two above, synced
# every run regardless of which $ENV was passed. terraform.yml and
# deploy-backend.yml's `terraform init` steps need this to actually
# reach the real backend instead of silently falling back to an empty
# local one - see docs/design-decisions.md for that incident.
set_repo_var "$PLATFORM_REPO" TF_STATE_BUCKET "$STATE_BUCKET"

echo "=== $BACKEND_REPO ($ENV) ==="
ensure_environment "$BACKEND_REPO" "$ENV"
set_env_var "$BACKEND_REPO" "$ENV" AWS_ROLE_ARN "$(val github_actions_backend_role_arn)"
set_env_var "$BACKEND_REPO" "$ENV" ECR_REPOSITORY_URL "$(val ecr_backend_repository_url)"
set_env_var "$BACKEND_REPO" "$ENV" AWS_REGION "$REGION"
set_env_var "$BACKEND_REPO" "$ENV" PLATFORM_REPO "$OWNER/$PLATFORM_REPO"
# Flat copy of dev's ECR URL specifically - promote.yml's staging/prod
# jobs run under the TARGET environment (so `vars.ECR_REPOSITORY_URL`
# there means the target's repo), but still need to know where to copy
# *from*, which is always dev regardless of target.
if [ "$ENV" = "dev" ]; then
  set_repo_var "$BACKEND_REPO" ECR_REPOSITORY_URL_DEV "$(val ecr_backend_repository_url)"
fi

echo "=== $FRONTEND_REPO ($ENV) ==="
ensure_environment "$FRONTEND_REPO" "$ENV"
set_env_var "$FRONTEND_REPO" "$ENV" AWS_ROLE_ARN "$(val github_actions_frontend_role_arn)"
set_env_var "$FRONTEND_REPO" "$ENV" FRONTEND_BUCKET_NAME "$(val frontend_bucket_name)"
set_env_var "$FRONTEND_REPO" "$ENV" CLOUDFRONT_DISTRIBUTION_ID "$(val frontend_distribution_id)"
set_env_var "$FRONTEND_REPO" "$ENV" AWS_REGION "$REGION"
set_env_var "$FRONTEND_REPO" "$ENV" BACKEND_URL_PARAMETER_NAME "$(val backend_url_parameter_name)"
# Flat copy of dev's own bucket name - same reasoning as
# ECR_REPOSITORY_URL_DEV above: promote.yml's staging/prod jobs run under
# the target environment, but still need to know dev's bucket name to
# copy *from*.
if [ "$ENV" = "dev" ]; then
  set_repo_var "$FRONTEND_REPO" DEV_FRONTEND_BUCKET_NAME "$(val frontend_bucket_name)"
fi

echo "done: $ENV synced to all three repos"
