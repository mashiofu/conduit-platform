# Backup & Restore

## What's backed up, and why

| Tier | Backed up? | Mechanism |
|---|---|---|
| RDS Postgres | Yes | Automated daily snapshots + point-in-time recovery (PITR), retention set per environment in `terraform/live/main.tf`'s `env_config` (`backup_retention_days` in `modules/rds`) |
| Frontend S3 bucket | Yes | Versioning (every deploy's objects recoverable), lifecycle-capped at 30 days of noncurrent versions |
| Terraform state bucket | Yes | Versioning, lifecycle-capped at 90 days (kept longer - it's the audit trail of every infra change, and tiny) |
| ElastiCache Redis | **No, deliberately** | It's a read-through cache for anonymous GET responses (see the backend's `cache` package), never a source of truth. Losing it costs some latency until it re-warms, not data. A snapshot/restore story here would be solving a problem that doesn't exist. |
| EKS cluster / in-cluster state | **No backup needed** | Nothing in the cluster is stateful - no PVs, no StatefulSets. Every workload is either stateless (the backend) or itself backed by a managed service (Postgres, Redis) or reconstructible from Helmfile (all the platform add-ons). Re-running `helmfile apply` against a freshly-created cluster reconstructs the entire platform layer from source. |

## Restoring RDS

Two paths, depending on what you're recovering from.

### Path A: point-in-time recovery (the common case - "undo the last N hours/days")

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier conduit-<env>-postgres \
  --target-db-instance-identifier conduit-<env>-postgres-restored \
  --restore-time 2026-08-27T03:00:00Z \
  --db-subnet-group-name conduit-<env>-db \
  --vpc-security-group-ids <the db security group ID - `terraform output` from modules/rds, or look it up: aws rds describe-db-instances --db-instance-identifier conduit-<env>-postgres>
```

This creates a **new** instance (`-restored`), leaving the original untouched - you get a chance to verify the data before committing to a cutover.

### Path B: restore from a specific automated or manual snapshot

```bash
aws rds describe-db-snapshots --db-instance-identifier conduit-<env>-postgres --query 'DBSnapshots[].DBSnapshotIdentifier'

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier conduit-<env>-postgres-restored \
  --db-snapshot-identifier <snapshot-id-from-above> \
  --db-subnet-group-name conduit-<env>-db \
  --vpc-security-group-ids <same as above>
```

### Cutover, either path

1. Wait for the restored instance to reach `available` (`aws rds describe-db-instances --db-instance-identifier conduit-<env>-postgres-restored --query 'DBInstances[0].DBInstanceStatus'`).
2. Verify the data looks right - connect directly and spot-check, or point a scratch backend pod at it.
3. Point the app at it. The cleanest way: update the `ExternalSecret`'s templated `DATABASE_URL` in `helm/backend-chart/templates/externalsecret.yaml` to use the restored instance's endpoint (`aws.rdsEndpoint` in Helmfile values), then `helmfile apply`. This is a deliberate manual edit, not automated - a DB cutover during an incident should have a human looking at it, not a script deciding for you.
4. Once confident, decide whether to keep the old instance around briefly (for further comparison) or decommission it via Terraform (rename the restored one to the identifier Terraform expects, or `terraform import` it, then remove the old one from state/reality).

**Nothing here writes back into Terraform state automatically.** A restore is an imperative, human-in-the-loop action; reconciling Terraform's view of the world with whichever instance is now "the real one" is a deliberate follow-up step, not something to script blindly during an incident.

## Recovering an S3 object (frontend bucket)

Versioning means a deleted or overwritten object isn't gone - it's a noncurrent version:

```bash
aws s3api list-object-versions --bucket conduit-<env>-frontend-mashiofu --prefix <path>

aws s3api copy-object \
  --bucket conduit-<env>-frontend-mashiofu \
  --copy-source "conduit-<env>-frontend-mashiofu/<path>?versionId=<version-id-from-above>" \
  --key <path>
```

Then invalidate CloudFront for that path so cached edge copies don't keep serving the bad version:

```bash
aws cloudfront create-invalidation --distribution-id <id> --paths "/<path>"
```

In practice, the more common "I need last week's frontend back" scenario doesn't need any of this - re-run `promote.yml` (or `cd.yml`) with an older commit's built assets, since the actual source of truth is the git history, not the bucket.
