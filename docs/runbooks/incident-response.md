# Incident Response

## First 5 minutes

1. **Check the Grafana "Conduit Backend" dashboard** (kube-prometheus-stack's Grafana) - request rate, 5xx rate, p95 latency, in one place.
2. **Check which alert fired.** Each alert in `helm/backend-chart/templates/prometheusrule.yaml` maps to a likely cause:

| Alert | Likely cause | Where to look next |
|---|---|---|
| `BackendHighErrorRate` | A bad deploy, a downstream dependency (RDS/Redis) failing, or a genuine bug | CloudWatch Logs Insights saved query `backend-5xx-responses`; check recent deploys in the GitHub Actions history |
| `BackendHighLatencyP95` | DB under load, cold cache (check the cache hit-rate panel), noisy-neighbor CPU throttling | `backend-slow-requests-over-500ms` saved query; Grafana's cache hit-rate panel |
| `BackendPodCrashLooping` | OOMKilled, a panic on startup, a bad config/secret | `kubectl logs -n conduit-backend --previous`, then `errors-across-all-pods` saved query |
| `BackendHPAAtMaxReplicas` | Real load growth, or a regression making requests slower/more expensive | Check whether latency/error rate also degraded; if not, this may just mean it's time to raise `autoscaling.maxReplicas` |
| `BackendCacheHitRateLow` | Informational only - low anonymous traffic, or TTLs too short. Not urgent. | `backend-status-code-distribution` to see traffic mix |

3. **Check recent changes**: `helm/*.generated.yaml` timestamps, the last few `deploy-backend.yml` runs in `conduit-platform`'s Actions tab, and the last few merges in whichever app repo owns the affected tier.

## Rolling back a bad deploy (backend or frontend)

Push-based CD (see `design-decisions.md`) means there's no GitOps revert to click. Both tiers are on the identical immutable-ECR-tag model, so the same two options apply to either - just swap `backend`/`frontend` in the event type and repo name.

**Option A - re-deploy the previous image tag** (seconds, no rebuild):
```bash
# deploy-backend.yml/deploy-frontend.yml only take repository_dispatch, not
# workflow_dispatch - there's no `gh workflow run` for either. Fire the
# dispatch event directly instead, the same way each repo's own cd.yml
# "Trigger deploy" step does. For the backend:
gh api repos/<GITHUB_ORG>/conduit-platform/dispatches --input - <<< \
  '{"event_type":"backend-deploy","client_payload":{"environment":"<env>","image_tag":"<previous-known-good-sha-tag>"}}'
# For the frontend, same shape:
gh api repos/<GITHUB_ORG>/conduit-platform/dispatches --input - <<< \
  '{"event_type":"frontend-deploy","client_payload":{"environment":"<env>","image_tag":"<previous-known-good-sha-tag>"}}'
```
(Find the previous tag from ECR: `aws ecr describe-images --repository-name conduit-<env>-backend --query 'sort_by(imageDetails,& imagePushedAt)[-5:].imageTags'` - swap `backend` for `frontend` for that repo's tags.)

**Option B - revert the commit** in the affected app repo and let its `cd.yml` build+deploy the reverted code normally. Slower (a full CI run), but goes through the same tested path as any other change.

## Rolling back a bad Terraform apply

Terraform doesn't have an automatic "undo" either. Revert the merged PR, open a new PR (so `terraform.yml`'s plan runs and gets reviewed same as any change), then run the `apply` `workflow_dispatch` for the affected environment.

## Escalation

This is a personal project with a single operator, so "escalation" is really "don't be afraid to just stop and look" - kill the affected `workflow_dispatch`/pipeline run rather than let it keep applying against a system already showing symptoms, and prefer the rollback paths above over debugging forward under pressure.
