# Incident Response

## First 5 minutes

1. **Check the Grafana "Conduit Backend" dashboard** (kube-prometheus-stack's Grafana) - request rate, 5xx rate, p95 latency, in one place.
2. **Check which alert fired.** Each alert in `helm/backend-chart/templates/prometheusrule.yaml` maps to a likely cause:

| Alert | Likely cause | Where to look next |
|---|---|---|
| `BackendHighErrorRate` | A bad deploy, a downstream dependency (RDS/Redis) failing, or a genuine bug | CloudWatch Logs Insights saved query `backend-5xx-responses`; check recent deploys in the GitHub Actions history |
| `BackendHighLatencyP95` | DB under load, cold cache (check the cache hit-rate panel), noisy-neighbor CPU throttling | `backend-slow-requests-over-500ms` saved query; Grafana's cache hit-rate panel |
| `BackendPodCrashLooping` | OOMKilled, a panic on startup, a bad config/secret | `kubectl logs --previous`, then `errors-across-all-pods` saved query |
| `BackendHPAAtMaxReplicas` | Real load growth, or a regression making requests slower/more expensive | Check whether latency/error rate also degraded; if not, this may just mean it's time to raise `autoscaling.maxReplicas` |
| `BackendCacheHitRateLow` | Informational only - low anonymous traffic, or TTLs too short. Not urgent. | `backend-status-code-distribution` to see traffic mix |

3. **Check recent changes**: `helm/*.generated.yaml` timestamps, the last few `deploy-backend.yml` runs in `conduit-platform`'s Actions tab, and the last few merges in whichever app repo owns the affected tier.

## Rolling back a bad backend deploy

Push-based CD (see `design-decisions.md`) means there's no GitOps revert to click. Two options, fastest first:

**Option A - re-deploy the previous image tag** (seconds, no rebuild):
```bash
# From conduit-platform, or trigger deploy-backend.yml manually with:
#   client_payload: { environment: "<env>", image_tag: "<previous known-good sha-tag>" }
gh workflow run deploy-backend.yml -f environment=<env> -f image_tag=<previous-tag>
```
(Find the previous tag from ECR: `aws ecr describe-images --repository-name conduit-<env>-backend --query 'sort_by(imageDetails,& imagePushedAt)[-5:].imageTags'`.)

**Option B - revert the commit** in the backend repo and let `cd.yml` build+deploy the reverted code normally. Slower (a full CI run), but goes through the same tested path as any other change.

## Rolling back a bad Terraform apply

Terraform doesn't have an automatic "undo" either. Revert the merged PR, open a new PR (so `terraform.yml`'s plan runs and gets reviewed same as any change), then run the `apply` `workflow_dispatch` for the affected environment.

## Escalation

This is a personal project with a single operator, so "escalation" is really "don't be afraid to just stop and look" - kill the affected `workflow_dispatch`/pipeline run rather than let it keep applying against a system already showing symptoms, and prefer the rollback paths above over debugging forward under pressure.
