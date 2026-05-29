# 00 — The Roadmap

> **Goal of this doc:** give you the whole map before we start the journey, so
> you always know *where you are*, *why this step exists*, and *what's next*.

If you only read one paragraph: we are going to build a real cloud system the way
a professional SRE/DevOps team would — networking first, then compute, then data,
then the app, then delivery, then serverless, then observability — describing
**every resource in Terraform** and keeping costs near **zero** by destroying
labs when we're done. By the end you'll be able to explain and rebuild a
Well-Architected AWS system from scratch. That is exactly what a WSO2 SRE/DevOps
interview wants to see.

---

## 1. How this course is structured

The work is split into **phases**. Each phase is one or more numbered docs in
`docs/`. A phase always follows the same rhythm:

1. **Concept** — what the AWS service is, in plain language, and why it exists.
2. **Design** — what we're going to build and the cost implications.
3. **Code** — the Terraform (and app code), explained line by line.
4. **Apply & verify** — run it, look at it in the AWS Console, confirm it works.
5. **Destroy** — tear it down to protect your credit (we re-create on demand).

> 🧠 **Why "destroy after each lab"?** In the real world you'd leave
> infrastructure running. But you're a single learner on a ~$100 budget, and the
> *skill* you're building is being able to recreate anything with one command
> (`terraform apply`). So we treat your AWS account as disposable and your
> Terraform code as the source of truth. This is itself a core SRE mindset:
> **cattle, not pets.**

---

## 2. The phases at a glance

| Phase | Docs | Theme | Key AWS services | Free-tier risk |
|------:|------|-------|------------------|----------------|
| **0** | 00–06 | Foundations & tooling | (none deployed yet) S3 + DynamoDB for state | ✅ Practically free |
| **1** | 07–08 | Networking | VPC, Subnets, IGW, Route Tables, NACL, Security Groups | ✅ Free (NAT Gateway avoided) |
| **2** | 09–10 | Compute | EC2, Launch Template, Auto Scaling Group, ALB | ⚠️ ALB hours + 2nd EC2 — watch it |
| **3** | 11 | Database | RDS PostgreSQL, Subnet Group, Secrets | ⚠️ Single-AZ only to stay free |
| **4** | 12–14 | The application | FastAPI backend, React frontend, Docker | ✅ Local + on existing EC2 |
| **5** | 15 | Content delivery | S3 (static hosting), CloudFront (CDN) | ✅ Generous free tier |
| **6** | 16–17 | Serverless | API Gateway, Lambda, DynamoDB, X-Ray, SES | ✅ Generous free tier |
| **7** | 18 | Observability & cost | CloudWatch (logs/metrics/alarms), Cost Explorer/Budgets | ✅ Free within limits |
| **8** | 19–20 | Productionizing | GitHub Actions CI/CD, teardown, interview story | ✅ Free |

**Phases 0–3 are written** (docs 00–11): Phase 1 — Networking
([07](07-networking-vpc-and-subnets.md), [08](08-networking-security-groups-and-nacls.md)),
Phase 2 — Compute
([09](09-compute-launch-template-and-asg.md), [10](10-compute-application-load-balancer.md)),
and Phase 3 — Database ([11](11-database-rds-postgresql.md)) are ready to build.

> The doc numbers above are the *plan*. I write each phase's docs when you reach
> it, so we can adjust based on what you learned in the previous one. You won't
> see docs 12+ in the repo until we get there — that's intentional.

---

## 3. The 4-month schedule (suggested)

You said interviews are ~4 months out. Here's a realistic part-time pace
(~6–8 hours/week). Adjust freely — the docs don't expire.

### Month 1 — Foundations & Networking
- **Week 1:** Docs 00–02. Understand the architecture and the vocabulary. No deploys.
- **Week 2:** Doc 03–04. Create AWS account, lock it down, set budgets, install tools.
- **Week 3:** Doc 05–06. Learn Terraform, deploy your first thing (state backend).
- **Week 4:** Docs 07–08 (Phase 1). Build the VPC and all networking. This is the
  single most important chunk for interviews — take your time.

### Month 2 — Compute & Database
- **Week 5–6:** Phase 2. EC2 + Auto Scaling + Load Balancer. Learn how traffic flows.
- **Week 7:** Phase 3. RDS database. Learn subnet groups and secrets.
- **Week 8:** Phase 4 (part 1). Get the FastAPI backend running locally and on EC2.

### Month 3 — Application & Delivery & Serverless
- **Week 9:** Phase 4 (part 2). React frontend, wire it to the backend.
- **Week 10:** Phase 5. S3 + CloudFront to serve the frontend globally.
- **Week 11–12:** Phase 6. Serverless features (Lambda/DynamoDB/SES) + X-Ray.

### Month 4 — Polish, Observability, Interview Prep
- **Week 13:** Phase 7. CloudWatch dashboards, alarms, log aggregation.
- **Week 14:** Phase 8. CI/CD with GitHub Actions.
- **Week 15:** Write your architecture diagram + README; rehearse the "tell me
  about a project" story (we'll script it together).
- **Week 16:** Buffer / redo any phase you felt shaky on. Practice
  `terraform destroy` + `apply` of the whole stack until it's boring.

> 🧠 **Interview insight:** Interviewers rarely care that your app is fancy. They
> care that you understand *networking, security boundaries, failure modes, cost,
> and automation*. That's why we spend the most time on Phases 1–3 and 7.

---

## 4. What "done" looks like

By the end you will be able to:

- Draw the architecture from memory and explain every box and arrow.
- Explain the difference between a public and private subnet, and *why* the
  database must never be in a public one.
- Explain how a request travels: browser → CloudFront → ALB → EC2 → RDS.
- Stand up the entire stack with `terraform apply` and tear it down with
  `terraform destroy`.
- Explain how you kept it inside the free tier and what each service would cost
  at production scale.
- Talk fluently about IAM, least privilege, security groups vs NACLs, Auto
  Scaling, and observability.

---

## 5. A note on cost (read this every time you deploy)

💰 **Three habits will keep you safe:**
1. After any lab, run `terraform destroy` unless a doc explicitly says to leave
   something up.
2. Check the **Billing → Free Tier** page in the AWS Console once a week.
3. Trust the **budget alarm** we set in Doc 03 — if it emails you, stop and
   investigate immediately.

The only things we intentionally leave running long-term are nearly free:
the S3 state bucket and DynamoDB lock table (fractions of a cent), and later the
S3/CloudFront frontend (well within free tier).

---

## ✅ Checkpoint

You don't *do* anything in this doc — it's the map. You're ready to move on when
you can answer:

- What are the 8 phases, roughly in order?
- Why do we destroy infrastructure after labs?
- What region are we using and why?
- Where do the budget alarms come from (which doc)?

Next: **[01 — Architecture Overview](01-architecture-overview.md)** — we read the
diagrams in detail and define exactly what we're building.
