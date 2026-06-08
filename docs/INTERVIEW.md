# CloudCare — Interview Cheat-Sheet

> One file. Read it the night before. Read the bold lines again 30 minutes before.
> Everything here is **concepts + trade-offs + war stories** — no code.

---

## 🎤 The 30-second pitch

> *"CloudCare is a hospital management system I built on AWS to learn Well-Architected
> design end-to-end. It's a three-tier app — React on S3/CloudFront, FastAPI on EC2
> behind an ALB, and PostgreSQL on RDS — plus two serverless slices for an audit log
> (Lambda + DynamoDB) and a contact form (Lambda + SES). Everything is in
> Terraform across 8 stacks with isolated state, fronted by CloudWatch
> observability, deployed via GitHub Actions using OIDC federation — no stored AWS
> keys. The whole thing runs free-tier and tears down with one `terraform destroy`
> per stack."*

---

## 🎤 The 2-minute architecture walk

```
   Users (browsers, worldwide)
        │ HTTPS
        ▼
   CloudFront (CDN, free *.cloudfront.net TLS, OAC to private S3)
        │  default →  S3 (React build, private)
        │  /api/*  →  ALB
        ▼
   ALB (2 public subnets, 2 AZs) ── alb-sg → app-sg :8000
        │
        ▼
   ASG of EC2 (2 private app subnets, 2 AZs)
        │  Docker container, image from ECR, secret from Secrets Manager
        │  app-sg → db-sg :5432
        ▼
   RDS PostgreSQL (2 private db subnets, encrypted, single-AZ for free tier)

   In parallel — serverless slices (no VPC):
     POST /events  → API Gateway → Lambda → DynamoDB (audit, X-Ray traced)
     POST /contact → API Gateway → Lambda → SES        (contact form)

   Cross-cutting:
     • One VPC, 6 subnets (public/app/db × 2 AZs), one NAT instance for egress
     • CloudWatch dashboard + alarms → SNS topic → email
     • GitHub Actions OIDC → IAM role → Terraform plan-on-PR, apply-on-main
```

Memorize this diagram. It's the single best answer to *"walk me through what
you built."*

---

## 🗝️ Vocabulary you MUST get right

### AWS resource identifiers — which to use when

| What | Looks like | Use it for |
|---|---|---|
| **ARN** (Amazon Resource Name) | `arn:aws:elasticloadbalancing:ap-south-1:670794226080:loadbalancer/app/cloudcare-alb/abc...` | IAM policies (`resources = [arn]`), cross-account references, anything "permission" |
| **ID** | `vpc-08fcc309...`, `i-015c05a...`, `sg-0abc...` | What AWS console shows, what most CLI flags take (`--vpc-id`, `--instance-ids`) |
| **Name** (the tag) | `cloudcare-vpc` | Human-readable label; nothing functional |
| **DNS name** | `cloudcare-alb-199499790.ap-south-1.elb.amazonaws.com` | The URL clients connect to; CloudFront origins |
| **ARN suffix** (e.g. `alb_arn_suffix`) | `app/cloudcare-alb/82e463d1b2482a0e` | **The string after `loadbalancer/`** in the ARN — **CloudWatch metric dimensions need this**, NOT the full ARN |
| **Identifier** (RDS) | `cloudcare-postgres` | RDS-specific human name; CloudWatch `DBInstanceIdentifier` dimension uses this |
| **Zone ID** | `ZP97RAFLXTNZK` | Route 53 alias records use this to point a domain at an ALB |
| **Endpoint** (RDS) | `cloudcare-postgres.xxx.rds.amazonaws.com:5432` | `host:port` you give to the DB client |

**Interview gotcha**: CloudWatch's `LoadBalancer` dimension wants the **ARN suffix**, not the ARN. If you only published the ARN as a Terraform output, your alarms would silently see no data. That's why `compute/outputs.tf` exports `alb_arn_suffix` specifically.

### Networking terms

| Term | One-line meaning |
|---|---|
| **VPC** | Your private network in AWS |
| **CIDR** (`10.0.0.0/16`) | An IP range. Smaller number = bigger range. `/16` ≈ 65k IPs, `/24` ≈ 256 IPs |
| **AZ** (Availability Zone) | A physically separate data center inside one AWS region |
| **Subnet** | A slice of the VPC bound to **exactly one AZ** |
| **Public subnet** | Subnet whose **route table** sends `0.0.0.0/0` to the Internet Gateway |
| **Private subnet** | Subnet with no `0.0.0.0/0` route — no internet, in or out |
| **Internet Gateway (IGW)** | The VPC's door to the public internet (one per VPC) |
| **NAT Gateway** | AWS-managed NAT, ~$32/mo. Lets private subnets reach internet OUTbound |
| **NAT instance** | DIY: a `t3.micro` doing `iptables MASQUERADE`. Free-tier. Single-AZ. |
| **Route table** | **Navigation** rules: "to reach X, go via Y." Doesn't allow/deny |
| **Security Group (SG)** | **Stateful** firewall on a resource. Allow-only. Reply traffic auto-allowed |
| **NACL** (Network ACL) | **Stateless** firewall on a subnet. Allow + deny. Rules in numbered order. Must allow return traffic on ephemeral ports |
| **Ephemeral port** | A temporary high port (1024–65535) clients use as source. Replies come back here |

### Compute / app terms

| Term | One-line meaning |
|---|---|
| **EC2** | A virtual server |
| **AMI** | The OS install image an EC2 boots from |
| **Launch Template** | The **recipe** for a server (OS, size, SG, user-data). Doesn't create instances |
| **Auto Scaling Group (ASG)** | The **manager** that keeps N instances alive from a template. Self-healing |
| **`desired_capacity` / `min` / `max`** | ASG always aims for `desired`, never less than `min`, never more than `max` |
| **Instance refresh** | ASG action that rolling-replaces instances — how new images deploy |
| **Health check `EC2` vs `ELB`** | EC2 = "is the VM alive". ELB = "does the app respond on `/health`". Use ELB once an ALB exists |
| **IAM role + instance profile** | A "badge" the server wears so it can call AWS without stored keys. EC2 needs the **instance profile** wrapper specifically |
| **IMDSv2** | Hardened metadata service requiring a session token. Blocks SSRF → cred theft |
| **SSM Session Manager** | Browser/CLI shell into an EC2 with **no SSH key + no open port 22**. Uses IAM |
| **user-data** | Boot script that runs once as root on first start |
| **cloud-init** | The Linux subsystem that runs user-data |

### Load balancer / CDN terms

| Term | One-line meaning |
|---|---|
| **ELB** | The **family** of AWS load balancers (umbrella term) |
| **ALB** | Application LB — Layer 7, HTTP-aware. What we use |
| **NLB** | Network LB — Layer 4, TCP/UDP. Higher perf, fewer features |
| **CLB** | Classic LB — legacy, avoid |
| **Target group** | The pool of backends + their health-check definition |
| **Listener** | "Accept traffic on port X, forward to target group Y" |
| **`source_dest_check = false`** | **Required** for a NAT instance — lets it forward packets not addressed to itself |
| **CloudFront distribution** | One global CDN config with origins + behaviors |
| **Origin** | A backend CloudFront fetches from on cache miss (S3, ALB, any HTTPS URL) |
| **Behavior** | A rule that maps URL path → origin + cache policy |
| **OAC** (Origin Access Control) | Modern signed-request mechanism letting CloudFront read a **private** S3 bucket |
| **OAI** (Origin Access Identity) | The legacy version of OAC. Existing setups still use it |
| **Invalidation** | "Forget cached copy of these paths." First 1,000/month free |
| **Hash-busting** | Filenames like `app.a3f1b.js` — content change → new name → automatic cache bust |

### Data / serverless terms

| Term | One-line meaning |
|---|---|
| **RDS** | AWS-managed relational database. Handles backups, patching, optional Multi-AZ |
| **DB subnet group** | A named set of subnets RDS may place the instance in (requires ≥2 AZs even single-AZ) |
| **Multi-AZ RDS** | Synchronous standby in another AZ. Auto-failover ~1 min. **Doubles cost** |
| **PITR** (Point-In-Time Recovery) | Continuous backups, restore to any second in last 35 days |
| **Secrets Manager** | AWS service that stores credentials, ~$0.40/secret/month |
| **Lambda** | "Functions-as-a-service" — code runs on demand, no idle cost |
| **Cold start vs warm start** | First invoke loads runtime + code (~100–500ms); next reuse the container (~few ms) |
| **DynamoDB** | Managed NoSQL key/value. Single-digit-ms reads/writes |
| **Partition key (hash key)** | The required primary key for DynamoDB |
| **Sort key (range key)** | Optional second key for range/order queries within a partition |
| **GSI** | Global Secondary Index — a parallel index on different keys |
| **`Scan` vs `Query`** | Scan = read whole table (slow/expensive). Query = read one partition (fast/cheap) |
| **PAY_PER_REQUEST vs PROVISIONED** | On-demand pricing vs reserved capacity |
| **API Gateway HTTP API vs REST API** | HTTP API = newer/cheaper/simpler. REST API = older/feature-richer |
| **SES sandbox** | New accounts only send to/from verified addresses, low cap. Removed by support request |

### Observability / cost terms

| Term | One-line meaning |
|---|---|
| **Metrics** | Numeric samples over time (`AWS/ApplicationELB`, `AWS/RDS`, etc.) |
| **Logs** | Text events (CloudWatch Logs, Logs Insights to query) |
| **Traces** | Per-request timelines across services (X-Ray) |
| **CloudWatch namespace** | The product family (`AWS/Lambda`, `AWS/RDS`) |
| **Dimension** | Which specific resource a metric is for (`FunctionName`, `DBInstanceIdentifier`) |
| **Statistic** | How to aggregate datapoints (`Sum`, `Average`, `Min`, `Max`, `pXX`) |
| **`evaluation_periods`** | Consecutive periods that must breach to fire an alarm |
| **`treat_missing_data`** | What to do with no data (`notBreaching` for counts, `breaching` for health) |
| **SNS topic** | Pub/sub channel — alarms publish, subscriptions receive |
| **Budgets / Cost Explorer / Compute Optimizer** | Alert / analyze / right-size — the three cost tools |
| **Cost-allocation tag** | A tag enabled in Billing so Cost Explorer can filter by it (`Project=cloudcare`) |

### CI/CD terms

| Term | One-line meaning |
|---|---|
| **OIDC federation** | GitHub mints a per-run JWT; AWS verifies it → short-lived (1h) creds. **No stored AWS keys** |
| **JWT** | A signed token with claims (issuer, audience, subject) |
| **`sub` claim** | `repo:owner/name:ref:refs/heads/main` — the security backbone of the trust policy |
| **Trust policy** | The IAM policy that says "who may assume this role" |
| **GitHub variable vs secret** | Variable visible; secret masked. The role ARN is a variable (not sensitive on its own) |
| **`paths:` filter** | Workflow trigger restricted to certain file changes |
| **`$GITHUB_ENV`** | Magic file — write lines to it to pass values to subsequent steps |
| **`npm ci` vs `npm install`** | `ci` = exact lockfile reproduction; preferred in CI |
| **Branch protection** | Force PR + passing checks before merge to main |

---

## 🏗️ What's actually running (the inventory)

| Stack (Terraform folder) | What's in it |
|---|---|
| `bootstrap/` | S3 state bucket + DynamoDB lock table. Local state. Leave running |
| `network/` | 1 VPC, 6 subnets, 1 IGW, 2 route tables, 3 SGs, 2 NACLs. **Free, leave running** |
| `compute/` | 1 Launch Template, 1 ASG, 1 ALB + target group + listener, ECR repo, NAT instance, IAM role. **Costs money, destroy after labs** |
| `database/` | 1 RDS PostgreSQL (single-AZ), 1 DB subnet group, 1 Secrets Manager secret, generated password. **Costs money** |
| `cdn/` | 1 S3 frontend bucket, 1 CloudFront distribution with OAC, 1 bucket policy. **Free**, leave up |
| `serverless-audit/` | 1 DynamoDB table, 1 Lambda, 1 HTTP API, X-Ray on. **Free** |
| `serverless-contact/` | 2 SES identities, 1 Lambda, 1 HTTP API. **Free** |
| `observability/` | 1 SNS topic + email sub, 8 CloudWatch alarms, 1 dashboard. **Free** |
| `cicd/` | 1 IAM OIDC provider, 1 deploy role (AdministratorAccess for lab). **Free** |

**Cost discipline**: only `network`, `bootstrap`, `cdn`, `serverless-*`, `observability`, `cicd` should be **left running** between sessions. `compute` and `database` get **destroyed after each lab**.

---

## 🎯 The 5 questions they WILL ask (with model answers)

### 1. "Walk me through what happens when a user clicks Add Patient."

> *"Browser sends `POST /api/patients` over HTTPS to the CloudFront URL.
> CloudFront's `/api/*` behavior forwards to the ALB origin (no caching). The
> ALB picks a healthy target from the target group — an EC2 in one of the two
> private app subnets. The request goes from the public ALB subnet into the
> private app subnet across the `alb-sg → app-sg :8000` security-group chain
> and the private NACL. The Docker container running on the EC2 (FastAPI)
> validates the body with Pydantic, opens a SQLAlchemy session, and writes a
> row to RDS over `app-sg → db-sg :5432`. RDS sits in the private db subnets,
> not publicly accessible. Response trickles back: app → ALB → CloudFront →
> browser. The DB password came from Secrets Manager, fetched at boot via the
> instance's IAM role — no credentials on disk."*

### 2. "How is this highly available?"

> *"Every tier has a subnet in each of two AZs. The ALB is provisioned with
> both public subnets — AWS drops a node into each, sharing one DNS name. The
> ASG's `vpc_zone_identifier` lists both app subnets, so instances are
> balanced across AZs and the ASG auto-replaces failed ones. The RDS subnet
> group covers both db subnets, so flipping `multi_az = true` instantly adds
> a synchronous standby — currently off to stay in free tier. CloudFront,
> S3, DynamoDB, and Lambda are AWS-managed multi-AZ by default. Lose an AZ
> and the system stays up — every tier has a survivor."*

### 3. "How is the database secured?"

> *"Three locks. **One**: it's in a private subnet with no internet route.
> **Two**: it sits behind a security group that only the app-tier SG can
> reach on port 5432. Even other things inside the VPC can't connect.
> **Three**: `publicly_accessible = false` means no public DNS endpoint
> exists. Add encryption at rest with AES-256, automated daily snapshots,
> and the master password generated by Terraform straight into Secrets
> Manager — never typed, never in git, never output by Terraform."*

### 4. "You're paged because the site returns 502s. How do you debug?"

> *"Trace the request path. First, `aws elbv2 describe-target-health` — are
> any targets healthy? If all unhealthy, the app isn't responding on the
> port the health check hits. SSM into an instance, `docker ps -a`, `docker
> logs` — usually the app crashed on boot (DB connection, missing secret,
> typo). If targets are healthy and you still 502 at CloudFront only,
> CloudFront probably points at a stale ALB DNS — `terraform_remote_state`
> baked in the value at plan time, and compute was recreated since.
> Re-apply the cdn stack so it re-reads the current ALB DNS. The pattern is
> always: peel from the edge inward — ALB target-group health → instance
> health → app logs."*

### 5. "What would you do differently in production?"

The hardening checklist (recite 6–8 of these):

| Layer | Production change |
|---|---|
| **Networking** | NAT Gateway across 2 AZs instead of single NAT instance |
| **Compute** | ASG `desired = 2+`, instance refresh strategy with stricter `MinHealthyPercentage` |
| **Database** | `multi_az = true`, `deletion_protection = true`, `skip_final_snapshot = false`, 7–30 day backups |
| **ALB** | HTTPS listener with ACM cert; redirect HTTP→HTTPS; WAF in front |
| **SES** | Production access (no sandbox); SPF/DKIM/DMARC on a real domain |
| **CloudFront** | Custom domain + ACM cert (us-east-1); WAF |
| **IAM** | One IAM role per CI workflow with least-privilege policies (not AdministratorAccess) |
| **Secrets** | Enable Secrets Manager rotation; pass them to the container via SDK call, not env vars |
| **DynamoDB** | Access-pattern-driven schema with `pk + sk` and GSIs, not `Scan` |
| **App** | Alembic migrations (not `create_all`); structured JSON logging; APM/X-Ray on FastAPI |
| **Observability** | More alarms (latency p99, DB queue depth); composite alarms for noise reduction; runbook links in alarm descriptions |
| **Cost** | Tagged cost-allocation; Compute Optimizer review monthly; Savings Plans for steady workloads |

---

## ⚖️ Trade-offs you can speak to fluently

| You picked | Over | Because |
|---|---|---|
| **3-tier + serverless** | All one or all the other | Right tool per workload. Patients = steady, stateful → EC2+RDS. Audit/contact = spiky, simple → Lambda |
| **NAT instance** | NAT Gateway | $0 (free-tier hours) vs $32/mo. Production = Gateway. Best = VPC interface endpoints |
| **`PAY_PER_REQUEST`** (DynamoDB) | Provisioned | Spiky low workload. Provisioned cheaper at high steady throughput |
| **HTTP API** (API Gateway) | REST API | 70% cheaper, simpler, built-in CORS, payload format 2.0 |
| **CloudFront + private S3 (OAC)** | Public S3 website hosting | Private bucket, free HTTPS, edge caching, DDoS shield. Strictly better |
| **Single-AZ RDS** | Multi-AZ | Free tier. One flag change to flip — design is HA-ready |
| **One IAM role for CI** | One per workflow | Lab convenience. Production splits least-privilege per workflow |
| **OIDC federation** | Stored AWS keys | No keys in repo, 1h credentials, per-run JWT scoped by `sub` |
| **SES with verified identities** | SMTP relay / 3rd party | Native AWS, in same account, IAM-controlled. Sandbox → production via form |
| **Vite SPA** | Server-side rendering | Static files → S3+CDN means infinite scale, ~$0, no idle server |
| **State-isolated Terraform folders** | One monorepo state | Smaller blast radius. A mistake in `compute` can't corrupt `network` |

---

## 🐛 Real war stories (these EARN POINTS — interviewers love hearing them)

### War story 1 — "CloudFront returned 502 from `/api/*` after compute was rebuilt"

**Symptom**: Frontend loaded fine; `/api/*` returned 502.
**Root cause**: `cdn/cloudfront.tf` reads `alb_dns_name` from compute's remote state at **plan time** and bakes the value in. When `compute/` was destroyed and recreated, the ALB got a new DNS name, but CloudFront still pointed at the destroyed one.
**Fix**: re-apply the `cdn/` stack so it reads the current ALB DNS.
**Lesson**: cross-stack `terraform_remote_state` values are pinned at plan time. Recreating an upstream stack requires re-applying the downstream.

### War story 2 — "ALB target stuck unhealthy → ECR was empty"

**Symptom**: Target unhealthy with `Health checks failed`. EC2 was running but nothing on `:8000`.
**Root cause**: User-data did `docker pull cloudcare-backend:latest` but I hadn't pushed any image yet. The container never started.
**Fix**: `docker build → tag → push` to ECR, then `aws autoscaling start-instance-refresh` to re-run user-data on a fresh instance.
**Lesson**: order of operations — image must exist in ECR before instances boot. CI/CD (Phase 8) makes this automatic.

### War story 3 — "ALB returned 200 but `/health` was 404"

**Symptom**: `/api/patients` worked, but ALB marked target unhealthy because the `/health` check returned 404.
**Root cause**: The FastAPI `/health` route was **commented out** in `main.py` — the comment line above it said "/health stays a top-level route" but the actual `@app.get("/health")` was still commented.
**Fix**: uncomment the route, rebuild image, push, instance refresh.
**Lesson**: ALB target marked unhealthy on a 4xx ≠ "the app is dead." Always check what the health-check path actually returns.

### War story 4 — "Stateless NACL silently dropped reply traffic"

**Symptom**: After adding the NAT instance, instances' `dnf install` and `docker pull` hung at `SYN_RECV` — never completed.
**Root cause**: The private NACL only allowed inbound from `10.0.0.0/16`. Once egress through NAT existed, replies came from random public IPs on ephemeral ports — the NACL dropped them silently.
**Fix**: add an ingress rule on the private NACL allowing TCP `1024–65535` from `0.0.0.0/0`.
**Lesson**: stateless NACL = every conversation needs both directions explicitly. Adding egress later forces you to revisit return-traffic rules.

### War story 5 — "SES IAM denied `ses:SendEmail` on the recipient identity"

**Symptom**: `AccessDeniedException ... ses:SendEmail on resource <recipient ARN>`.
**Root cause**: When both sender and recipient are verified identities in the same account (typical in SES sandbox), SES checks `ses:SendEmail` against **both** identity ARNs. Our policy only granted the sender's.
**Fix**: list both ARNs in the policy's `resources`, keep the `ses:FromAddress` condition so the role can still only send **as** the sender.
**Lesson**: in sandbox, sender + recipient are both your identities → both need IAM scope. In production with sandbox lifted, recipients aren't your identities, so the original policy works.

### War story 6 — "Lambda 500 with `Runtime.ImportModuleError`"

**Symptom**: `Unable to import module 'lambda_function': No module named 'lambda_function'`.
**Root cause**: Filename typo — `lambda_funtion.py` (missing the `c`). Handler config said `lambda_function.lambda_handler`, Python couldn't find the file.
**Fix**: rename to `lambda_function.py`, `terraform apply` (the `source_code_hash` change triggers redeploy).
**Lesson**: the handler string `<module>.<function>` literally maps to `<module>.py` + `<function>` symbol. A typo in either side breaks import at runtime, not deploy time.

---

## 🎓 Concepts they'll quiz you on (rapid-fire prep)

| Q | One-line answer |
|---|---|
| What makes a subnet public? | A `0.0.0.0/0` route to an Internet Gateway in its route table |
| Why two AZs from day one? | A subnet lives in exactly one AZ; ALB/ASG/RDS all want pairs for fault tolerance |
| SG vs NACL? | SG = stateful, per-resource, allow-only. NACL = stateless, per-subnet, allow+deny, ordered |
| Why ephemeral 1024–65535 in NACL? | Replies come back on the client's random source port — stateless NACL needs explicit allow |
| `0.0.0.0/0` vs `from_port=0/to_port=0/protocol=-1`? | First = any IP. Second = all ports + protocols. Two different "0"s |
| Why an ALB needs ≥ 2 subnets? | High availability — AWS puts a node in each AZ subnet under one DNS name |
| ALB vs NLB? | ALB = Layer 7 HTTP-aware. NLB = Layer 4 TCP/UDP for raw perf |
| 502 vs 503 vs 504 from ALB? | 502 = backend gave malformed reply. 503 = no healthy targets. 504 = backend timed out |
| Why `health_check_type = ELB` (not EC2)? | EC2 only knows the VM is on. ELB knows the app responds → catches "VM up, app crashed" |
| What does an IAM role give an EC2? | Short-lived, auto-rotated AWS creds via the metadata service. No stored keys |
| Why IMDSv2? | Requires a session token PUT first. Blocks SSRF-based credential theft |
| RDS three locks? | Private subnet + db-sg (app-only) + `publicly_accessible = false` |
| Multi-AZ RDS trade-off? | Sync standby in other AZ → ~1-min auto-failover. Doubles cost |
| Why Secrets Manager not env vars? | Rotation, audit logs, IAM-scoped, never in git |
| CloudFront OAC vs OAI? | OAC = modern (SigV4, KMS-friendly). OAI = legacy. New work uses OAC |
| Why disable cache on `/api/*`? | APIs return per-user/dynamic data. Caching = stale or leaked data |
| Why `aws:SourceArn` on the bucket policy? | Pins access to **your** distribution. Without it, any CloudFront could read your bucket |
| Why SPA fallback (`403/404 → /index.html`)? | Client-side routing handles deep URLs that don't exist as S3 objects |
| Lambda cold start vs warm? | Cold = AWS provisions container (~100–500ms). Warm = reuses container |
| Why `tracing_config = "Active"`? | Lambda auto-emits X-Ray subsegments per AWS SDK call. No code change |
| `PAY_PER_REQUEST` vs `PROVISIONED` DynamoDB? | On-demand for spiky/low. Provisioned cheaper at high steady |
| What's the SES sandbox? | Default new-account mode. Sender + recipient must be verified. Production access = a support request |
| Why OIDC over stored AWS keys? | No long-lived secret. 1h credentials. Scoped to repo + ref via `sub` claim. Auditable per run |
| What does the `sub` claim look like? | `repo:owner/name:ref:refs/heads/main` |
| Why one IAM role per workflow in production? | Least privilege — frontend deploy needs S3 + CloudFront, not EC2/IAM |
| Why tag images with SHA + `latest`? | `:latest` is what the launch template pulls. SHA tag = immutable rollback target |

---

## 🏁 The "what kind of system did you build" recap

> *"It's a small but production-shaped 3-tier web app with a serverless side
> for event-driven features. Eight Terraform stacks, each with isolated S3
> state and DynamoDB locking, modeling a real multi-AZ deployment: VPC with
> three tiers across two AZs, ALB front-ending an EC2 ASG that runs a
> Dockerized FastAPI talking to a private RDS Postgres. Static React frontend
> served globally via CloudFront from a private S3 bucket, with `/api/*`
> routed to the ALB through the same CDN. Audit log and contact form are
> Lambdas behind API Gateway, hitting DynamoDB and SES respectively.
> Everything monitored by a CloudWatch dashboard + 8 alarms feeding an SNS
> topic. Shipped via GitHub Actions using OIDC federation — no AWS keys in
> the repo. Built to demonstrate every layer of the Well-Architected
> Framework: networking + security, compute + scaling, data + secrets, edge
> + delivery, serverless + tracing, observability + cost, automation."*

---

## 💸 Costs in one table

| Stack | Cost when running |
|---|---|
| `bootstrap` | Cents/month (state bucket + lock table) |
| `network` | $0 — no NAT Gateway, no Elastic IPs |
| `compute` | NAT t3.micro + app t3.micro + ALB — **$0 within free tier hours; eats them fast with 2 micros** |
| `database` | `db.t3.micro` single-AZ + Secrets Manager $0.40/mo |
| `cdn` | S3 (KB) + CloudFront (1TB/mo free) = ~$0 |
| `serverless-audit` | Lambda + DDB + API GW HTTP = ~$0 |
| `serverless-contact` | Lambda + SES ($0.10/1k mails) + API GW = ~$0 |
| `observability` | 8 alarms (first 10 free) + 1 dashboard (first 3 free) = $0 |
| `cicd` | $0 |

**Leave running**: bootstrap, network, cdn, serverless-*, observability, cicd. All ~$0.
**Destroy after labs**: compute, database. The two t3.micros + the ALB hours add up.

---

## 🧠 One-line answers for fast-fire questions

- *Region?* — `ap-south-1` (Mumbai), low latency for South Asia, good free tier
- *Why Terraform not CloudFormation?* — multi-cloud-friendly syntax, larger community, better state model
- *Why split into folders?* — state isolation; smaller blast radius; per-team ownership in real orgs
- *How did you handle secrets in state?* — S3 backend encrypts state at rest; public-access blocked; never output
- *What if Mumbai AZ-a fails?* — ALB serves from AZ-b node; ASG replaces EC2 in AZ-b; RDS would need Multi-AZ enabled to survive (currently it wouldn't)
- *How would you add a custom domain?* — Route 53 hosted zone + ACM cert in `us-east-1` + alias record → CloudFront distribution
- *How would you add caching for the patients list?* — ElastiCache (Redis) in private subnets + cache-aside in the FastAPI app; or DAX for DynamoDB
- *Logs aggregation?* — CloudWatch Logs + Logs Insights for now; production = ship to OpenSearch or Datadog
- *Deploy pipeline?* — PR runs `terraform plan` per stack; merge to main runs `apply` in dependency order, builds Docker → ECR, rolls ASG, builds React → S3 sync → CloudFront invalidate
- *How do you debug a 5xx in production?* — peel from the edge: CloudFront response → ALB target health → instance via SSM → docker logs → CloudWatch logs → X-Ray trace

---

## ✅ The night before — final 10 minutes

Recite these 8 sentences out loud:

1. *"Three tiers, two AZs, eight Terraform stacks, OIDC-deployed."*
2. *"Public is a routing decision. Private subnets have no `0.0.0.0/0` route."*
3. *"SG is stateful, per-resource, allow-only. NACL is stateless, per-subnet, allow+deny, needs ephemeral return rules."*
4. *"ALB requires ≥ 2 subnets in ≥ 2 AZs. AWS puts a node in each, one DNS name."*
5. *"EC2 wears an IAM role through an instance profile. Creds via IMDSv2. SSH is closed; access via SSM."*
6. *"RDS three locks: private subnet, db-sg trusting app-sg only, `publicly_accessible = false`."*
7. *"CloudFront + private S3 + OAC + `aws:SourceArn` on the bucket policy. `/api/*` routed to the ALB, no caching."*
8. *"OIDC trust policy pins `sub = repo:owner/name:ref:refs/heads/main`. No stored AWS keys."*

If you can say each one without thinking, you're ready.

Good luck.
