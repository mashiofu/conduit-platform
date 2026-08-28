# Architecture

## Runtime

```mermaid
flowchart TB
    User(("Browser"))

    subgraph edge["Edge / CDN"]
        CF["CloudFront"]
        S3["S3 (private)<br/>built Angular SPA"]
    end

    subgraph vpc["VPC - conduit-&lt;env&gt;"]
        ALB["ALB<br/>(AWS Load Balancer Controller)"]

        subgraph eks["EKS cluster"]
            direction TB
            Backend["Backend pods (Go/Gin)<br/>HPA 2-10 replicas"]
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

    User -->|HTTPS| CF --> S3
    User -->|HTTP, API calls| ALB --> Backend
    Backend --> RDS
    Backend --> Redis
    ESO -.reads.-> SM
    ESO -.reads.-> SSM
    ESO -.syncs into cluster Secret.-> Backend
    Prom -.scrapes /metrics.-> Backend
    eks -.container logs.-> CW
```

The frontend is static assets on S3/CloudFront - no compute, no cluster involvement. The backend is the only thing running on EKS. Postgres and Redis are both managed services, not in-cluster state, which is why the cluster itself needs no backup story (see `runbooks/backup-restore.md`).

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
        FCD["cd.yml<br/>build -> S3 (dev) -> CloudFront"]
        FPromote["promote.yml<br/>copy assets, no rebuild"]
    end

    subgraph platformRepo["conduit-platform"]
        TF["terraform.yml<br/>plan on PR, gated apply"]
        Deploy["deploy-backend.yml<br/>helmfile apply + k6 gate"]
    end

    ECR[("ECR")]
    EKS[("EKS cluster")]
    S3B[("S3 + CloudFront")]

    BCD -->|push image| ECR
    BCD -->|repository_dispatch| Deploy
    BPromote -->|repository_dispatch| Deploy
    Deploy -->|helmfile apply| EKS
    Deploy -.publishes ALB hostname to SSM.-> FCD

    FCD --> S3B
    FPromote --> S3B
```

Two IAM roles do all the AWS-side work in `conduit-platform`, and only there: **`terraform-ci`** (broad, runs Terraform) and **`platform-ci`** (EKS-scoped only, runs `helmfile apply`). Neither app repo's CI role can touch the cluster - see `design-decisions.md` for why that split exists and what it costs.
