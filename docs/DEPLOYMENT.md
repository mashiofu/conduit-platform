# Deploying From Scratch

Every command below, in the order that actually works. Written to be run by a human in their own terminal - nothing here has been executed for you (see `docs/design-decisions.md`: standing up real AWS infrastructure was a deliberate, separate decision from writing the code).

Nothing in this guide is specific to any one person - it's written for whoever forked these three repos to their own GitHub account, into their own AWS account. That's step 0.

**Total time: ~30-40 minutes**, almost all of it waiting for the EKS cluster to provision. **Real cost starts accruing the moment step 3 finishes** - see `docs/cost-estimate.md` (~$7.50/day for `dev`).

---

## 0. Configure your deployment

```bash
cd conduit-platform
cp deploy.env.example deploy.env
```

Edit `deploy.env` - fill in your own AWS profile name, GitHub username/org, and a globally-unique Terraform state bucket name (see the comments in the file for what each value means and why it matters). Then, in **every terminal** you use for the rest of this guide:

```bash
source deploy.env
```

Every command below assumes this has been done - none of them hardcode an AWS profile, GitHub org, or bucket name. If a command fails because a variable is unset, you skipped this step (or opened a new terminal without re-sourcing it).

Assumes you're in `~/incode-take-home-task/` (or wherever) with all three repos as sibling directories.

## 1. Bootstrap remote Terraform state

One-time, per AWS account:

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=$TF_STATE_BUCKET"
```

Type `yes` when prompted. If that bucket name is taken (S3 names are global across every AWS account on Earth, not just yours), pick a different value for `TF_STATE_BUCKET` in `deploy.env`, re-source it, and retry.

## 2. Point `live/` at the new backend

```bash
cd ../live
cp backend.hcl.example backend.hcl
```

Edit `backend.hcl` - replace the placeholder with your real bucket name:

```hcl
bucket       = "your-TF_STATE_BUCKET-value-here"
key          = "live/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
```

Uncomment the `backend "s3" { ... }` block in `versions.tf` (it's the last thing in that file, commented out with instructions right above it).

```bash
terraform workspace select dev
terraform init -backend-config=backend.hcl -migrate-state
```

Answer `yes` to "copy existing state to the new backend." (The `dev`/`staging`/`prod` workspaces created earlier for testing are all empty - nothing's actually been applied yet - so there's nothing meaningful to lose here either way.)

## 3. Apply Terraform - this is the real infrastructure

```bash
terraform apply
```

Review the plan, type `yes`. This provisions the VPC, EKS cluster + node group, RDS, ElastiCache, ECR, every IAM role (trust-scoped to `$GITHUB_ORG`'s repos - this is where `deploy.env` actually matters, not just cosmetically), CloudFront/S3, the `JWT_SECRET` SSM parameter, and the CloudWatch saved queries - **~85 resources**. The EKS cluster + node group is what makes this slow (10-15 minutes is normal); everything else is fast.

When it finishes, sanity-check the cluster exists:
```bash
aws eks describe-cluster --name conduit-dev-cluster --query 'cluster.status'
# -> "ACTIVE"
```

## 4. Bridge Terraform outputs into GitHub

```bash
cd ../../scripts
./sync-github-environments.sh dev
```

This creates/updates a `dev` GitHub Environment in all three repos (`$PLATFORM_REPO`, `$BACKEND_REPO`, `$FRONTEND_REPO` under `$GITHUB_ORG`) with the IAM role ARNs, ECR URL, S3 bucket name, and CloudFront distribution ID that each repo's workflows need. Requires `gh` authenticated (it already is) and `jq`.

## 5. Create the cross-repo dispatch token (manual - can't be automated)

The backend/frontend repos need to notify `conduit-platform` when they've built something new, via GitHub's `repository_dispatch` API - which needs write access to a *different* repo than the one the workflow is running in, so the default `GITHUB_TOKEN` can't do it.

1. Go to **github.com/settings/personal-access-tokens/new** (fine-grained token).
2. Name it something like `conduit-platform-dispatch`, set an expiration.
3. **Repository access**: only `$PLATFORM_REPO` - not all repos.
4. **Permissions**: Repository permissions → **Contents: Read and write**.
5. Generate it, copy the value (you won't see it again).
6. Add it as a secret in *both* app repos:
   ```bash
   gh secret set PLATFORM_DISPATCH_TOKEN --repo "$GITHUB_ORG/$BACKEND_REPO" --body "<paste-token>"
   gh secret set PLATFORM_DISPATCH_TOKEN --repo "$GITHUB_ORG/$FRONTEND_REPO" --body "<paste-token>"
   ```
   (Or add it through each repo's Settings → Secrets and variables → Actions, if you'd rather not paste a token into a terminal command's argument list.)

## 6. Install the platform add-ons

Everything except the backend itself - that gets its first real deploy in step 8, through the actual CI/CD pipeline, not by hand here.

```bash
cd ../helm
aws eks update-kubeconfig --name conduit-dev-cluster --region "$AWS_REGION"
./scripts/generate-terraform-values.sh dev
helmfile -e dev -l name!=conduit-backend apply
```

Verify everything comes up:
```bash
kubectl get pods -A
```
Expect pods in `kube-system` (LB controller, cluster-autoscaler), `external-secrets`, and `monitoring` (Prometheus/Grafana/Alertmanager), all `Running`.

## 7. Push all three repos to GitHub

Everything's been sitting uncommitted, so review before committing:

```bash
cd ../../conduit-platform
git add -A && git status   # review, then:
git commit -m "Full platform: Terraform, Helm/Helmfile, CI/CD, observability"
git push -u origin main

cd ../golang-gin-realworld-example-app
git add -A && git status
git commit -m "Add Postgres support, Prometheus metrics, Redis cache, Dockerfile, CI/CD"
git push origin main

cd ../angular-realworld-example-app
git add -A && git status
git commit -m "Runtime-configurable API URL, zone.js fix, Dockerfile, CI/CD"
git push origin main
```

## 8. Let the real pipeline deploy the backend, then the frontend

Pushing to `$BACKEND_REPO`'s `main` branch (step 7 already did this) triggers `cd.yml` automatically: build → test → push to ECR → `repository_dispatch` → `conduit-platform`'s `deploy-backend.yml` runs `helmfile apply` for the backend, waits for the ALB, runs the k6 smoke+perf check, and publishes the ALB hostname to SSM.

**Watch it**: `gh run watch --repo "$GITHUB_ORG/$BACKEND_REPO"` (or the Actions tab in the browser).

Once that finishes, the frontend needs to pick up the now-published backend URL. Its own push in step 7 may have run *before* the backend URL existed - if so, just re-run it:
```bash
gh workflow run cd.yml --repo "$GITHUB_ORG/$FRONTEND_REPO"
gh run watch --repo "$GITHUB_ORG/$FRONTEND_REPO"
```

## 9. Verify end to end

```bash
# Backend directly
kubectl get ingress conduit-backend
curl http://<hostname-from-above>/api/ping/

# Frontend - open in a browser
aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='conduit-dev frontend'].DomainName" --output text
```
Open that CloudFront URL, register a user, create an article, favorite something - that exercises frontend → ALB → backend → RDS and Redis all at once.

**Grafana**: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`, open `localhost:3000`, log in `admin` / `prom-operator` (the chart's default - change it if this cluster lives longer than a quick demo), open the **Conduit Backend** dashboard.

## Tearing down

**Order matters.** Helm-managed resources first, or the ALB the Load Balancer Controller created gets orphaned and blocks the VPC from deleting:

```bash
cd conduit-platform/helm
helmfile -e dev destroy

cd ../terraform/live
terraform destroy
```
