# 11 — Database: RDS PostgreSQL & Secrets Manager

> **Goal of this doc:** create CloudCare's **data tier** — a managed **RDS
> PostgreSQL** instance in the private **db** subnets, fronted by a **DB subnet
> group**, locked behind the `db-sg` you built in Phase 1, with its master
> password generated and stored in **Secrets Manager** (never in code). This is
> **Phase 3 — Database**, a single doc.

⏱️ Time: ~60 minutes (RDS itself takes ~5–10 min to create/destroy).
💰 Cost: ~$0 on a single-AZ `db.t3.micro` within free tier — **but RDS is the
biggest free-tier risk in the project.** Read §8 before you walk away, and
`terraform destroy` after the lab.

---

## 1. What we're building (and where it sits)

```
   ┌──────────────── PRIVATE app subnets (Phase 2) ───────────────┐
   │   EC2 (FastAPI, Phase 4)  ──┐                                 │
   └────────────────────────────┼──────────────────────────────────┘
                                 │ :5432  (app-sg ──► db-sg)
   ┌──────────────── PRIVATE db subnets (AZ-a, AZ-b) ─────────────┐
   │   DB subnet group spans both ──►  RDS PostgreSQL (single-AZ)  │
   │                                   • db-sg: only :5432 from app │
   │                                   • not publicly accessible    │
   │                                   • encrypted, auto-backups    │
   └───────────────────────────────────────────────────────────────┘

   Secrets Manager:  cloudcare/db/credentials  (username + generated password)
```

The database is the **most protected** resource in CloudCare: a private subnet
(no internet route) **and** a security group that trusts only the app tier. Even
other things inside the VPC can't reach it. That layered isolation is the whole
point of the three-tier design.

> 🧠 **Why RDS instead of running Postgres on EC2?** RDS is a *managed* database:
> AWS handles backups, patching, failover, and storage scaling. You stop being a
> part-time DBA and get reliability features that are hard to build yourself. The
> interview phrasing: "We use RDS so backups, patching, and (optional) Multi-AZ
> failover are managed, letting us focus on the app."

---

## 2. The Terraform folder

A fourth stack, its own state key (`database/...`) in the same bucket:

```
terraform/
├── bootstrap/   ← Phase 0 (leave it)
├── network/     ← Phase 1 (leave it — free)
├── compute/     ← Phase 2 (destroy after labs)
└── database/    ← Phase 3 — THIS doc
```

Files:

```
providers.tf   # terraform{} + backend{} (key=database/...) + the random provider
variables.tf   # region, project, db sizing, engine version, multi_az toggle
data.tf        # remote state (network) → db subnets + db-sg + vpc id
secrets.tf     # generate the password, store creds in Secrets Manager
rds.tf         # DB subnet group + the RDS instance
outputs.tf     # endpoint, port, secret ARN (NOT the password)
```

---

## 3. `providers.tf` — add the `random` provider

We need a second provider — HashiCorp's `random` — to generate a strong password
without ever typing one.

```hcl
# terraform/database/providers.tf

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "database/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "cloudcare-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "cloudcare"
      ManagedBy = "terraform"
      Component = "database"
    }
  }
}
```

---

## 4. `variables.tf`

```hcl
# terraform/database/variables.tf

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix"
  type        = string
  default     = "cloudcare"
}

variable "db_instance_class" {
  description = "RDS instance class (db.t3.micro is free-tier eligible)"
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "allocated_storage" {
  description = "Storage in GB (free tier covers 20 GB)"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the initial database"
  type        = string
  default     = "cloudcare"
}

variable "db_username" {
  description = "Master username (avoid reserved words like 'admin'/'postgres')"
  type        = string
  default     = "cloudcare_admin"
}

variable "backup_retention_days" {
  description = "Days of automated backups to keep (0 disables them)"
  type        = number
  default     = 1
}

variable "multi_az" {
  description = "Run a standby in a second AZ (DOUBLES cost — keep false to stay free)"
  type        = bool
  default     = false
}
```

> 💰 **`multi_az = false` by default.** A Multi-AZ deployment runs a *second*
> standby instance for automatic failover — and **doubles** your DB hours, blowing
> the 750-hour free tier. We *write* the production-grade option (just flip this to
> `true`) but keep it off, exactly as [Doc 01 §5](01-architecture-overview.md)
> promised. Flip it on to demo failover, then flip it back.

> 💡 **`engine_version = "16"`** lets RDS pick the latest 16.x at creation. If a
> later `terraform plan` shows a tiny version drift, either pin the exact minor
> (e.g. `"16.4"`) or check what's available:
> `aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion'`.

---

## 5. `data.tf` — read the network stack

```hcl
# terraform/database/data.tf

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "network/terraform.tfstate"
    region = "ap-south-1"
  }
}
```

We'll use `outputs.db_subnet_ids` and `outputs.db_security_group_id` from this.

---

## 6. `secrets.tf` — generate the password, store it safely

```hcl
# terraform/database/secrets.tf

# Generate a strong master password. Stored in TF state (which is why our state
# bucket is private + encrypted — Doc 06) and in Secrets Manager, never in code.
resource "random_password" "db" {
  length  = 20
  special = true
  # Exclude characters RDS rejects in master passwords (/, @, ", and spaces).
  override_special = "!#$%^&*()-_=+[]{}"
}

# A Secrets Manager secret to hold the DB connection details. The app (Phase 4)
# will read this at runtime instead of having credentials baked in.
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project}/db/credentials"
  description = "CloudCare RDS master credentials"

  # Learning-friendly: allow immediate delete + recreate (no 7–30 day window).
  recovery_window_in_days = 0
}

# The actual secret value — a JSON blob the app can parse.
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
  })
}
```

> 🧠 **No circular dependency here, even though it looks like one.** The RDS
> instance depends on `random_password` (for its password). The *secret version*
> depends on the RDS instance (for its host/port). The RDS instance does **not**
> depend on the secret. Terraform orders it: password → RDS → secret version.

> 💰🔒 **Secrets Manager is not free** — ~**$0.40 per secret per month** (+ tiny
> API charges). For one secret that's negligible, but know the free alternative:
> **SSM Parameter Store** `SecureString` is free. We use Secrets Manager because
> it's the professional choice (rotation, fine-grained access) and interview-
> relevant. `recovery_window_in_days = 0` means `terraform destroy` removes it
> immediately, stopping the charge.

---

## 7. `rds.tf` — the subnet group and the instance

```hcl
# terraform/database/rds.tf

# Tells RDS WHICH subnets it may place the database in. We give it both private
# db subnets so a Multi-AZ standby (if enabled) lands in the other AZ.
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = data.terraform_remote_state.network.outputs.db_subnet_ids

  tags = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-postgres"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # encrypt data at rest — non-negotiable for patient data

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  # Network placement: private subnets + the db-sg (only :5432 from app-sg).
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.db_security_group_id]
  publicly_accessible    = false # the DB must never have a public endpoint

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_days

  # Learning-friendly destroy behavior (do NOT use these defaults in production):
  skip_final_snapshot = true  # don't force a final snapshot when destroying
  deletion_protection = false # allow `terraform destroy`
  apply_immediately   = true  # apply changes now, not in the maintenance window

  tags = { Name = "${var.project}-postgres" }
}
```

> 🧠 **`publicly_accessible = false` + private subnets + db-sg = three locks.**
> The DB has no public IP, no internet route, and a firewall that only trusts the
> app tier. Be able to name all three when asked "how is the database secured?"

> ⚠️ **`skip_final_snapshot` / `deletion_protection = false` are LEARNING
> settings.** In production you'd keep a final snapshot and turn deletion
> protection *on* so nobody can `terraform destroy` your customer data by accident.
> We disable them so labs tear down cleanly — say this out loud in an interview so
> they know you know.

---

## 8. `outputs.tf` — endpoint yes, password no

```hcl
# terraform/database/outputs.tf

output "db_endpoint" {
  description = "RDS connection endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "db_address" {
  description = "RDS hostname"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}
```

> 🧠 **We never output the password.** The app reads it from Secrets Manager at
> runtime using its IAM role. Outputting it would print it to the console and
> store it in plaintext anywhere `terraform output` is captured.

---

## 9. Apply & verify

From inside `terraform/database/`:

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

terraform init        # downloads the aws AND random providers; configures backend
terraform fmt
terraform validate
terraform plan
```

Expect **`Plan: 5 to add, 0 to change, 0 to destroy.`** —

| Resource | Count |
|----------|------:|
| `random_password` | 1 |
| Secrets Manager secret + version | 2 |
| DB subnet group | 1 |
| RDS instance | 1 |
| **Total** | **5** |

```bash
terraform apply       # type "yes" — creating the RDS instance takes ~5-10 min
```

### Verify with the CLI

```bash
# The instance is "available", single-AZ, NOT publicly accessible:
aws rds describe-db-instances \
  --db-instance-identifier cloudcare-postgres \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,Public:PubliclyAccessible,Engine:EngineVersion,Class:DBInstanceClass}' \
  --output table

# The endpoint Terraform recorded:
terraform output db_endpoint

# The credentials landed in Secrets Manager (this DOES print the password —
# only run it when you need it; it proves the secret is populated):
aws secretsmanager get-secret-value \
  --secret-id cloudcare/db/credentials \
  --query SecretString --output text
```

You want `Status = available`, `Public = False`, `MultiAZ = False`.

> 🧠 **Why we don't `psql` into it here.** The DB is private, and our app
> instances (Phase 2) have no shell (no SSM endpoints / no NAT). Real
> connectivity gets exercised in **Phase 4**, when the FastAPI app — running on an
> app-subnet instance that the db-sg trusts — reads the secret and connects. For
> now, "available + private + secret populated" is the correct finish line.

> 💡 **Want to prove connectivity now (optional)?** Temporarily set the ASG
> desired to 1, add SSM interface endpoints (small cost) or a NAT instance, open
> an SSM shell on an app instance, `sudo dnf install -y postgresql15`, then
> `psql "host=<db_address> user=cloudcare_admin dbname=cloudcare"`. Tear the
> extras down afterward. Most people skip this until Phase 4.

---

## 10. 💰 Cost & teardown (the most important section this phase)

RDS is where surprise bills happen. Guard rails:

| Resource | Free-tier status |
|----------|------------------|
| `db.t3.micro` single-AZ | ✅ 750 hrs/month for 12 months (≈ one instance all month) |
| Multi-AZ (`multi_az = true`) | ⚠️ **doubles** hours → leaves free tier |
| 20 GB gp3 storage | ✅ within 20 GB free-tier |
| Automated backups | ✅ up to 100% of storage free |
| Secrets Manager secret | ⚠️ ~$0.40/month (not free tier) |

> 💰 **Teardown after every lab session:**
> ```bash
> terraform destroy   # in terraform/database/  — ~5-10 min
> ```
> Because `skip_final_snapshot = true`, this removes the instance cleanly and
> `recovery_window_in_days = 0` deletes the secret immediately — back to ~$0.
> **Leave `network/` and `bootstrap/` up.** Recreate the DB anytime with
> `terraform apply` (you'll get a *fresh, empty* database and a new password —
> fine, since the schema/data come from the app in Phase 4).

> ⚠️ Don't forget: if you left **compute** running from Phase 2, destroy that too
> (the ALB is the other thing that costs money). Only `network/` and `bootstrap/`
> should ever be left running between sessions.

---

## ✅ Checkpoint — end of Phase 3 🎉

You've built CloudCare's data tier. You should now have, in
`terraform/database/` (state key `database/...`):

- [ ] An RDS PostgreSQL `db.t3.micro`, single-AZ, **encrypted**, `available`.
- [ ] A DB subnet group spanning both private db subnets.
- [ ] The instance attached to `db-sg` and **not publicly accessible**.
- [ ] A generated master password stored in **Secrets Manager** (never in code or
      outputs).
- [ ] Outputs for the endpoint and secret ARN, ready for the app to consume.

And you can explain, from memory:

- Why the DB lives in a private subnet **and** behind a security group (the three
  locks).
- Why we use RDS (managed backups/patching/failover) over self-hosting Postgres.
- The Multi-AZ trade-off (failover vs double cost) and how you'd enable it.
- Why the password is generated and stored in Secrets Manager, not written down.

> With Phases 1–3 done you now have the **entire infrastructure backbone**:
> network, compute, and data. Everything from here builds *on* it.

**Tell me when you've reached this checkpoint** (and that you've destroyed the
compute + database stacks), and I'll write **Phase 4 — The Application**: the
FastAPI backend (reading the DB secret, talking to RDS), the React frontend, and
getting it running locally and on the EC2 app tier — including how we finally give
the private instances the egress they need to pull the app.

Next: **Phase 4 — The Application** (docs 12–14, written when you reach this
checkpoint).
