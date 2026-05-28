# 01 — Architecture Overview

> **Goal of this doc:** turn the screenshots in `resourse_images/` into a clear
> mental model of the system we're building, and define our exact target
> architecture (with a diagram you can redraw in an interview).

You don't deploy anything here. This is the blueprint. Come back to it whenever a
later phase makes you ask "wait, where does this piece fit?"

---

## 1. Reading the source diagrams

The diagrams come from AWS Skill Builder's *"Optimizing a cloud architecture"*
course. There are **four** distinct architectures. Let's decode each one.

### Diagram A — The Well-Architected 3-tier web app (the main one)

This is the diagram that appears three times (the florist business example). Read
left to right, it shows how a user's request flows through a resilient web app:

```
Users
  │
  ▼
Amazon CloudFront        ← global CDN / cache (the "front door")
  │
  ▼
Internet Gateway         ← the doorway between the internet and your VPC
  │
  ▼
Application Load Balancer ← spreads traffic across servers, checks their health
  │
  ├──────────────► EC2 instances (Availability Zone 1)  ┐
  │                                                       ├─ managed by an
  └──────────────► EC2 instances (Availability Zone 2)  ┘   Auto Scaling Group
                        │
                        ▼
                  Amazon RDS (a primary DB + a standby in the other AZ)
```

Surrounding that core, the diagram shows the supporting cast:

- **Region** — the big outer box. Everything lives in one AWS Region.
- **VPC (Virtual Private Cloud)** — your own private network inside the Region.
- **Availability Zones** — the VPC spans two AZs (two physically separate data
  centers) so one failing doesn't take you down.
- **Amazon S3** — object storage (file uploads, backups, static assets).
- **IAM + MFA token** — who is allowed to do what; multi-factor login security.
- **AWS Lambda** — run code without managing a server (used for small tasks).
- **Amazon CloudWatch** — metrics, logs, and alarms (the monitoring system).
- **AWS Compute Optimizer** — recommends cheaper/right-sized instances.
- **AWS Cost Explorer / Budgets / Cost & Usage Report** — the money tools.

> 🧠 **Why this is called "3-tier":**
> 1. **Presentation tier** = CloudFront + the frontend.
> 2. **Application/logic tier** = the EC2 instances running your API.
> 3. **Data tier** = RDS (the database).
> Keeping tiers separate lets you scale and secure each independently. This
> separation is the single most important idea in the whole project.

### Diagram B — Serverless backend monitored by X-Ray

```
Traffic → Amazon API Gateway → AWS Lambda → Amazon DynamoDB
                                   │
                              AWS X-Ray (traces each request for a developer)
```

A request hits **API Gateway** (a managed HTTP front door), which invokes a
**Lambda** function (your code, no server), which reads/writes **DynamoDB** (a
NoSQL database). **X-Ray** records a timeline of the request so you can see where
time was spent. No servers to patch, and you pay per request.

### Diagram C — Serverless static website with a contact form

```
Website on Amazon S3 (HTML + a contact form)
        │  (form submit)
        ▼
Amazon API Gateway → AWS Lambda → Amazon SES → email to the business owner
```

The website is just files in **S3**. When a visitor submits the contact form,
JavaScript calls **API Gateway → Lambda**, and Lambda uses **SES** (Simple Email
Service) to email the hospital. Again: zero servers.

### Diagram D — Customer support with a callback option

This one uses **Amazon Connect** (a cloud call-center), CloudFront, and Lambda to
offer chat / call / callback. 💰 **We are NOT building this.** Amazon Connect
bills per minute with no real free tier, and it's a niche skill. We'll mention it
as a "future enhancement" in our README and move on.

---

## 2. Our target architecture (what we will actually build)

We merge **A + B + C** into one system: **CloudCare**, a Hospital Management
System. Here is the full picture. Spend time here — this is the diagram you'll
redraw on a whiteboard.

```
                                   ┌──────────── Users (browsers) ────────────┐
                                   │                                          │
                          (static site + API)                          (contact form)
                                   │                                          │
                                   ▼                                          │
                        ┌─────────────────────┐                              │
                        │  Amazon CloudFront   │  global CDN, HTTPS, caching  │
                        └──────────┬──────────┘                              │
                static assets ◄────┤                                          │
                 (React build)     │ /api/*                                   │
                                   ▼                                          ▼
   ┌──────────────────────── AWS Region: ap-south-1 (Mumbai) ──────────────────────────┐
   │                                                                                    │
   │   S3 bucket            ┌──────────────────── VPC  10.0.0.0/16 ───────────────────┐ │
   │  (React build,         │                                                         │ │
   │   uploads)             │   Internet Gateway                                      │ │
   │       ▲                │        │                                                │ │
   │       │                │        ▼                                                │ │
   │       │                │  ┌───────────── Public subnets (AZ-a, AZ-b) ─────────┐  │ │
   │       │                │  │   Application Load Balancer (ALB)                  │  │ │
   │       │                │  └───────┬───────────────────────────┬──────────────┘  │ │
   │       │                │          │                           │                  │ │
   │       │                │  ┌───────▼──────── Private app subnets (AZ-a, AZ-b) ─▼─┐ │ │
   │       │                │  │   Auto Scaling Group of EC2 (FastAPI in Docker)    │ │ │
   │       │                │  └───────┬───────────────────────────┬───────────────┘ │ │
   │       │                │          │                           │                 │ │
   │       │                │  ┌───────▼──────── Private DB subnets (AZ-a, AZ-b) ──▼─┐ │ │
   │       │                │  │   Amazon RDS (PostgreSQL)  primary  [+ standby*]   │ │ │
   │       │                │  └────────────────────────────────────────────────────┘ │ │
   │       │                └─────────────────────────────────────────────────────────┘ │
   │       │                                                                              │
   │  Serverless side (no VPC needed):                                                    │
   │   API Gateway → Lambda → DynamoDB   (notifications / audit log, traced by X-Ray)     │
   │   API Gateway → Lambda → SES        (contact form → email to hospital admin)         │
   │                                                                                      │
   │  Cross-cutting:  IAM (identities & permissions) · CloudWatch (logs/metrics/alarms)   │
   │                  Cost Explorer / Budgets (money) · Secrets Manager (DB password)     │
   └──────────────────────────────────────────────────────────────────────────────────────┘

   * the standby (Multi-AZ) is written and explained in Terraform but kept OFF by
     default to stay free. We turn it on only to practice, then turn it off.
```

### The request journey (memorize this)

1. A user opens `cloudcare.example` in their browser.
2. **CloudFront** serves the cached React app (HTML/JS/CSS) from the nearest edge
   location. Fast, and it offloads work from our servers.
3. The React app calls `/api/...`. CloudFront forwards `/api/*` requests to the
   **Application Load Balancer**.
4. The **ALB** picks a healthy **EC2** instance (in either AZ) and forwards the
   request.
5. The **FastAPI** app on that EC2 instance runs the logic and queries **RDS
   PostgreSQL** for patient/appointment data.
6. The response travels back the same path. Some side-features (notifications,
   contact form) instead go through **API Gateway → Lambda** — no EC2 involved.
7. The whole time, **CloudWatch** is collecting logs and metrics, and **IAM** is
   enforcing who/what is allowed to touch each resource.

---

## 3. Why each layer exists (the interview answers)

| Layer | What it does | What breaks without it |
|-------|--------------|------------------------|
| **CloudFront** | Caches + serves content globally over HTTPS | Slow sites for far-away users; servers do all the work |
| **VPC** | Private, isolated network you control | Resources exposed on the public internet by default |
| **Public subnet** | Holds things that *must* face the internet (ALB) | No safe place for internet-facing components |
| **Private subnet** | Holds things that must **not** be reachable directly (EC2, RDS) | Your app servers and DB exposed to attackers |
| **Internet Gateway** | The VPC's door to the internet | VPC can't send/receive internet traffic |
| **ALB** | Distributes traffic, health-checks servers, single entry point | One server gets overloaded; no failover |
| **Auto Scaling Group** | Keeps the right number of EC2 instances, replaces dead ones | Manual scaling; an instance dies and stays dead |
| **EC2** | Runs your application code | Nowhere to run the API |
| **RDS** | Managed relational database (backups, patching) | You hand-manage a fragile DB |
| **S3** | Cheap, durable file/object storage | Nowhere to store the frontend build or uploads |
| **Lambda + API Gateway** | Run small features without servers | Pay for idle servers to do tiny jobs |
| **DynamoDB** | Fast NoSQL store for serverless features | No serverless-friendly database |
| **IAM** | Identities + least-privilege permissions | Everything can do everything = disaster |
| **CloudWatch** | Logs, metrics, alarms | You're blind when something breaks |

---

## 4. How this maps to the AWS Well-Architected Framework

AWS evaluates designs against six "pillars." Knowing these by name is interview
gold. Here's how our design touches each:

1. **Operational Excellence** — everything is Terraform (repeatable),
   CloudWatch gives us visibility, CI/CD automates deploys.
2. **Security** — private subnets, least-privilege IAM, security groups, MFA on
   the account, secrets in Secrets Manager (never in code).
3. **Reliability** — multiple AZs, Auto Scaling replaces failed instances, ALB
   health checks, RDS automated backups.
4. **Performance Efficiency** — CloudFront caching, right-sized instances,
   serverless for spiky workloads.
5. **Cost Optimization** — free-tier sizing, destroy-when-idle, Budgets +
   Cost Explorer, Compute Optimizer recommendations.
6. **Sustainability** — serverless and auto-scaling reduce idle waste (this is
   literally what one of your screenshots is about).

> 🧠 In an interview, when asked "how would you design X?", structuring your
> answer around these six pillars makes you sound senior. We'll reinforce them in
> every phase.

---

## 5. What we deliberately simplify (and why it's OK)

| Real production | Our learning version | Why it's fine |
|-----------------|----------------------|---------------|
| Multi-AZ RDS (auto failover) | Single-AZ, but we *write* the Multi-AZ config | Multi-AZ doubles DB cost; we explain + demo briefly |
| NAT Gateway for private egress | VPC endpoints / NAT instance only when needed | NAT GW is ~$32/mo + data — the #1 surprise bill |
| 2+ EC2 always on | Usually 1, scale to 2 to demo | 2 × `t2.micro` can exceed the 750 free hours |
| Custom domain + ACM cert | CloudFront default domain | A real domain costs money; not needed to learn |
| Always-on stack | Destroy after labs | Protects your ~$100 credit |

None of these change the *concepts* — they only change how long things run. You
will have written the production-grade version of each in Terraform.

---

## ✅ Checkpoint

You're ready for the next doc when you can, from memory:

- Name the three tiers and which AWS service is in each.
- Trace a request from browser to database and back.
- Explain why the database lives in a private subnet, not a public one.
- Name at least three of the six Well-Architected pillars.

Next: **[02 — Core Concepts](02-core-concepts.md)** — we define every networking
and security term used above so the Terraform later isn't mysterious.
