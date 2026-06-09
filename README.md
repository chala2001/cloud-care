# CloudCare HMS — an AWS DevOps showcase

> A small **Hospital Management System** used as the vehicle to build, operate,
> and document a real production-style **AWS environment** with **Terraform** and
> **GitHub Actions**. The interesting work happens under `terraform/` and
> `.github/workflows/` — not in the web UI.

**Region** `ap-south-1` (Mumbai) · **IaC** Terraform 1.9+ ·
**Backend** Python 3.12 + FastAPI · **Frontend** React 18 + Vite ·
**Database** PostgreSQL 16 on RDS · **CI/CD** GitHub Actions + OIDC

---

## Scope — what this repo is and isn't

This project is intentionally focused on the **DevOps and SRE side**:
infrastructure-as-code, networking, IAM, deployment pipelines, observability,
and cost control. The application logic (patients, appointments) is the
simplest possible CRUD that gives the infrastructure something to host.

> **UI/UX is out of scope.** The web frontend exists to prove the stack is wired
> up end-to-end (`CloudFront → S3` for assets, `CloudFront → ALB → EC2 → RDS`
> for the API). It is not designed as a product, and visual polish was not a
> goal. To evaluate this project, read the Terraform stacks, the workflows, and
> the architecture sections below.

---

## Tech stack

Twenty-one tools, grouped by what they do in the system.

<table>
  <tr>
    <td width="33%" valign="top">
      <h4>Cloud &amp; IaC</h4>
      <p>
        <img src="https://img.shields.io/badge/AWS-232F3E?style=for-the-badge&logo=amazonwebservices&logoColor=white" alt="AWS"/>
        <img src="https://img.shields.io/badge/Terraform%201.9-7B42BC?style=for-the-badge&logo=terraform&logoColor=white" alt="Terraform"/>
        <img src="https://img.shields.io/badge/S3%20%2B%20DynamoDB%20state-FF9900?style=for-the-badge&logo=amazon&logoColor=white" alt="S3+DDB state"/>
      </p>
      <sub>Infrastructure declared once, applied from anywhere; remote state with locking.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Network</h4>
      <p>
        <img src="https://img.shields.io/badge/VPC-232F3E?style=for-the-badge&logo=amazonaws&logoColor=white" alt="VPC"/>
        <img src="https://img.shields.io/badge/Subnets-232F3E?style=for-the-badge" alt="Subnets"/>
        <img src="https://img.shields.io/badge/NACLs-DD344C?style=for-the-badge" alt="NACLs"/>
        <img src="https://img.shields.io/badge/Security%20Groups-DD344C?style=for-the-badge" alt="Security Groups"/>
      </p>
      <sub>Custom VPC across 2 AZs; defense-in-depth via SG chain plus stateless NACL backstops.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Compute</h4>
      <p>
        <img src="https://img.shields.io/badge/EC2-FF9900?style=for-the-badge&logo=amazonec2&logoColor=white" alt="EC2"/>
        <img src="https://img.shields.io/badge/Auto%20Scaling-FF9900?style=for-the-badge" alt="ASG"/>
        <img src="https://img.shields.io/badge/ALB-FF9900?style=for-the-badge" alt="ALB"/>
        <img src="https://img.shields.io/badge/ECR-FF9900?style=for-the-badge" alt="ECR"/>
        <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker"/>
      </p>
      <sub>Auto-healing ASG of <code>t3.micro</code> instances behind an ALB; container images in ECR.</sub>
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>Data</h4>
      <p>
        <img src="https://img.shields.io/badge/RDS%20PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="RDS PostgreSQL"/>
        <img src="https://img.shields.io/badge/DynamoDB-4053D6?style=for-the-badge&logo=amazondynamodb&logoColor=white" alt="DynamoDB"/>
        <img src="https://img.shields.io/badge/Secrets%20Manager-DD344C?style=for-the-badge" alt="Secrets Manager"/>
      </p>
      <sub>Relational data on private RDS; audit events on DynamoDB; DB password generated into Secrets Manager.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Serverless</h4>
      <p>
        <img src="https://img.shields.io/badge/Lambda-FF9900?style=for-the-badge&logo=awslambda&logoColor=white" alt="Lambda"/>
        <img src="https://img.shields.io/badge/API%20Gateway-FF4F8B?style=for-the-badge" alt="API Gateway"/>
        <img src="https://img.shields.io/badge/SES-DD344C?style=for-the-badge" alt="SES"/>
      </p>
      <sub>HTTP APIs in front of Lambda; SES for transactional email from the contact form.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Edge</h4>
      <p>
        <img src="https://img.shields.io/badge/CloudFront-8C4FFF?style=for-the-badge" alt="CloudFront"/>
        <img src="https://img.shields.io/badge/S3%20%28static%29-569A31?style=for-the-badge&logo=amazons3&logoColor=white" alt="S3 static"/>
      </p>
      <sub>One HTTPS origin for the whole app; static SPA from private S3 via Origin Access Control.</sub>
    </td>
  </tr>
  <tr>
    <td width="33%" valign="top">
      <h4>Observability</h4>
      <p>
        <img src="https://img.shields.io/badge/CloudWatch-FF4F8B?style=for-the-badge&logo=amazoncloudwatch&logoColor=white" alt="CloudWatch"/>
        <img src="https://img.shields.io/badge/SNS-FF4F8B?style=for-the-badge" alt="SNS"/>
        <img src="https://img.shields.io/badge/X--Ray-FF4F8B?style=for-the-badge" alt="X-Ray"/>
      </p>
      <sub>Metrics, logs, and alarms across every tier; SNS fan-out; X-Ray traces the serverless paths.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Identity &amp; CI/CD</h4>
      <p>
        <img src="https://img.shields.io/badge/IAM%20%2B%20OIDC-DD344C?style=for-the-badge" alt="IAM + OIDC"/>
        <img src="https://img.shields.io/badge/GitHub%20Actions-2088FF?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions"/>
      </p>
      <sub>Least-privilege IAM with condition keys; keyless CI auth via OIDC federation.</sub>
    </td>
    <td width="33%" valign="top">
      <h4>Application</h4>
      <p>
        <img src="https://img.shields.io/badge/FastAPI-009688?style=for-the-badge&logo=fastapi&logoColor=white" alt="FastAPI"/>
        <img src="https://img.shields.io/badge/React-61DAFB?style=for-the-badge&logo=react&logoColor=black" alt="React"/>
        <img src="https://img.shields.io/badge/Vite-646CFF?style=for-the-badge&logo=vite&logoColor=white" alt="Vite"/>
      </p>
      <sub>Python 3.12 backend, React 18 SPA built with Vite — the simplest CRUD needed to wire the stack.</sub>
    </td>
  </tr>
</table>

---

## Engineering practices demonstrated

The ten disciplines this project deliberately exercises. These are the things
to grep the repo for, not "features":

| # | Practice | Where to find it |
|---|----------|-------------------|
| 1 | **Remote state with locking** — Terraform safe to run from multiple machines / CI | `terraform/bootstrap/` (S3 + DynamoDB) |
| 2 | **Per-stack state isolation** — cross-stack reads via `terraform_remote_state`, never re-declaration | every stack's `backend.s3.key` |
| 3 | **Least-privilege IAM** — resource-scoped policies, condition keys (e.g. `ses:FromAddress`, `aws:SourceArn`) | `terraform/{compute,serverless-contact,cdn}/iam.tf` |
| 4 | **Multi-AZ networking** — public / private app / private DB subnets across two AZs | `terraform/network/{subnets,routing}.tf` |
| 5 | **Immutable image deploys** — ECR push + ASG `start-instance-refresh` rollout | `.github/workflows/backend.yml` |
| 6 | **Static assets through CloudFront** — private S3 via OAC, cache invalidation on every deploy | `terraform/cdn/` + `.github/workflows/frontend.yml` |
| 7 | **Workflow concurrency** — prevents state-lock and refresh races on rapid pushes | `.github/workflows/terraform.yml` `concurrency:` |
| 8 | **Observability across three pillars** — metrics, logs, traces (X-Ray) | `terraform/observability/`, Lambda `tracing_config` |
| 9 | **Cost controls** — Budgets, billing alarm, free-tier-aware sizing, NAT instance over Gateway | [Doc 03](docs/03-aws-account-and-cost-safety.md), `terraform/compute/nat.tf` |
| 10 | **Keyless GitHub Actions auth** — OIDC federation, `sub` claim pinned to repo + refs | `terraform/cicd/oidc.tf` |

---

## Table of contents

- [Architecture at a glance](#architecture-at-a-glance)
- [Architecture diagram](#architecture-diagram)
- [Request flow](#request-flow)
- [Network topology](#network-topology)
- [Security architecture](#security-architecture)
- [Data model](#data-model)
- [Repository structure](#repository-structure)
- [Infrastructure modules](#infrastructure-modules)
- [Prerequisites](#prerequisites)
- [Quick start — deploy from scratch](#quick-start--deploy-from-scratch)
- [Local development](#local-development)
- [CI/CD pipeline](#cicd-pipeline)
- [Observability](#observability)
- [Cost](#cost)
- [Teardown](#teardown)
- [Documentation & learning path](#documentation--learning-path)

---

## Architecture at a glance

Users hit **CloudFront**. Static React assets come from an **S3** bucket via
Origin Access Control. API requests (`/api/*`) are forwarded to an
**Application Load Balancer**, which routes them to an **Auto Scaling Group**
of EC2 instances running the FastAPI backend container pulled from **ECR**. The
backend talks to a private **RDS PostgreSQL** instance using credentials
fetched at boot from **Secrets Manager** via the instance's IAM role.

Side flows run on **serverless**: a contact form posts to
`API Gateway → Lambda → SES`, and audit events go to
`API Gateway → Lambda → DynamoDB` with X-Ray tracing. **CloudWatch** collects
metrics and logs across every tier, with alarms fanning out through **SNS** to
email.

---

## Architecture diagram

The full system at a glance. Public traffic enters through CloudFront; the
three-tier path sits in a VPC; two serverless features hang off API Gateway.

```mermaid
flowchart TB
    User([Users])

    subgraph Edge["AWS Edge"]
        CF["Amazon CloudFront<br/>(HTTPS, free *.cloudfront.net cert)"]
    end

    S3["S3 bucket<br/>(React SPA, private + OAC)"]

    subgraph VPC["VPC 10.0.0.0/16 — ap-south-1"]

        IGW{{Internet Gateway}}

        subgraph Pub["Public subnets (AZ-a, AZ-b)"]
            ALB["Application<br/>Load Balancer"]
            NAT["NAT Instance<br/>t3.micro"]
        end

        subgraph AppT["Private app subnets (AZ-a, AZ-b)"]
            ASG["Auto Scaling Group<br/>EC2 t3.micro<br/>FastAPI in Docker"]
        end

        subgraph DBT["Private DB subnets (AZ-a, AZ-b)"]
            RDS[("RDS PostgreSQL<br/>encrypted, single-AZ")]
        end
    end

    subgraph AWSsvc["AWS Services"]
        ECR[("ECR<br/>Docker images")]
        SM[("Secrets Manager<br/>DB credentials")]
        CW["CloudWatch<br/>logs · metrics · alarms"]
    end

    subgraph SL["Serverless slices"]
        APIa["API Gateway<br/>Audit"]
        Laud["Lambda<br/>audit-handler"]
        DDB[("DynamoDB<br/>audit events")]
        APIc["API Gateway<br/>Contact"]
        Lcon["Lambda<br/>contact-handler"]
        SES["Amazon SES"]
        XR["AWS X-Ray"]
    end

    User -- HTTPS --> CF
    CF -- "/*" --> S3
    CF -- "/api/*" --> ALB

    IGW --- ALB
    IGW --- NAT
    ALB -- ":8000" --> ASG
    ASG -- ":5432" --> RDS
    ASG -.->|pull image| NAT
    NAT --> IGW
    ASG -. pull .-> ECR
    ASG -. GetSecretValue .-> SM
    ASG -. logs/metrics .-> CW

    User -- HTTPS --> APIa
    User -- HTTPS --> APIc
    APIa --> Laud
    Laud --> DDB
    Laud -.-> XR
    APIc --> Lcon
    Lcon --> SES
```

> The data tier is unreachable from anywhere except the app tier: it sits in a
> private subnet, has no public route, and its security group only trusts the
> app security group. Three independent locks.

---

## Request flow

A typical "load the patients page, then add a patient" sequence, with first-time
boot calls included:

```mermaid
sequenceDiagram
    actor User
    participant CF as CloudFront
    participant S3 as S3 (SPA)
    participant ALB as ALB
    participant EC2 as EC2 (FastAPI)
    participant SM as Secrets Manager
    participant RDS as RDS PostgreSQL

    rect rgb(238,245,255)
    Note over User,RDS: First page load (static)
    User->>CF: GET /
    CF->>S3: GET index.html (OAC, SigV4)
    S3-->>CF: 200 OK
    CF-->>User: 200 (cached at edge)
    end

    rect rgb(238,255,238)
    Note over User,RDS: First boot of an instance
    EC2->>SM: GetSecretValue(cloudcare/db/credentials)
    SM-->>EC2: { username, password, host, ... }
    end

    rect rgb(255,245,235)
    Note over User,RDS: API call
    User->>CF: POST /api/patients { ... }
    CF->>ALB: forward (origin: alb-api)
    ALB->>EC2: forward to healthy target :8000
    EC2->>RDS: INSERT INTO patients ...
    RDS-->>EC2: row
    EC2-->>ALB: 201 Created
    ALB-->>CF: 201
    CF-->>User: 201 Created
    end
```

---

## Network topology

Six subnets across two AZs, three tiers, two route tables:

```mermaid
flowchart TB
    Internet((Internet))
    IGW{{Internet Gateway}}

    subgraph VPC["VPC — 10.0.0.0/16"]

        subgraph AZa["Availability Zone ap-south-1a"]
            PubA["Public subnet<br/>10.0.0.0/24<br/>(ALB, NAT)"]
            AppA["Private app subnet<br/>10.0.10.0/24<br/>(EC2)"]
            DbA["Private db subnet<br/>10.0.20.0/24<br/>(RDS)"]
        end

        subgraph AZb["Availability Zone ap-south-1b"]
            PubB["Public subnet<br/>10.0.1.0/24<br/>(ALB, standby)"]
            AppB["Private app subnet<br/>10.0.11.0/24<br/>(EC2)"]
            DbB["Private db subnet<br/>10.0.21.0/24<br/>(RDS standby)"]
        end

        RTpub["Public route table<br/>0.0.0.0/0 → IGW"]
        RTpriv["Private route table<br/>0.0.0.0/0 → NAT instance"]
    end

    Internet --- IGW
    IGW --- PubA
    IGW --- PubB

    PubA -.assoc.-> RTpub
    PubB -.assoc.-> RTpub
    AppA -.assoc.-> RTpriv
    AppB -.assoc.-> RTpriv
    DbA  -.assoc.-> RTpriv
    DbB  -.assoc.-> RTpriv
```

| CIDR | Tier | Public? | Purpose |
|------|------|---------|---------|
| `10.0.0.0/24`, `10.0.1.0/24` | Public | ✅ (route → IGW) | ALB, NAT instance |
| `10.0.10.0/24`, `10.0.11.0/24` | App (private) | ❌ (egress via NAT) | EC2 ASG |
| `10.0.20.0/24`, `10.0.21.0/24` | DB (private) | ❌ (local only) | RDS PostgreSQL |

> The DB subnets have **no NAT route either** — the database has zero egress.
> Only the app subnets route through the NAT instance, and only for outbound
> connections initiated from inside.

---

## Security architecture

### Defense in depth — the security-group chain

Each tier accepts traffic **only from the tier directly in front of it**, by
referencing the upstream *security group*, not an IP range:

```mermaid
flowchart LR
    I([Internet]) -- ":80, :443" --> ALB["alb-sg"]
    ALB -- ":8000<br/>(SG reference)" --> A["app-sg"]
    A -- ":5432<br/>(SG reference)" --> D["db-sg"]

    style ALB fill:#dbeafe,stroke:#1d4ed8,color:#000
    style A   fill:#fef3c7,stroke:#b45309,color:#000
    style D   fill:#fee2e2,stroke:#b91c1c,color:#000
```

| SG | Ingress | Source | Egress |
|----|---------|--------|--------|
| `alb-sg` | 80, 443 (TCP) | `0.0.0.0/0` | all |
| `app-sg` | 8000 (TCP) | **`alb-sg`** | all |
| `db-sg`  | 5432 (TCP) | **`app-sg`** | all |

NACLs sit one layer below as stateless subnet guards (allow VPC-internal, allow
ephemeral return ports on public). They're coarse on purpose — the SGs do the
precise work.

### IAM principles applied

- **No long-lived AWS keys in GitHub** — CI authenticates via GitHub OIDC →
  `sts:AssumeRoleWithWebIdentity` → 1-hour creds per job, scoped via the `sub`
  claim to `repo:owner/name:ref:refs/heads/main` and `pull_request`.
- **No credentials on EC2** — instances use an IAM instance profile with
  `secretsmanager:GetSecretValue` scoped to the **exact** DB secret ARN.
- **Contact-form Lambda** cannot impersonate other senders — `ses:SendEmail` is
  conditioned on `ses:FromAddress = <our verified sender>`.
- **CloudFront-only S3 access** — S3 bucket policy allows reads from
  `cloudfront.amazonaws.com` *only when* `aws:SourceArn` matches this
  distribution's ARN.
- **IMDSv2 enforced** on EC2 (`http_tokens = "required"`) to block SSRF-based
  credential theft.

---

## Data model

```mermaid
erDiagram
    PATIENTS ||--o{ APPOINTMENTS : has

    PATIENTS {
        int id PK
        string full_name
        date date_of_birth
        string phone
        datetime created_at
    }

    APPOINTMENTS {
        int id PK
        int patient_id FK
        datetime scheduled_for
        string reason
        string status
    }

    AUDIT_EVENTS {
        string event_id PK
        string ts
        string entity_type
        string entity_id
        string action
        string actor
    }
```

`PATIENTS` and `APPOINTMENTS` live in **RDS PostgreSQL** (the relational, joined
data). `AUDIT_EVENTS` lives in **DynamoDB** (high-volume, write-heavy, simple
key access) — exactly the split DynamoDB and a relational DB exist for.

---

## Repository structure

```
cloud-care/
├── README.md                       ← this file
├── docs/                           ← 21 numbered teaching docs (00–20)
│   └── 00-roadmap.md
├── app/
│   ├── backend/                    ← FastAPI + Dockerfile + docker-compose
│   │   ├── app/{main,config,database,models,schemas}.py
│   │   ├── Dockerfile
│   │   ├── docker-compose.yml
│   │   └── requirements.txt
│   └── frontend/                   ← React + Vite
│       ├── src/{main,App,api}.jsx
│       ├── index.html
│       └── package.json
├── terraform/                      ← 9 independent stacks (own state key each)
│   ├── bootstrap/                  ← S3 state bucket + DynamoDB lock table
│   ├── network/                    ← VPC, subnets, IGW, route tables, NACLs, SGs
│   ├── database/                   ← RDS + Secrets Manager
│   ├── compute/                    ← ALB, ASG, ECR, NAT, IAM
│   ├── cdn/                        ← S3 + CloudFront + OAC
│   ├── serverless-audit/           ← API Gateway + Lambda + DynamoDB + X-Ray
│   ├── serverless-contact/         ← API Gateway + Lambda + SES
│   ├── observability/              ← Dashboard + alarms + SNS
│   └── cicd/                       ← GitHub OIDC provider + deploy role
├── .github/workflows/              ← terraform.yml · backend.yml · frontend.yml
└── resourse_images/                ← reference AWS architecture diagrams
```

---

## Infrastructure modules

Each Terraform stack owns its own state key in the shared backend (`s3://
cloudcare-tfstate-<account>/<stack>/terraform.tfstate`). Stacks consume each
other's outputs via `terraform_remote_state`, never by redeclaration.

```mermaid
flowchart TB
    BS["bootstrap<br/>S3 state + DynamoDB lock"]

    NET["network<br/>VPC · subnets · IGW · RTs · NACLs · SGs"]
    DB["database<br/>RDS · subnet group · Secrets Manager"]
    CMP["compute<br/>ALB · ASG · ECR · NAT · IAM"]
    CDN["cdn<br/>S3 · CloudFront · OAC"]
    SA["serverless-audit<br/>API Gateway · Lambda · DynamoDB"]
    SC["serverless-contact<br/>API Gateway · Lambda · SES"]
    OBS["observability<br/>Dashboard · Alarms · SNS"]
    CICD["cicd<br/>OIDC provider · deploy IAM role"]

    BS -.->|hosts state for all| NET
    NET --> DB
    NET --> CMP
    DB --> CMP
    CMP --> CDN
    CMP --> OBS
    DB --> OBS
    SA --> OBS
    SC --> OBS
```

| Stack | State key | Reads from | Free-tier risk |
|-------|-----------|------------|----------------|
| `bootstrap` | `bootstrap/terraform.tfstate` (local) | — | ✅ ~cents/mo |
| `network` | `network/...` | — | ✅ free |
| `database` | `database/...` | `network` | ⚠️ RDS hours |
| `compute` | `compute/...` | `network`, `database` | ⚠️ ALB + 2× t3.micro hours |
| `cdn` | `cdn/...` | `compute` | ✅ free within tier |
| `serverless-audit` | `serverless/audit/...` | — | ✅ free within tier |
| `serverless-contact` | `serverless/contact/...` | — | ✅ free within tier |
| `observability` | `observability/...` | `compute`, `database`, both serverless | ✅ free within tier |
| `cicd` | `cicd/...` | — | ✅ free |

---

## Prerequisites

- **AWS account** with a non-root IAM admin user, MFA enabled, and budgets configured (see [docs/03](docs/03-aws-account-and-cost-safety.md))
- **AWS CLI v2** authenticated as that admin (`aws sts get-caller-identity` succeeds)
- **Terraform** `>= 1.5`
- **Docker** + **Docker Compose**
- **Node.js** 20+ (for the frontend)
- **Python** 3.12 (for local backend dev, optional — Docker is enough)
- A **GitHub repo** if you want CI/CD (Phase 8)

---

## Quick start — deploy from scratch

The stacks must be applied in dependency order. Each phase has a dedicated doc
with full explanation; below is the minimal command sequence.

### 1. Bootstrap the Terraform state backend

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=cloudcare-tfstate-$(aws sts get-caller-identity --query Account --output text)"
```

### 2. Network → Database → Compute

```bash
for stack in network database compute; do
  ( cd "terraform/$stack" && terraform init && terraform apply -auto-approve )
done
```

### 3. Push the backend image to ECR

```bash
REGION=ap-south-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO=$(cd terraform/compute && terraform output -raw ecr_repository_url)

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

( cd app/backend && docker build -t "$REPO:latest" . && docker push "$REPO:latest" )

# Roll the ASG so instances pull the freshly-pushed image:
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$(cd terraform/compute && terraform output -raw asg_name)"
```

### 4. CDN → upload the frontend → invalidate

```bash
( cd terraform/cdn && terraform init && terraform apply -auto-approve )

BUCKET=$(cd terraform/cdn && terraform output -raw frontend_bucket)
DIST=$(cd terraform/cdn && terraform output -raw cloudfront_distribution_id)

( cd app/frontend && npm ci && npm run build )
aws s3 sync app/frontend/dist/ "s3://$BUCKET/" --delete
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*"
```

### 5. Serverless + observability + CI/CD (optional)

```bash
for stack in serverless-audit serverless-contact observability cicd; do
  ( cd "terraform/$stack" && terraform init && terraform apply )
done
```

### 6. Verify

```bash
CF=$(cd terraform/cdn && terraform output -raw cloudfront_domain_name)
echo "Open https://$CF/  — that's CloudCare."

curl "https://$CF/health"
curl "https://$CF/api/patients"
```

---

## Local development

Run the backend and a throwaway Postgres locally with Docker Compose:

```bash
cd app/backend
docker compose up --build
# API on http://localhost:8000   |  Swagger UI on http://localhost:8000/docs
```

Then run the frontend (Vite dev server, hot reload):

```bash
cd app/frontend
npm install
npm run dev
# Open http://localhost:5173
```

Configure the frontend's API base via an env file:

```bash
# app/frontend/.env.local
VITE_API_URL=http://localhost:8000
```

To point the local frontend at the **deployed** API:

```bash
VITE_API_URL="https://$(cd ../../terraform/cdn && terraform output -raw cloudfront_domain_name)" npm run dev
```

---

## CI/CD pipeline

GitHub Actions authenticates to AWS via OIDC — no long-lived AWS keys are ever
stored in GitHub. Each workflow only runs when files in its scope change.

```mermaid
flowchart LR
    Dev([Developer]) -->|push / PR| GH[GitHub Repo]

    subgraph GHA["GitHub Actions"]
        TF["terraform.yml<br/>plan on PR<br/>apply on main"]
        BE["backend.yml<br/>build · push · roll ASG"]
        FE["frontend.yml<br/>build · sync · invalidate"]
    end

    GH --> TF
    GH --> BE
    GH --> FE

    TF -- "OIDC<br/>AssumeRoleWithWebIdentity" --> STS[(AWS STS)]
    BE -- "OIDC<br/>AssumeRoleWithWebIdentity" --> STS
    FE -- "OIDC<br/>AssumeRoleWithWebIdentity" --> STS

    STS --> Role["IAM role:<br/>cloudcare-github-deploy<br/>(trust: repo:owner/name<br/>refs: main · PR)"]

    Role --> ECR[ECR push]
    Role --> ASG[ASG instance refresh]
    Role --> S3O[S3 sync]
    Role --> CFI[CloudFront invalidation]
    Role --> TFA[terraform apply]
```

| Trigger | Workflow | What runs |
|---------|----------|-----------|
| PR touches `terraform/**` | `terraform.yml` | `terraform plan` for every stack |
| Push to `main`, `terraform/**` | `terraform.yml` | `terraform apply` for every stack (dependency-ordered) |
| Push to `main`, `app/backend/**` | `backend.yml` | `docker build/push` + `start-instance-refresh` |
| Push to `main`, `app/frontend/**` | `frontend.yml` | `npm run build` + `s3 sync` + CloudFront invalidate |

---

## Observability

A single CloudWatch dashboard (`cloudcare-overview`) shows ALB traffic & errors,
healthy host count, RDS CPU/connections/storage, and Lambda invocations &
errors — at a glance.

Alarms publish to one SNS topic (`cloudcare-ops-alerts`) which fans out to email
today and can fan out to Slack/PagerDuty later without changing any alarm:

| Alarm | Threshold | Why this threshold |
|-------|-----------|---------------------|
| `cloudcare-alb-5xx` | `≥ 5 5xx in 5 min` | Single error is noise; sustained is signal |
| `cloudcare-alb-no-healthy-hosts` | `< 1 healthy for 2 min` | The site is down — page immediately |
| `cloudcare-rds-cpu-high` | `> 80% avg over 10 min` | Brief spikes are normal; sustained means trouble |
| `cloudcare-rds-storage-low` | `< 2 GB free` | Lead time to expand before writes fail |
| `cloudcare-rds-connections-high` | `> 80 conns avg over 10 min` | `db.t3.micro` caps near 100 |
| `cloudcare-audit-lambda-errors` | `≥ 1 in 5 min` | Lambda errors should be 0 |
| `cloudcare-contact-lambda-errors` | `≥ 1 in 5 min` | Same |
| `cloudcare-ddb-throttled` | `≥ 1 throttle in 5 min` | On-demand shouldn't ever throttle at our scale |

Cost telemetry: **Budgets** (Doc 03) for tripwire alerts, **Cost Explorer** for
attribution by `Project = cloudcare` tag, **Compute Optimizer** for right-sizing
recommendations.

---

## Cost

Designed to live inside the AWS Free Tier when run for ≤ 750 hours/month of
each free-tier-eligible resource. The key habits:

- One `t3.micro` app instance (`desired = 1`); scale to 2 only briefly
- Single-AZ RDS `db.t3.micro` (Multi-AZ written but `false` by default)
- A **NAT instance**, not a NAT Gateway (~$32/mo saved)
- Frontend on CloudFront's always-free tier (1 TB out + 10M HTTPS requests/mo)
- Lambda + DynamoDB + X-Ray always-free quotas dwarf lab usage
- **Destroy after each lab** — only `network/` and `bootstrap/` are left running

> The roadmap doc tracks a four-month part-time learning pace; the only things
> intentionally left running are nearly free. A surprise bill should be
> impossible — Doc 03's budgets, billing alarm, and free-tier alerts all email
> you long before any real spend.

---

## Teardown

Destroy in reverse-dependency order to return to ~$0:

```bash
for stack in observability cdn compute database serverless-contact \
             serverless-audit cicd network; do
  ( cd "terraform/$stack" && terraform destroy -auto-approve )
done
```

Leave `bootstrap/` alone — it holds the state for everything else and costs
cents per month. Bring the whole stack back with one apply loop in
reverse order (see [Quick start](#quick-start--deploy-from-scratch) or
[docs/20](docs/20-teardown-and-interview-story.md) for the complete recipe).

---

## Documentation & learning path

This repository was built incrementally as a complete teaching project for AWS
SRE/DevOps fundamentals. The 21 docs in [`docs/`](docs/) walk through every
phase with the *what*, *why*, and *how* — full Terraform code, design
trade-offs, AWS console verification steps, and interview-relevant framing.

Start at the [**roadmap**](docs/00-roadmap.md) for the full 8-phase plan, or
jump to any phase below:

| Phase | Topic | Docs |
|------:|-------|------|
| 0 | Foundations · account · tooling · Terraform · state backend | [00](docs/00-roadmap.md)–[06](docs/06-remote-state-backend.md) |
| 1 | Networking · VPC · SGs · NACLs | [07](docs/07-networking-vpc-and-subnets.md), [08](docs/08-networking-security-groups-and-nacls.md) |
| 2 | Compute · ASG · ALB | [09](docs/09-compute-launch-template-and-asg.md), [10](docs/10-compute-application-load-balancer.md) |
| 3 | Database · RDS · Secrets Manager | [11](docs/11-database-rds-postgresql.md) |
| 4 | Application · FastAPI · EC2 deploy · React | [12](docs/12-application-fastapi-backend.md), [13](docs/13-application-deploy-to-ec2.md), [14](docs/14-application-react-frontend.md) |
| 5 | Content delivery · S3 · CloudFront | [15](docs/15-content-delivery-s3-cloudfront.md) |
| 6 | Serverless · Lambda · DynamoDB · SES · X-Ray | [16](docs/16-serverless-audit-log-lambda-dynamodb.md), [17](docs/17-serverless-contact-form-lambda-ses.md) |
| 7 | Observability & cost | [18](docs/18-observability-and-cost.md) |
| 8 | CI/CD · teardown · the interview story | [19](docs/19-cicd-github-actions.md), [20](docs/20-teardown-and-interview-story.md) |

---

<sub>Architecture references: AWS Well-Architected Framework · AWS Skill
Builder "Optimizing a cloud architecture" (original diagrams under
`resourse_images/`).</sub>
