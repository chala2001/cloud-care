# 02 — Core Concepts (the vocabulary)

> **Goal of this doc:** explain every concept and term you'll meet later, in
> plain language, with a hospital analogy where it helps. After this, the
> Terraform code will read like English instead of magic.

This is a reference. Read it once top-to-bottom now, then revisit individual
sections when a later phase uses the term. Nothing here costs money — it's all
ideas.

---

## 1. What "the cloud" actually is

"The cloud" = renting computers and services in someone else's data centers
(here, Amazon's) over the internet, paying only for what you use, and asking for
resources via an API instead of buying hardware.

**Three big benefits** (and the interview phrasing):
- **Elasticity** — get 1 server or 1,000 in minutes; give them back when done.
- **Pay-as-you-go** — no upfront capital; you rent by the hour/second/request.
- **Managed services** — AWS runs the hard parts (DB backups, load balancer
  health, patching) so you don't have to.

**IaaS vs PaaS vs SaaS** (you'll be asked this):
- **IaaS** (Infrastructure) — raw building blocks: EC2 (a virtual machine), VPC.
  *You* manage the OS and app.
- **PaaS** (Platform) — AWS manages more: RDS (database), Lambda (just your code).
- **SaaS** (Software) — a finished product you just use (e.g., Gmail).

---

## 2. The AWS account, Regions, and Availability Zones

### Account
Your **AWS account** is the top-level container and the billing boundary.
Everything you create lives in it. The all-powerful first login is the **root
user** — we will lock it away and never use it for daily work (Doc 03).

### Region
A **Region** is a geographic location with multiple data centers — e.g.
`ap-south-1` is Mumbai, `us-east-1` is N. Virginia. You pick a Region for each
resource. We use **`ap-south-1`** (closest cheap region to Sri Lanka).

> 🧠 Regions are isolated from each other. A resource in Mumbai can't directly
> see one in Virginia unless you connect them. This isolation is a *reliability*
> feature.

### Availability Zone (AZ)
A Region is divided into **Availability Zones** — `ap-south-1a`, `ap-south-1b`,
`ap-south-1c`. Each AZ is one or more physically separate data centers (separate
power, cooling, network) but they're close enough for fast connections.

> 🧠 **The golden rule of reliability:** spread your resources across *at least
> two AZs*. If one AZ catches fire or loses power, the other keeps serving. This
> is exactly why our diagram shows EC2 in AZ-a *and* AZ-b.

**Mental model:**
```
Account
 └── Region (ap-south-1, Mumbai)
      ├── AZ ap-south-1a  (data center #1)
      ├── AZ ap-south-1b  (data center #2)
      └── AZ ap-south-1c  (data center #3)
```

---

## 3. Networking — the part interviews care about most

### 3.1 IP addresses
Every device on a network has an **IP address** — like a postal address for data.
The common form (IPv4) looks like `10.0.1.25`: four numbers (0–255) separated by
dots. Some ranges are **private** (only usable inside a private network, never on
the public internet): `10.x.x.x`, `172.16–31.x.x`, and `192.168.x.x`. We build
our VPC out of the `10.0.0.0` private range.

### 3.2 CIDR notation (this trips everyone up — slow down here)
A network is a *range* of IP addresses, written as **CIDR**: an address + a slash
number, e.g. `10.0.0.0/16`.

The `/number` says **how many bits at the front are fixed** (the "network part").
The remaining bits are free for hosts.

- IPv4 has **32 bits** total.
- `/16` = first 16 bits fixed → 32 − 16 = 16 free bits → 2¹⁶ = **65,536**
  addresses. Range: `10.0.0.0` to `10.0.255.255`.
- `/24` = first 24 bits fixed → 8 free bits → 2⁸ = **256** addresses. Range:
  `10.0.1.0` to `10.0.1.255`.
- `/28` = 4 free bits → **16** addresses.

> Rule of thumb: **bigger slash number = smaller network.** `/16` is huge, `/28`
> is tiny.

Our plan:
```
VPC:            10.0.0.0/16     (65,536 addresses — the whole private city)
 ├ public  AZ-a 10.0.0.0/24     (256 — a neighborhood)
 ├ public  AZ-b 10.0.1.0/24
 ├ app     AZ-a 10.0.10.0/24
 ├ app     AZ-b 10.0.11.0/24
 ├ db      AZ-a 10.0.20.0/24
 └ db      AZ-b 10.0.21.0/24
```
We carve the big `/16` VPC into smaller `/24` subnets, one pair per tier per AZ.
(AWS reserves 5 addresses in every subnet, so a `/24` gives you 251 usable.)

> 🧠 Why plan IP ranges at all? Because they can't overlap if you ever connect
> networks (VPC peering, VPNs, company networks). Picking a clean, non-overlapping
> scheme up front is a sign of someone who's done this before.

### 3.3 VPC (Virtual Private Cloud)
A **VPC** is *your own private, isolated network* inside an AWS Region. You
choose its IP range (CIDR) and decide what's reachable from where. Think of it as
a gated private campus; nothing gets in or out unless you build a road and a gate.

### 3.4 Subnet
A **subnet** is a slice of the VPC's IP range that lives in **one AZ**. You place
resources into subnets. There are two flavors, defined entirely by *routing*:

- **Public subnet** — has a route to the **Internet Gateway**, so things in it
  can be reached from / reach the internet. We put the **ALB** here.
- **Private subnet** — has *no* direct internet route. We put **EC2** and **RDS**
  here so they can't be reached directly from the internet.

> 🧠 "Public" vs "private" isn't a checkbox — a subnet is public *only because*
> its route table sends `0.0.0.0/0` (all traffic) to an Internet Gateway. Remove
> that route and it's private. Interviewers love this distinction.

### 3.5 Route table
A **route table** is a list of rules: "to reach this destination, send traffic
*there*." Each subnet is associated with one route table. Example:
```
Destination     Target
10.0.0.0/16     local              ← traffic inside the VPC stays local
0.0.0.0/0       internet-gateway   ← everything else goes to the internet (public)
```
A private subnet's table simply omits that second line (or points it elsewhere).

### 3.6 Internet Gateway (IGW)
A horizontally-scaled, AWS-managed component that connects your VPC to the public
internet. One per VPC. A subnet is "public" when its route table points
`0.0.0.0/0` at the IGW.

### 3.7 NAT Gateway / NAT instance 💰
A **NAT** lets resources in a *private* subnet make **outbound** connections to
the internet (e.g., to download OS updates) **without** being reachable from the
internet. The managed **NAT Gateway costs ~$32/month + data** — the classic
free-tier killer.

**Our strategy:** avoid the NAT Gateway. We'll get OS packages into private
instances via baked images / S3 / VPC endpoints, or briefly run a tiny **NAT
instance** (a `t2.micro` doing NAT) only when a lab needs egress, then destroy it.

### 3.8 Security Group (SG) vs Network ACL (NACL)
Two firewalls, at two levels. **You will be asked the difference.**

| | Security Group | Network ACL |
|---|---|---|
| Attaches to | An instance/resource (ENI) | A whole subnet |
| State | **Stateful** — reply traffic is auto-allowed | **Stateless** — you must allow return traffic too |
| Rules | **Allow** only | **Allow and Deny** |
| Evaluation | All rules considered | Numbered, lowest first, stops at first match |
| Typical use | Primary control ("EC2 may receive 8000 from the ALB") | Coarse subnet-wide guardrail |

**Analogy:** a Security Group is the *bouncer at each door of a building* who
remembers who he let in (so they can leave). A NACL is the *gate guard for the
whole compound* who checks everyone both ways and follows a strict numbered list.

We rely mainly on Security Groups (clean, stateful) and use NACLs as a coarse
backstop.

### 3.9 How our security groups will chain
```
Internet ──(80/443)──► ALB-SG ──(8000)──► App-SG ──(5432)──► DB-SG
```
- **ALB-SG**: allow 80/443 from anywhere.
- **App-SG**: allow 8000 *only from the ALB-SG* (not the whole internet).
- **DB-SG**: allow 5432 (PostgreSQL) *only from the App-SG*.

Each tier only accepts traffic from the tier in front of it. That's
**defense in depth**.

### 3.10 DNS, HTTP/HTTPS, ports (quick hits)
- **DNS** maps names (`cloudcare.example`) to IP addresses. AWS's DNS service is
  **Route 53**.
- **HTTP** (port **80**) and **HTTPS** (port **443**, encrypted) are how browsers
  talk to web servers. **A port** is just a numbered "channel" on an IP address.
- Our FastAPI app will listen on port **8000**; PostgreSQL uses **5432**.

---

## 4. Identity & access — IAM

**IAM (Identity and Access Management)** controls *who* can do *what* in your
account. Four building blocks:

- **User** — a human identity (you). Has a password and optionally access keys.
- **Group** — a bucket of users sharing permissions (e.g., "Admins").
- **Role** — an identity that's *assumed temporarily*, with no permanent
  password. **Machines use roles.** Our EC2 instance will assume a role to read
  from S3 — so we never store keys on the server.
- **Policy** — a JSON document listing allowed/denied actions. Attached to users,
  groups, or roles.

> 🧠 **Least privilege**: grant only the permissions actually needed, nothing
> more. The opposite ("give it admin so it works") is the most common real-world
> security failure. We'll practice tight policies throughout.

**Root user vs IAM user:** the **root user** (your email login) can do anything,
including close the account. We enable MFA on it and then *never use it*. We do
daily work as an IAM user with admin rights — safer and revocable. (Doc 03.)

---

## 5. Compute — where code runs

- **EC2 (Elastic Compute Cloud)** — a virtual machine you rent by the
  second/hour. You pick CPU/RAM (the *instance type*, e.g. `t2.micro` = 1 vCPU,
  1 GB RAM, free-tier eligible). You manage the OS. Our FastAPI app runs here.
- **AMI (Amazon Machine Image)** — a template (OS + preinstalled software) used
  to launch an EC2 instance. We'll use Amazon Linux 2023.
- **Launch Template** — a saved "recipe" (AMI + instance type + script + SG) that
  the Auto Scaling Group uses to create identical instances.
- **Auto Scaling Group (ASG)** — keeps a desired number of instances running,
  launches replacements when one dies, and can add/remove instances based on
  load. Reliability + elasticity in one feature.
- **Lambda** — you upload a function; AWS runs it on demand and bills per
  request + runtime. No servers, no idle cost. Great for small, spiky tasks
  (our notifications + contact form).
- **Containers (Docker)** — package an app + its dependencies into a portable
  image. We'll run FastAPI as a Docker container on EC2. (AWS also has ECS/EKS to
  orchestrate containers — out of scope, but good to name-drop.)

**EC2 vs Lambda — when to use which:** steady, long-running, stateful work → EC2.
Short, event-driven, spiky work → Lambda. Our design uses *both*, on purpose.

---

## 6. Storage

- **S3 (Simple Storage Service)** — **object** storage: you put/get whole files
  ("objects") into "buckets" via HTTP. Cheap, durable (11 nines), infinitely
  scalable. Great for the React build, uploads, backups, and Terraform state.
  *Not* a filesystem and *not* a database.
- **EBS (Elastic Block Store)** — a virtual hard disk attached to one EC2
  instance. This is where the instance's OS and files live.
- **S3 vs EBS:** EBS is a disk for *one* server (block storage); S3 is a shared
  bucket reachable over the network by *anything* (object storage).

---

## 7. Databases

- **RDS (Relational Database Service)** — managed **SQL** databases (PostgreSQL,
  MySQL, etc.). AWS handles backups, patching, and (optionally) failover. Data is
  structured into tables with relationships. CloudCare's patients/appointments
  live here. We use **PostgreSQL** on a free `db.t3.micro`.
- **DynamoDB** — managed **NoSQL** key-value/document store. Single-digit-ms
  reads, serverless, scales automatically. Great for our Lambda features
  (notifications, audit log). No SQL, no joins; you design around access patterns.
- **SQL vs NoSQL:** SQL = structured, relational, great for complex queries &
  consistency. NoSQL = flexible, fast, scales horizontally, great for simple
  high-volume access patterns. Using both here is a deliberate teaching choice.

- **Secrets Manager** — stores sensitive values (like the DB password) encrypted,
  with rotation. We *never* hardcode passwords in Terraform or code.

---

## 8. Traffic distribution & delivery

- **Application Load Balancer (ALB)** — a Layer-7 (HTTP-aware) load balancer. It
  takes incoming requests and distributes them across healthy targets (our EC2
  instances), running **health checks** and removing unhealthy ones. It can route
  by path (e.g., `/api/*` → app servers). Single, stable entry point.
- **Target Group** — the set of instances the ALB sends traffic to, plus the
  health-check definition.
- **CloudFront** — a **CDN (Content Delivery Network)**: caches your content at
  ~hundreds of edge locations worldwide so users get it from nearby, with HTTPS.
  It fronts both the S3 static site and (via path rules) the ALB.

---

## 9. Observability & cost

- **CloudWatch** — the monitoring hub: **Logs** (app/system logs), **Metrics**
  (CPU %, request counts), **Alarms** (notify/act when a metric crosses a
  threshold), and **Dashboards**. If you can't see it, you can't run it.
- **X-Ray** — distributed tracing: shows the timeline of a single request across
  services (API Gateway → Lambda → DynamoDB), so you can find the slow part.
- **Cost Explorer / Budgets** — visualize spend and get alerted before you blow
  your budget. **Compute Optimizer** suggests right-sizing.

---

## 10. Glossary cheat-sheet

| Term | One-liner |
|------|-----------|
| Region | A geographic AWS location (we use Mumbai `ap-south-1`). |
| AZ | An isolated data center within a Region; use ≥2 for reliability. |
| VPC | Your private, isolated network in a Region. |
| CIDR | IP range notation (`10.0.0.0/16`); bigger slash = smaller net. |
| Subnet | A VPC slice in one AZ; public (has IGW route) or private. |
| IGW | The VPC's door to the internet. |
| NAT | Lets private subnets reach *out* without being reachable *in* (costs $). |
| Security Group | Stateful, allow-only firewall on a resource. |
| NACL | Stateless allow/deny firewall on a subnet. |
| IAM | Who can do what; users, groups, roles, policies. |
| Role | Temporary identity machines assume (no stored keys). |
| EC2 | A rented virtual machine. |
| AMI | The image/template an EC2 boots from. |
| ASG | Keeps N healthy instances running; self-heals + scales. |
| Lambda | Run code with no server; pay per call. |
| S3 | Object/file storage in buckets. |
| EBS | A virtual disk for one EC2 instance. |
| RDS | Managed SQL database (we use PostgreSQL). |
| DynamoDB | Managed NoSQL key-value store. |
| ALB | HTTP load balancer with health checks. |
| CloudFront | Global CDN cache + HTTPS front door. |
| CloudWatch | Logs, metrics, alarms, dashboards. |

---

## ✅ Checkpoint

You're ready for the next doc when you can answer, in your own words:

1. What's the difference between a Region and an Availability Zone?
2. What makes a subnet "public" vs "private"?
3. How many usable IPs are in a `/24`? Why is a NAT Gateway something we avoid?
4. Security Group vs NACL — give one difference for each of: what it attaches to,
   stateful vs stateless, allow vs deny.
5. Why does a machine use an IAM **role** instead of stored access keys?
6. When would you choose Lambda over EC2?

Next: **[03 — AWS Account & Cost Safety](03-aws-account-and-cost-safety.md)** —
we create the account and put the money guardrails up *before* spending a cent.
