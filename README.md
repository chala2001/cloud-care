# CloudCare HMS — A Well-Architected AWS Project (from zero)

> A complete, beginner-friendly journey to build a real, industrial-style cloud
> system on AWS using **Terraform**, while staying inside the **AWS Free Tier**.
> The application we build is **CloudCare**, a Hospital Management System (HMS).

This repository is **both a project and a course**. Every step is documented in
`docs/` with the *what*, the *why*, and the *how* — written for someone doing
their **first ever cloud + Terraform project**.

---

## What we are building

We are recreating the AWS *Well-Architected* reference architecture (from the
AWS Skill Builder "Optimizing a cloud architecture" course — the diagrams in
`resourse_images/`) as a working Hospital Management System.

The final system combines three architectures into one project:

1. **Core 3-tier web app** (the heart of the project)
   `Users → CloudFront → Application Load Balancer → Auto Scaling EC2 (FastAPI) → RDS PostgreSQL`,
   all inside a custom **VPC** with public/private **subnets**, **route tables**,
   **NACLs**, **security groups**, an **Internet Gateway**, plus **S3**, **IAM**,
   **CloudWatch**, and **cost controls**.

2. **Serverless feature** — `API Gateway → Lambda → DynamoDB` (traced with
   **X-Ray**) for things like appointment notifications and an audit log.

3. **Serverless contact form** — `S3 static site → API Gateway → Lambda → SES`
   so visitors can email the hospital without a server running.

> The 4th diagram (Amazon Connect customer-support callback) is kept as an
> **optional future enhancement** only — Amazon Connect has no meaningful free
> tier and would eat your credit, so we will not deploy it.

---

## The ground rules of this project

| Rule | Why |
|------|-----|
| **Region: `ap-south-1` (Mumbai)** | Closest cheap, full-service AWS region to Sri Lanka. |
| **Everything in Terraform** | Infrastructure as Code is the #1 SRE/DevOps skill. No "click-ops" except where AWS forces it. |
| **Strict Free Tier + teardown** | We default to the cheapest runnable version of every resource and run `terraform destroy` after each lab. We still *write and explain* the full high-availability version. |
| **Backend: Python FastAPI** | Light enough for a free `t2.micro`, auto-generates API docs, easy to learn. |
| **Frontend: React** | The industry-standard SPA frontend. |
| **Explain everything** | This is a learning project. No magic copy-paste. |

> **Money safety:** Before we deploy *anything*, [Doc 03](docs/03-aws-account-and-cost-safety.md)
> sets up budgets and billing alarms so you get emailed long before you ever
> approach your ~$100 credit. Read it. Do not skip it.

---

## How to use this repository

Work through `docs/` **in order**. Each doc is a self-contained lesson that ends
with a checkpoint. Do not jump ahead — later docs assume earlier ones are done.

### Phase 0 — Foundations (you are here)

| Doc | What you'll learn / do |
|-----|------------------------|
| [00 — Roadmap](docs/00-roadmap.md) | The full 4-month plan and how the phases fit together. |
| [01 — Architecture Overview](docs/01-architecture-overview.md) | Deep read of the diagrams and the exact system we're building. |
| [02 — Core Concepts](docs/02-core-concepts.md) | Cloud, regions/AZs, VPC, IP/CIDR, IAM, load balancing — the vocabulary. |
| [03 — AWS Account & Cost Safety](docs/03-aws-account-and-cost-safety.md) | Create the account, lock down root, MFA, budgets, billing alarms. |
| [04 — Tooling Setup](docs/04-tooling-setup.md) | Install AWS CLI + Terraform on Linux, configure credentials safely. |
| [05 — Terraform Fundamentals](docs/05-terraform-fundamentals.md) | IaC, HCL syntax, providers, resources, variables, state, the workflow. |
| [06 — Remote State Backend](docs/06-remote-state-backend.md) | Your **first `terraform apply`**: an S3 + DynamoDB state backend. |

### Phases 1–8 — coming next (built as you progress)

1. **Networking** — VPC, subnets, IGW, route tables, NACLs, security groups.
2. **Compute** — EC2 launch template, Auto Scaling Group, Application Load Balancer.
3. **Database** — RDS PostgreSQL, secrets, parameter groups.
4. **Application** — the FastAPI backend + React frontend (CloudCare HMS).
5. **Content delivery** — S3 + CloudFront for the frontend.
6. **Serverless** — API Gateway + Lambda + DynamoDB + X-Ray; SES contact form.
7. **Observability** — CloudWatch dashboards, alarms, logs, the Cost tools.
8. **Wrap-up** — CI/CD, the interview story, and a full teardown guide.

See [docs/00-roadmap.md](docs/00-roadmap.md) for the detailed schedule.

---

## Repository layout

```
aws-cloud-deployment/
├── README.md            ← you are here
├── docs/                ← the course: one numbered lesson per file
├── terraform/           ← all infrastructure code (built phase by phase)
├── app/                 ← the CloudCare application (FastAPI + React)
└── resourse_images/     ← the original AWS architecture diagrams
```

---

## Conventions used in the docs

- **`like this`** = something you type, a filename, or a value.
- 💰 = a cost warning. Always read these.
- ✅ **Checkpoint** = stop, verify, and make sure it works before moving on.
- 🧠 **Why it matters** = the interview-relevant concept behind a step.

Start with **[Doc 00 — Roadmap](docs/00-roadmap.md)**.
