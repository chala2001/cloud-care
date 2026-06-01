# 20 — Teardown & the Interview Story

> **Goal of this doc:** two things. (1) **Tear the project down cleanly and
> safely** — the right order, what to leave running, and how to bring it all
> back. (2) **Tell the story well** — a tested "tell me about a project" script,
> the six Well-Architected pillars revisited against *your* stack, common
> follow-up questions, and resume bullet templates. This is the final doc of the
> whole journey. 🎉

⏱️ Reading time: ~30 minutes. Apply time: ~20 minutes for full teardown.

---

## 1. Why teardown matters

You built **nine Terraform stacks** spanning EC2, RDS, ALB, NAT, ECR, Lambda,
DynamoDB, SES, CloudFront, and a dashboard's worth of alarms. Even within the
free tier, leaving them running drains hours. Knowing how to *destroy and
recreate* on demand is itself the SRE skill we've been practicing all along —
**cattle, not pets**.

> 🧠 **Interview phrasing:** "I treat my AWS account as disposable and the
> Terraform code as the source of truth. Spinning up the whole stack is one
> command per layer; tearing it down is the same. That discipline is what made
> staying near $0 across the whole project possible."

---

## 2. The dependency graph (so the destroy order makes sense)

```
                bootstrap   (S3 state bucket + lock table — the foundation)
                    │
                    ▼
              ┌── network ──┐
              │             │
              ▼             ▼
           compute       database
              │
              ▼
             cdn (CloudFront → reads compute's ALB)
                                                 ▲
                                                 │
   observability (reads compute, database, both serverless stacks)

   serverless-audit    (independent)
   serverless-contact  (independent)
   cicd                (independent — just IAM/OIDC)
```

**Rule of thumb:** destroy *consumers* before *producers*. A stack that *reads*
another's remote state is a consumer; destroying the producer first leaves
dangling references that fail to plan.

---

## 3. Safe teardown order

Run these in **this order**. Every step is `terraform destroy` inside that
folder. Each is independent — you can stop at any point and only the layers
above are gone.

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

# 1) Observability — reads almost everything. Kill it first.
cd terraform/observability && terraform destroy && cd -

# 2) CDN — reads compute (ALB).
cd terraform/cdn && terraform destroy && cd -

# 3) Compute — the costly tier (ALB + NAT + EC2).
cd terraform/compute && terraform destroy && cd -
# ↑ If you uploaded images to ECR via Doc 19, force_delete=true cleans them up.

# 4) Database — RDS itself takes ~5 min to delete.
cd terraform/database && terraform destroy && cd -
# ↑ skip_final_snapshot=true means destroy is clean (no leftover snapshot).

# 5) Serverless slices — independent, safe anytime.
cd terraform/serverless-contact && terraform destroy && cd -
cd terraform/serverless-audit   && terraform destroy && cd -

# 6) CI/CD — IAM role + OIDC provider.
cd terraform/cicd && terraform destroy && cd -

# 7) Network — almost free, but if you want a totally clean slate, kill it now.
cd terraform/network && terraform destroy && cd -

# 8) Bootstrap — LAST. This is the S3 state bucket itself. See §4.
```

You should now see your AWS console with no CloudCare resources except,
possibly, the state bucket. **Compute, Database, and CDN being gone means the
two things that cost real money (ALB, NAT, RDS) are gone — that's the only
discipline that really matters for the budget.**

---

## 4. The bootstrap exception

Doc 06 marked the state bucket with `prevent_destroy = true`. To actually
remove it you must:

1. Edit `terraform/bootstrap/main.tf`, remove (or set `false`) the
   `lifecycle { prevent_destroy = true }` block on `aws_s3_bucket.tfstate`.
2. `terraform apply` to record the lifecycle change.
3. **Empty the bucket manually** (Terraform won't delete a non-empty bucket;
   `force_destroy` is also disabled by default on a state bucket on purpose):
   ```bash
   aws s3 rm s3://cloudcare-tfstate-670794226080 --recursive
   ```
4. `terraform destroy` in `terraform/bootstrap/` — the bucket + DynamoDB lock
   table are removed.

> ⚠️ **Don't do this casually.** Destroying bootstrap means losing the state for
> any stack you *haven't* already destroyed. Do steps 1–3 only when truly done.

For the **normal** "I'm done for the day" flow, **never** touch bootstrap.
Leave it. It costs cents.

---

## 5. Bringing it all back (the up command)

Reapply in dependency order — basically the destroy order reversed, skipping
bootstrap (it's still there):

```bash
for stack in network database compute cdn serverless-audit serverless-contact observability cicd; do
  echo "==== $stack ===="
  ( cd "terraform/$stack" && terraform init -input=false && terraform apply -auto-approve )
done
```

Two things to redo after a fresh apply:
- **Re-push the backend image** to ECR (Doc 13 §4) — the registry is empty.
- **Re-upload the React build** to S3 (Doc 15 §10) — the bucket is empty.

Once the CI/CD pipeline (Doc 19) is in place, both happen automatically on the
next push to `main`.

---

## 6. The interview story (memorize the scaffold, fill it in)

This is the script for "Tell me about a recent project." Adjust phrasing to
sound like you — but keep the structure.

### 6a. The 30-second pitch

> "I built **CloudCare**, an AWS-hosted Hospital Management System, end-to-end
> in **Terraform** and following the **Well-Architected Framework**. It's a
> three-tier web app — React on CloudFront + S3, a FastAPI service on an
> auto-scaling EC2 group behind an ALB, and a PostgreSQL RDS instance in private
> subnets — plus two serverless slices (an audit log on Lambda + DynamoDB with
> X-Ray, and a contact form on Lambda + SES). It runs in `ap-south-1`, stays
> inside the free tier, and ships through GitHub Actions using OIDC federation —
> so there are no AWS keys in the repo."

### 6b. Architecture walkthrough (~2 minutes)

Have this diagram in your head and narrate it left-to-right:

```
Users ─► CloudFront ─┬─► S3 (React static, OAC, private)
                      └─► ALB ─► Auto Scaling Group of EC2 (FastAPI)
                                    │
                                    ▼
                                  RDS PostgreSQL (private subnets)
                                    ▲
                                    │ password
                                  Secrets Manager
                                    ▲
                                    │ IAM role (least-priv)
                                  EC2 instance

   API Gateway HTTP ─► Lambda ─► DynamoDB   (audit log, X-Ray)
   API Gateway HTTP ─► Lambda ─► SES        (contact form)

   Cross-cutting: VPC with public/private subnets across 2 AZs, IGW + NAT
                  instance (private egress), security-group chain
                  ALB→App→DB, NACL backstops, CloudWatch dashboard + SNS
                  alarms, Cost Explorer + Budgets, GitHub Actions via OIDC.
```

Beat-by-beat narration:

1. *Network.* "VPC with public/private subnets across two AZs. Security groups
   form a chain: only the ALB SG reaches the App SG, only the App SG reaches
   the DB SG. NACLs are coarse stateless backstops."
2. *Compute.* "The app tier is an ASG of `t3.micro` instances in private
   subnets, behind an ALB in the public subnets. Instances run a Docker image
   from ECR; egress is via a NAT instance, not a NAT Gateway — a deliberate
   cost choice."
3. *Database.* "Single-AZ RDS PostgreSQL, private, encrypted, with the master
   password generated and stored in Secrets Manager. The instance reads it via
   its IAM role — no credentials on disk."
4. *Frontend.* "React SPA built with Vite, hosted in a private S3 bucket fronted
   by CloudFront with OAC. CloudFront routes `/api/*` to the ALB so the whole
   app is one origin — no CORS in production."
5. *Serverless.* "Two slices on API Gateway HTTP APIs: audit events to
   DynamoDB with X-Ray tracing, and a contact form that emails through SES."
6. *Operability.* "One CloudWatch dashboard, SNS-fanned alarms on ALB 5xx, RDS
   CPU/connections/storage, and Lambda errors. Cost Explorer + Budgets +
   Compute Optimizer for the money."
7. *CI/CD.* "GitHub Actions with OIDC federation — short-lived creds, scoped to
   this repo and refs. PRs run `terraform plan`; main applies, builds the
   backend image, and deploys the frontend with a CloudFront invalidation."

### 6c. The Six Pillars, framed against your stack

When asked "how does this design hold up under Well-Architected?" go in order:

| Pillar | Your concrete answer |
|--------|----------------------|
| **Operational Excellence** | "Every resource is Terraform, every change goes through CI, dashboards + alarms make the system observable." |
| **Security** | "Defense in depth: private subnets, SG chain, NACLs, IAM roles instead of keys, Secrets Manager, least-priv IAM with conditions (e.g., `ses:FromAddress`), CloudFront-only S3 with `aws:SourceArn`." |
| **Reliability** | "Multi-AZ subnets, ASG self-healing, ALB health checks, RDS automated backups (Multi-AZ is written but off for cost)." |
| **Performance Efficiency** | "CloudFront caching at the edge, right-sized `t3.micro` instances, Lambda for spiky workloads, on-demand DynamoDB." |
| **Cost Optimization** | "Free-tier sizing, NAT instance instead of Gateway, destroy-after-labs habit, Budgets + Cost Explorer + Compute Optimizer." |
| **Sustainability** | "Serverless and auto-scaling reduce idle waste; the destroy-on-idle workflow extends that to ephemeral environments." |

---

## 7. Likely follow-up questions (rehearse short answers)

**Q: "What would change for production?"**
- Multi-AZ RDS on; ALB cert via ACM + custom domain; NAT Gateway instead of
  instance; per-workflow IAM roles in CI; egress restricted on security groups;
  WAF in front of CloudFront; SES sandbox lifted; CloudWatch Logs retention
  raised and shipped to S3 for archive; Alembic for DB migrations.

**Q: "Walk me through a request to view appointments."**
- Browser → DNS resolves CloudFront → CloudFront edge → CloudFront sees `/api/*`
  → routes to ALB origin over HTTP → ALB target group picks a healthy EC2 →
  FastAPI on EC2 → SQLAlchemy connection pool → PostgreSQL RDS over `:5432` (SG
  allows from App SG only) → row returned → JSON back → CloudFront forwards
  uncached → browser. X-Ray would show all the spans if I instrumented the EC2
  side too.

**Q: "How do you keep secrets out of code?"**
- DB password is generated by `random_password`, stored in Secrets Manager,
  fetched at instance boot by the EC2 IAM role with a policy scoped to that one
  secret ARN. No password in the repo, in env files, or in Terraform outputs.

**Q: "Why no NAT Gateway?"**
- "Cost. A managed NAT Gateway is ~$32/month plus data. For a learning project
  on free tier I used a NAT instance — a `t3.micro` doing iptables MASQUERADE
  with `source_dest_check` off. For production I'd switch to the Gateway (or,
  best, use VPC interface endpoints to remove the need for outbound internet
  entirely)."

**Q: "Security Group vs NACL?"**
- "SG is stateful, attaches to a resource, allow-only. NACL is stateless,
  attaches to a subnet, allow+deny, must permit return ephemeral ports
  explicitly. I used SGs for the precise three-tier chain and NACLs as coarse
  subnet backstops — AWS's recommended pattern."

**Q: "How does CI authenticate to AWS?"**
- "GitHub OIDC federation. GitHub mints a signed JWT per job; AWS STS validates
  it against the GitHub OIDC provider; my IAM role's trust policy restricts the
  `sub` claim to `repo:owner/repo:ref:refs/heads/main` and `pull_request`.
  Result: no long-lived AWS keys in GitHub, 1-hour credentials per job."

**Q: "How did you handle migrations?"**
- "For this learning slice I used SQLAlchemy `create_all` at app startup —
  fine for greenfield, not production. The real pattern is Alembic, with the
  migration step running before or alongside the ASG rollout, and the app
  refusing to start against an unmigrated DB. That'd be the very next thing I'd
  add."

---

## 8. Resume bullet templates

Pick the 3–4 most relevant for the role; trim numbers to taste.

- **Designed and built a Well-Architected, three-tier AWS application
  (CloudCare HMS)** entirely in Terraform across 9 isolated stacks, staying
  inside the free tier through destroy-after-lab discipline.
- **Implemented network defense-in-depth** with a custom VPC, public/private
  subnets across 2 AZs, an IGW + NAT instance (cost-conscious vs. NAT Gateway),
  and a stateful ALB→App→DB security-group chain backed by stateless NACLs.
- **Containerized a FastAPI backend** and deployed it via an Auto Scaling Group
  behind an Application Load Balancer; instances pulled images from ECR and
  fetched DB credentials from **Secrets Manager** via a least-privilege IAM
  role (no static credentials in code or env).
- **Served a React SPA globally via S3 + CloudFront** with Origin Access
  Control, single-origin `/api/*` routing to the ALB to eliminate CORS, and SPA
  fallback for client-side routing.
- **Built two serverless slices** (API Gateway → Lambda → DynamoDB with X-Ray
  tracing, and Lambda → SES for a contact form) following least-privilege IAM
  with attribute-level conditions.
- **Established operability** with CloudWatch dashboards, SNS-fanned alarms on
  ALB 5xx / RDS health / Lambda errors, and the AWS cost trio (Budgets, Cost
  Explorer, Compute Optimizer).
- **Built a keyless CI/CD pipeline** in GitHub Actions using **OIDC federation
  to AWS** (no stored access keys), with `terraform plan` on PRs, `apply` on
  main, automated image build/push to ECR with ASG rollout, and frontend
  deploy/invalidate to S3 + CloudFront.

---

## 9. What you actually know now

You've touched, in production-grade Terraform, at least:

> **VPC, Subnet, IGW, Route Table, NACL, Security Group, ALB, Target Group,
> Listener, Auto Scaling Group, Launch Template, EC2, IAM role/policy/instance
> profile, IAM OIDC provider, S3 bucket + policy + OAC, CloudFront, ECR, RDS,
> DB Subnet Group, Secrets Manager, random_password, DynamoDB, Lambda, API
> Gateway HTTP API, SES email identity, SNS topic + subscription, CloudWatch
> alarm + dashboard + log group, X-Ray, archive_file, terraform_remote_state,
> NAT-instance routing.**

That is a real, working AWS Solutions Architect / SRE / DevOps surface area.

---

## ✅ Final checkpoint — end of the project 🎉🎉🎉

You're done when:

- [ ] You've torn the stack down at least once and brought it back from
      Terraform alone.
- [ ] You can narrate §6b (the architecture walkthrough) without notes, drawing
      the diagram by hand.
- [ ] You can answer §7's questions in 30–60 seconds each.
- [ ] You've put one CloudCare bullet on your CV / LinkedIn.

> 🧠 The point of building this wasn't the app. It was being able to *talk*
> about every box and arrow in the diagram, defend every design choice, and
> reproduce the whole thing on demand. You can.

Go ace the WSO2 interviews. 🚀
