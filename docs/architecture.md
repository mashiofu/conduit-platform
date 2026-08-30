# Architecture

## Runtime

```mermaid
flowchart TB
    User(("Browser"))

    subgraph vpc["VPC - conduit-&lt;env&gt;"]
        ALBf["ALB (frontend)<br/>(AWS Load Balancer Controller)"]
        ALBb["ALB (backend)<br/>(AWS Load Balancer Controller)"]

        subgraph eks["EKS cluster"]
            direction TB
            subgraph nsFrontend["ns: conduit-frontend"]
                Frontend["Frontend pods (nginx)<br/>HPA 2-4 replicas"]
            end
            subgraph nsBackend["ns: conduit-backend"]
                Backend["Backend pods (Go/Gin)<br/>HPA 2-10 replicas"]
            end
            Prom["kube-prometheus-stack<br/>Prometheus + Grafana + Alertmanager"]
            ESO["External Secrets Operator"]
        end

        subgraph data["Data tier (private subnets)"]
            RDS[("RDS PostgreSQL<br/>Secrets-Manager-managed password")]
            Redis[("ElastiCache Redis<br/>anonymous-read cache only")]
        end
    end

    SM["Secrets Manager"]
    SSM["SSM Parameter Store<br/>(JWT_SECRET)"]
    CW["CloudWatch Logs<br/>+ Container Insights"]

    User -->|HTTP, static assets| ALBf --> Frontend
    User -->|HTTP, API calls - direct from browser JS| ALBb --> Backend
    Backend --> RDS
    Backend --> Redis
    ESO -.reads.-> SM
    ESO -.reads.-> SSM
    ESO -.syncs into cluster Secret.-> Backend
    Prom -.scrapes /metrics.-> Backend
    eks -.container logs.-> CW
```

Both frontend and backend are containerized and run on EKS, each in its own namespace and behind its own ALB - the frontend moved off S3/CloudFront (see `docs/design-decisions.md` for that trade-off, and for why each tier gets its own namespace rather than sharing `default`). Postgres and Redis are both managed services, not in-cluster state, so the cluster itself needs no backup story beyond redeploying from Helmfile (see `runbooks/backup-restore.md`).

## CI/CD

```mermaid
flowchart LR
    subgraph backendRepo["golang-gin-realworld-example-app"]
        BCI["ci.yml<br/>test + Trivy scan"]
        BCD["cd.yml<br/>build -> push ECR (dev)"]
        BPromote["promote.yml<br/>copy image, no rebuild"]
    end

    subgraph frontendRepo["angular-realworld-example-app"]
        FCI["ci.yml<br/>test + build"]
        FCD["cd.yml<br/>build -> push ECR (dev)"]
        FPromote["promote.yml<br/>copy image, no rebuild"]
    end

    subgraph platformRepo["conduit-platform"]
        TF["terraform.yml<br/>plan on PR, gated apply"]
        DeployB["deploy-backend.yml<br/>helmfile apply + k6 gate"]
        DeployF["deploy-frontend.yml<br/>helmfile apply + smoke test"]
    end

    ECR[("ECR<br/>(backend + frontend repos)")]
    EKS[("EKS cluster")]

    BCD -->|push image| ECR
    BCD -->|repository_dispatch| DeployB
    BPromote -->|repository_dispatch| DeployB
    DeployB -->|helmfile apply| EKS
    DeployB -.publishes backend ALB hostname to SSM.-> DeployF

    FCD -->|push image| ECR
    FCD -->|repository_dispatch| DeployF
    FPromote -->|repository_dispatch| DeployF
    DeployF -->|helmfile apply| EKS
```

Two IAM roles do all the AWS-side work in `conduit-platform`, and only there: **`terraform-ci`** (broad, runs Terraform) and **`platform-ci`** (EKS-scoped only, runs `helmfile apply`). Neither app repo's CI role can touch the cluster - see `design-decisions.md` for why that split exists and what it costs.
