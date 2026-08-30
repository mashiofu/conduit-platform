# Deploying From Scratch

Every command below, in the order that actually works. Written to be run by a human in their own terminal - nothing here has been executed for you (see `docs/design-decisions.md`: standing up real AWS infrastructure was a deliberate, separate decision from writing the code).

Nothing in this guide is specific to any one person - it's written for whoever forked these three repos to their own GitHub account, into their own AWS account.

**Total time: ~30-40 minutes**, almost all of it waiting for the EKS cluster to provision. **Real cost starts accruing the moment step 3 finishes** - see `docs/cost-estimate.md` (~$246/mo, ~$8/day for `dev`).

---

## Prerequisites

### Get the three repos

Clone all three **as siblings under the same parent directory** - not optional, two real things depend on this exact layout: `docker-compose.yml` (local dev, optional) builds the other two repos via relative paths (`../golang-gin-realworld-example-app`, `../angular-realworld-example-app`), and step 7 below `cd`s between all three the same way.

```bash
mkdir -p ~/conduit && cd ~/conduit

git clone https://github.com/<your-github-username>/conduit-platform.git
git clone https://github.com/<your-github-username>/golang-gin-realworld-example-app.git
git clone https://github.com/<your-github-username>/angular-realworld-example-app.git
```

You should end up with:
```
conduit/
  conduit-platform/
  golang-gin-realworld-example-app/
  angular-realworld-example-app/
```

(Renamed a fork? Fine - just use the name you actually used, and set it in `deploy.env` in step 0 below; `BACKEND_REPO`/`FRONTEND_REPO`/`PLATFORM_REPO` are exactly what make that configurable.)

### Install these first

| Tool | Version | Used for |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `>= 1.10` | Every `terraform` command below - `1.10` specifically for S3 native state locking (`use_lockfile`), no DynamoDB table needed |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | Everything - Terraform's provider, `aws eks update-kubeconfig`, every verification step. Configure it with credentials broad enough to create IAM roles/policies, VPCs, EKS, RDS, etc. - a personal sandbox account with admin access is the realistic expectation here, not a tightly-scoped IAM user |
| [Helm](https://helm.sh/docs/intro/install/) | 3.12+ (built/tested against 4.2.4) | Helmfile's underlying engine |
| [Helmfile](https://github.com/helmfile/helmfile#installation) | built/tested against 1.7.4 | Installing/upgrading every chart in `helm/` |
| [helm-diff plugin](https://github.com/databus23/helm-diff) - `helm plugin install https://github.com/databus23/helm-diff --version v3.15.11 --verify=false` | v3.15.11 specifically, not "whatever's latest" | `helmfile apply`/`diff` shell out to `helm diff` internally to compute what would change - this isn't a built-in Helm command, and `helmfile lint`/`template` don't need it, so it's easy to not notice it's missing until the first real `apply`. The `--verify=false` is because this plugin doesn't publish the provenance files Helm 4's default plugin verification expects. The version pin is deliberate too, not just caution: `deploy-backend.yml`'s CI hit this directly - `helm plugin install` grabbing latest helm-diff against an older, pinned Helm failed to load at all ("unknown field platformHooks" in the plugin's manifest, a schema field that Helm version didn't know about yet). v3.15.11 is the exact version confirmed working against Helm v4.2.4 throughout this project's own testing. |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | within one minor version of 1.34 (the cluster's version, per standard kubectl/server skew policy) | Verifying pods/ingress after a deploy |
| [gh CLI](https://cli.github.com/), authenticated (`gh auth login`) | any recent version | The GitHub Environment sync script, setting secrets, watching workflow runs |
| [jq](https://jqlang.github.io/jq/) | any recent version | Parsing `terraform output -json` in the sync scripts |
| git | any recent version | Obviously |

Docker is **not** required to follow this guide - image builds happen inside GitHub Actions, not on your machine. It only matters if you also want to run the stack locally via `conduit-platform/docker-compose.yml`.

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

Uncomment the `backend "s3" {}` block in `versions.tf` (it's the last thing in that file, commented out with instructions right above it) - leave it **empty**. Every real value comes from `backend.hcl` via `-backend-config` below; `versions.tf` is committed to git, so your bucket name should never end up hardcoded in it.

```bash
terraform init -backend-config=backend.hcl -migrate-state
```

If prompted to copy existing state to the new backend, answer `yes` - though if this is a genuinely fresh clone there won't be any local state to ask about at all.

**Now select the workspace - after this init, not before.** A brand-new S3 bucket has no workspaces of its own yet, so switching backends resets you to `default` regardless of what you had selected a moment ago (even if you'd already created `dev`/`staging`/`prod` locally, e.g. from earlier testing against a local backend - those don't carry over to a different backend just by name):

```bash
terraform workspace show
```

If that isn't `dev`, check what actually exists under this backend and create it if needed:
```bash
terraform workspace list
terraform workspace new dev      # if `dev` isn't in that list
# or: terraform workspace select dev   # if it already is (e.g. re-running this)
```

## 3. Apply Terraform - this is the real infrastructure

```bash
terraform apply
```

Review the plan, type `yes`. This provisions the VPC, EKS cluster + node group, RDS, ElastiCache, two ECR repos (backend + frontend), every IAM role (trust-scoped to `$GITHUB_ORG`'s repos - this is where `deploy.env` actually matters, not just cosmetically, plus EKS Pod Identity roles for the CloudWatch Observability and EBS CSI driver addons), a CloudWatch log group for Redis's slow-log, VPC Flow Logs, an S3 bucket for ALB access logs, the `JWT_SECRET` SSM parameter, and the CloudWatch saved queries - **124 resources** (confirmed via `terraform state list` against this project's own `dev` state). The EKS cluster + node group is what makes this slow (10-15 minutes is normal); everything else is fast.

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

This creates/updates a `dev` GitHub Environment in all three repos (`$PLATFORM_REPO`, `$BACKEND_REPO`, `$FRONTEND_REPO` under `$GITHUB_ORG`) with the IAM role ARNs and each app's own ECR repo URL that its workflows need. Requires `gh` authenticated (it already is) and `jq`.

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

Everything except the backend and frontend themselves - both are containers on EKS and get their first real deploy in step 8, through the actual CI/CD pipeline, not by hand here.

```bash
cd ../helm
aws eks update-kubeconfig --name conduit-dev-cluster --region "$AWS_REGION"
./scripts/generate-terraform-values.sh dev
helmfile -e dev -l name!=conduit-backend -l name!=conduit-frontend apply --skip-diff-validation-on-install
```

`--skip-diff-validation-on-install` matters here specifically for the AWS Load Balancer Controller chart: it bundles both a CRD (`IngressClassParams`) and an instance of it in the same release, and since nothing's ever been installed on a brand-new cluster, `helm-diff`'s K8s API validation has no way to recognize that CRD's kind yet when it tries to render a diff preview for the not-yet-installed release. This flag disables just that validation step for newly-installed releases - it still computes and shows a diff, unlike its blunter sibling `--skip-diff-on-install`.

Verify everything comes up:
```bash
kubectl get pods -A
```
Expect pods in `kube-system` (LB controller, cluster-autoscaler), `external-secrets`, and `monitoring` (Prometheus/Grafana/Alertmanager), all `Running`.

## 7. Push your code to GitHub

Which of these applies depends on where you're starting from:

> **Repos not pushed yet** (working from local changes for the first time): commit and push all three now.
> ```bash
> cd ../../conduit-platform   # back to its root - step 6 left you inside conduit-platform/helm
> git add -A && git status   # review what's actually changed, then:
> git commit -m "..."
> git push origin main
>
> cd ../golang-gin-realworld-example-app && git add -A && git status && git commit -m "..." && git push origin main
> cd ../angular-realworld-example-app && git add -A && git status && git commit -m "..." && git push origin main
> ```

> **Repos already on GitHub** (you cloned them fresh per the Prerequisites section, or already pushed in an earlier pass): nothing to do here - skip to step 8. If you've made your *own* edits since then (e.g. adjusting `env_config` in `terraform/live/main.tf`), treat just those like the case above.

## 8. Let the real pipeline deploy the backend, then the frontend

`cd.yml` on a push to `main` is what does the actual deploy: build → test → push to ECR → `repository_dispatch` → `conduit-platform`'s `deploy-backend.yml` runs `helmfile apply` for the backend, waits for the ALB, runs the k6 smoke+perf check, and publishes the ALB hostname to SSM. Same two cases as step 7 apply to how it gets started:

> **Step 7 just pushed for the first time**: that push already triggered it (steps 1-6 had already set up everything it needs to authenticate, so it should succeed). Just watch it:
> ```bash
> gh run watch --repo "$GITHUB_ORG/$BACKEND_REPO"
> ```

> **Your code was already on GitHub before you started this guide** (step 7 was a no-op): `cd.yml` already ran once, back when it was first pushed - before the `dev` GitHub Environment existed, so that run failed within seconds and won't retry on its own. Trigger it explicitly instead:
> ```bash
> gh workflow run cd.yml --repo "$GITHUB_ORG/$BACKEND_REPO"
> gh run watch --repo "$GITHUB_ORG/$BACKEND_REPO"
> ```

Either way, once the backend's run finishes, explicitly (re-)trigger the frontend so it picks up the now-published backend URL - even if its own push already fired automatically, that would have raced ahead of the backend publishing anything to SSM:
```bash
gh workflow run cd.yml --repo "$GITHUB_ORG/$FRONTEND_REPO"
gh run watch --repo "$GITHUB_ORG/$FRONTEND_REPO"
```

## 9. Verify end to end

```bash
# Backend directly
kubectl get ingress conduit-backend -n conduit-backend
curl http://<hostname-from-above>/api/ping/

# Frontend - open in a browser
kubectl get ingress conduit-frontend -n conduit-frontend
```
Open that hostname in a browser and use the app - register, create an article, favorite something. Both tiers are plain HTTP ALBs (no TLS on either yet - see `docs/design-decisions.md`'s HTTPS entry for that deliberately-deferred gap), so there's no mixed-content mismatch between them to worry about.

To confirm the backend specifically, independent of the browser:
```bash
BASE="http://<backend-hostname-from-above>/api"
curl -sS "$BASE/tags"
curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" \
  -d '{"user":{"username":"verify","email":"verify@example.com","password":"verifyPass123"}}'
# use the returned token to create an article, etc. - see design-decisions.md's
# HTTPS entry for what closes this gap for real browser use.
```

**Grafana**: this chart version doesn't ship a fixed default password (`adminPassword` is commented out in its own values) - it generates a random one per install, in the same Secret the chart's own `helm install` NOTES point at:
```bash
kubectl get secret --namespace monitoring -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}" | base64 --decode; echo
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```
Open `localhost:3000`, log in as `admin` with that password, open the **Conduit Backend** dashboard. No Ingress/LoadBalancer is set up for Grafana - port-forward is the only way in as things stand (see `docs/design-decisions.md` if you want to change that).

## Tearing down

**Order matters.** Helm-managed resources first, or the ALB the Load Balancer Controller created gets orphaned and blocks the VPC from deleting:

```bash
cd conduit-platform/helm
helmfile -e dev destroy

cd ../terraform/live
terraform destroy
```
