# 11 — Database: RDS PostgreSQL & Secrets Manager

> **Goal of this doc:** create CloudCare's **data tier** — a managed **RDS
> PostgreSQL** instance in the private **db** subnets, fronted by a **DB subnet
> group**, locked behind the `db-sg` you built in Phase 1, with its master
> password generated and stored in **Secrets Manager** (never in code). This is
> **Phase 3 — Database**, a single doc.

⏱️ Time: ~60 minutes (RDS itself takes ~5–10 min to create/destroy).
💰 Cost: ~$0 on a single-AZ `db.t3.micro` within free tier — **but RDS is the
biggest free-tier risk in the project.** Read §10 before you walk away, and
`terraform destroy` after the lab.

---

## 0. Beginner read-me first — vocabulary in one place

RDS and Secrets Manager both have their own jargon. Re-read this card whenever
something feels foreign.

| Word | Plain-English meaning |
|---|---|
| **RDS** (Relational Database Service) | AWS's managed-database service. You ask for a DB; AWS handles the OS, the DB engine install, patches, backups, and (optionally) failover. |
| **Engine** | Which database product (`postgres`, `mysql`, `mariadb`, `oracle`, `sqlserver`, `aurora-postgresql`). We use `postgres`. |
| **Engine version** | Specific version of the engine (e.g. `"16"` = latest 16.x at create time, or pin to `"16.4"`). |
| **Instance class** | The hardware shape, prefixed `db.` to distinguish from EC2. `db.t3.micro` = 1 vCPU, 1 GB RAM, free-tier eligible. |
| **`identifier`** | The DB's name in AWS (like an EC2 instance ID, but human). |
| **`db_name`** | The **logical database** auto-created inside Postgres on first boot. Not the same as the instance identifier. |
| **Master username / password** | The bootstrap admin account RDS creates inside the DB. We never use it from the app; we'd create per-app users instead in production. |
| **`allocated_storage`** | Disk size in GB. |
| **`storage_type`** | The disk family. `gp3` = General Purpose SSD v3 — modern default, good price/perf. |
| **`storage_encrypted`** | Encrypt the disk at rest with AWS-managed keys. Free; non-negotiable for any real data. |
| **DB subnet group** | A **named set of subnets** RDS may place the instance in. AWS **requires** ≥2 subnets in ≥2 AZs, even for single-AZ deployments — so a future flip to Multi-AZ has somewhere to put the standby. |
| **`publicly_accessible`** | If `true`, the DB gets a public DNS endpoint reachable from the internet (filtered by SG). **Should be `false` for any real database.** |
| **`multi_az`** | If `true`, AWS creates a **synchronous standby replica** in another AZ. Doubles cost; gives automatic ~1-min failover. |
| **Read replica** | A separate, asynchronous read-only copy for scaling reads. We don't use one. |
| **Automated backups (`backup_retention_period`)** | Number of days to keep daily snapshots. `0` disables. |
| **Final snapshot** | A snapshot taken when the instance is deleted. `skip_final_snapshot = true` skips it — great for labs, dangerous in production. |
| **`deletion_protection`** | If `true`, AWS refuses to delete the instance. Final safety net in production. |
| **Maintenance window** | A weekly time slot AWS may apply automatic minor-version patches. `apply_immediately = true` bypasses it for changes you make. |
| **Secrets Manager** | AWS's service for storing sensitive strings (passwords, API keys, certificates) with encryption + IAM-controlled access + audit logs. |
| **Secret (in Secrets Manager)** | A **named container** for a value. Like an envelope with a label. |
| **Secret version** | The actual **value** inside the envelope. Each new value is a new version; old ones are retained. |
| **`recovery_window_in_days`** | When a secret is deleted, AWS holds it in soft-delete for this many days. `0` = hard-delete immediately. |
| **`random_password` (Terraform random provider)** | A built-in helper that generates a random string at apply time, stored in state. Stable across re-applies (won't regenerate unless tainted). |
| **`jsonencode()`** | A Terraform built-in that turns an HCL map into a JSON string. Used for secret contents. |
| **ARN** (Amazon Resource Name) | Unique address for any AWS thing: `arn:aws:<svc>:<region>:<account>:<resource>/<name>`. |
| **Three locks (security)** | The protections around our DB: ① private subnet (no internet route), ② `db-sg` (only the app tier may connect), ③ `publicly_accessible = false` (no public endpoint). |

Now the picture.

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

### How the three actors actually communicate (the key insight)

A misconception worth killing up front:

> **RDS and Secrets Manager do NOT talk to each other at runtime.**

Terraform writes the same password to **both places** at create time:

```
random_password.db   →  one random value, e.g. "Xy7!aR9q..."
        │
        ├──► RDS instance   (Terraform sets it as the master password)
        │       password = random_password.db.result
        │
        └──► Secrets Manager (Terraform writes the JSON blob there)
                secret_string = jsonencode({ password = random_password.db.result, ... })
```

At runtime:
- **RDS** doesn't read from Secrets Manager — it just accepts whatever password
  Terraform set.
- **The app** (Phase 4) reads the JSON from Secrets Manager and uses the
  password to connect to RDS.

So the secret in Secrets Manager exists **for the app to look up**, not for
RDS. That's why the app's IAM role needs `secretsmanager:GetSecretValue` —
without it, the app can't fetch its own credentials at startup.

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

### What each file's job is, in one sentence

| File | One-line purpose |
|---|---|
| `providers.tf` | Connect to AWS; load the `random` provider too; store state under `database/`. |
| `variables.tf` | Inputs: region, project, DB size/engine, multi-AZ toggle, backup retention. |
| `data.tf` | **Read** the network stack's outputs (subnet IDs, SG ID, VPC ID). Creates nothing. |
| `secrets.tf` | Generate a password, create the secret container, store the JSON value. |
| `rds.tf` | Create the DB subnet group and the actual Postgres instance. |
| `outputs.tf` | Publish endpoint, port, and **secret ARN** — never the password. |

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

### What every line does

This is structurally identical to your previous `providers.tf` files, with
**two** real differences: the new `random` provider declaration and a fresh
state `key`.

| Line | Meaning |
|---|---|
| `required_providers.aws` | Install the AWS plugin (same as before). |
| `required_providers.random` | **NEW.** Install HashiCorp's **random** provider — generates random strings, IDs, passwords. The `~> 3.0` operator allows any `3.x`. |
| `backend "s3"` block | Same bucket as other stacks; **`key = "database/..."`** isolates this stack's state. |
| `provider "aws"` | Region + `Component = "database"` default tags so every resource is identifiable. |

> 🧠 **Why a separate provider for randomness?** Random generation is *not* an
> AWS thing — it happens locally in Terraform. The `random` provider is the
> official way to ask Terraform for a value (random string, UUID, integer)
> stored deterministically in state. Re-applies don't regenerate it unless you
> `terraform taint` it.

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

### Each variable in context

| Variable | What it controls | Override how |
|---|---|---|
| `aws_region` | Where the DB lives. Default Mumbai. | `-var='aws_region=...'` |
| `project` | Prefix for the `Name` tag. | `-var='project=...'` |
| `db_instance_class` | Hardware shape. `db.t3.micro` = free-tier. Bigger options: `db.t3.small`, `db.m6g.large`. | `-var='db_instance_class=db.t3.small'` |
| `engine_version` | Postgres major version. `"16"` lets RDS pick the latest 16.x; pin like `"16.4"` if you need an exact one. | `-var='engine_version=16.4'` |
| `allocated_storage` | Disk size in GB. Free tier covers 20 GB. | `-var='allocated_storage=50'` |
| `db_name` | The initial logical database name **inside Postgres** (auto-`CREATE DATABASE cloudcare;` on first boot). | `-var='db_name=...'` |
| `db_username` | Master user. **Avoid reserved words** like `postgres`, `admin`, `root`. | `-var='db_username=...'` |
| `backup_retention_days` | Days of automated snapshots. `1` = one day. `0` = backups disabled. | `-var='backup_retention_days=7'` |
| `multi_az` | If `true`, AWS creates a sync standby in the other AZ. **Doubles cost.** Default `false`. | `-var='multi_az=true'` |

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

### Line-by-line

| Line | Meaning |
|---|---|
| `data "terraform_remote_state" "network"` | A special data source: read another Terraform stack's state file from a remote backend. Nickname `network`. |
| `backend = "s3"` | "It's an S3-backend state." |
| `config = { bucket = ..., key = "network/terraform.tfstate", region = ... }` | **Where** to find it — same bucket, network folder's key. |

Once this data source is loaded, we use these outputs from the network stack:

| Reference | What it returns |
|---|---|
| `data.terraform_remote_state.network.outputs.db_subnet_ids` | `["subnet-...db-a", "subnet-...db-b"]` |
| `data.terraform_remote_state.network.outputs.db_security_group_id` | the `db-sg` ID |
| `data.terraform_remote_state.network.outputs.vpc_id` | the VPC ID |

This is the same cross-stack pattern from the compute folder — published as
`output` blocks over there, consumed as `data.terraform_remote_state` reads
here.

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

This file has **three** blocks that together produce one usable secret:

### Block 1 — generate the password

```hcl
resource "random_password" "db" {
  length  = 20
  special = true
  override_special = "!#$%^&*()-_=+[]{}"
}
```

| Line | Meaning |
|---|---|
| `resource "random_password" "db"` | From the `random` provider — generate a random string. Nickname `db`. |
| `length = 20` | 20 characters long. |
| `special = true` | Include special characters. |
| `override_special = "!#$%^&*()-_=+[]{}"` | **Replace** the default special-char set with this safer subset. RDS rejects master passwords containing `/`, `@`, `"`, or spaces — leaving those out avoids a confusing failure later. |

Accessed elsewhere as `random_password.db.result` — the actual string.

> 🧠 **Why a random password instead of typing one?** It's strong, never
> committed to git, and re-creating the infra produces the *same* password
> (because it's in state) — so existing apps stay connected. The tradeoff is
> that the password ends up in `terraform.tfstate`, which is exactly why our S3
> backend (Doc 06) is **encrypted at rest** and access-blocked.

### Block 2 — the secret container (no value yet)

```hcl
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project}/db/credentials"
  description = "CloudCare RDS master credentials"
  recovery_window_in_days = 0
}
```

| Line | Meaning |
|---|---|
| `resource "aws_secretsmanager_secret" "db"` | Create a **named slot** in Secrets Manager. Like an envelope with a label but no letter inside yet. |
| `name = "${var.project}/db/credentials"` | The address in Secrets Manager: `cloudcare/db/credentials`. The `/` is purely a naming convention for grouping. |
| `description` | Human note in the console. |
| `recovery_window_in_days = 0` | When you delete this secret, AWS normally holds it in soft-delete for **7–30 days** for recovery. `0` = **hard-delete immediately.** Convenient for learning (no leftover charges); dangerous in production (no undo). |

Block 2 creates a slot. Block 3 fills it.

### Block 3 — the secret value (JSON blob the app can parse)

```hcl
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

| Line | Meaning |
|---|---|
| `resource "aws_secretsmanager_secret_version" "db"` | Put a **value** into the slot from Block 2. |
| `secret_id = aws_secretsmanager_secret.db.id` | Which slot to fill. |
| `secret_string = jsonencode({ ... })` | The value, as a **JSON string** (one `GetSecretValue` API call gives the app everything it needs). |
| `jsonencode({...})` | A built-in Terraform function: turn an HCL map into a JSON string. |
| `password = random_password.db.result` | The string from Block 1. |
| `host = aws_db_instance.main.address` / `port = aws_db_instance.main.port` | The DB's network address and port (from `rds.tf`). |

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

### Block 1 — the DB subnet group

A **DB subnet group** is a **named set of subnets** that RDS may live in. AWS
**requires** every RDS instance to point at one.

```hcl
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = data.terraform_remote_state.network.outputs.db_subnet_ids
  tags = { Name = "${var.project}-db-subnet-group" }
}
```

| Line | Meaning |
|---|---|
| `resource "aws_db_subnet_group" "main"` | Create a DB subnet group. |
| `name = ...` | AWS-visible name. |
| `subnet_ids = data.terraform_remote_state.network.outputs.db_subnet_ids` | The **list** of subnet IDs — both private db subnets, from the network stack. |

> 🧠 **Why both subnets, even though we run single-AZ?** AWS **requires** a DB
> subnet group to cover **≥2 AZs**. The actual instance lives in **one** of them
> (single-AZ); the other subnet sits empty but **registered** — ready if you
> later flip `multi_az = true`. The subnet group is the "future-readiness" hook.

### Block 2 — the RDS instance itself

This is the longest single block in the project, so I'll group by purpose.

#### 2a — Identity & engine

```hcl
identifier     = "${var.project}-postgres"
engine         = "postgres"
engine_version = var.engine_version
instance_class = var.db_instance_class
```

| Line | Meaning |
|---|---|
| `identifier = "cloudcare-postgres"` | AWS-visible name of the DB instance (like an EC2 instance ID, but human). |
| `engine = "postgres"` | The DB engine. Alternatives: `mysql`, `mariadb`, `aurora-postgresql`, etc. |
| `engine_version` | The version (e.g. `"16"` for latest 16.x). |
| `instance_class` | Hardware shape (`db.t3.micro`). Note the `db.` prefix vs EC2's `t3.micro`. |

#### 2b — Storage

```hcl
allocated_storage = var.allocated_storage
storage_type      = "gp3"
storage_encrypted = true
```

| Line | Meaning |
|---|---|
| `allocated_storage = 20` | Disk size in GB. |
| `storage_type = "gp3"` | gp3 is the modern default for SSD storage (better price/perf than gp2). |
| `storage_encrypted = true` | Encrypt at rest with AWS-managed keys. **Essential for real data**, free, and required for healthcare-style workloads. |

#### 2c — Initial DB & master user

```hcl
db_name  = var.db_name
username = var.db_username
password = random_password.db.result
```

| Line | Meaning |
|---|---|
| `db_name = "cloudcare"` | The **logical database** auto-created inside Postgres on first boot. Not the same as the instance identifier. |
| `username = "cloudcare_admin"` | The master account name. |
| `password = random_password.db.result` | The generated password from `secrets.tf`. **Never typed, never in git.** |

#### 2d — Network placement (the security model)

```hcl
db_subnet_group_name   = aws_db_subnet_group.main.name
vpc_security_group_ids = [data.terraform_remote_state.network.outputs.db_security_group_id]
publicly_accessible    = false
```

| Line | Meaning |
|---|---|
| `db_subnet_group_name` | Use the subnet group from Block 1 → places the DB only in private DB subnets. |
| `vpc_security_group_ids = [...]` | Attach the **db-sg** from Phase 1 (only `:5432` from `app-sg`). |
| `publicly_accessible = false` | **No public DNS endpoint.** The DB is reachable only from inside the VPC. |

These three lines together are the entire "DB is locked down" story.

#### 2e — HA & backups

```hcl
multi_az                = var.multi_az
backup_retention_period = var.backup_retention_days
```

| Line | Meaning |
|---|---|
| `multi_az` | If `true`, AWS creates a **synchronous standby** in the other AZ. Failover takes ~60–120s. Doubles the bill. We leave it `false`. |
| `backup_retention_period` | Days of automated daily snapshots to keep. `0` disables; `7` is a common default. |

#### 2f — Destroy & change behavior (learning-friendly, **NOT production**)

```hcl
skip_final_snapshot = true
deletion_protection = false
apply_immediately   = true
```

| Line | Meaning | Production version |
|---|---|---|
| `skip_final_snapshot = true` | On `terraform destroy`, **don't** take a parting snapshot. Faster for labs. | `false` — always keep a final snapshot. |
| `deletion_protection = false` | Allow `terraform destroy` to delete the DB. | `true` — a final safety net. |
| `apply_immediately = true` | Apply changes **right now**, not during the AWS maintenance window. | `false` — schedule disruptive changes. |

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

| Output | What it is | Who reads it |
|---|---|---|
| `db_endpoint` | Combined `host:port` (e.g. `cloudcare-postgres.xxx.rds.amazonaws.com:5432`). | Humans and connection strings. |
| `db_address` | Just the host. | Programs that want host + port separately. |
| `db_port` | Just the port (5432). | Same. |
| `db_secret_arn` | The ARN of the Secrets Manager secret. | The app's IAM policy will scope `secretsmanager:GetSecretValue` to **exactly this ARN**, not `*`. |

> 🧠 **We never output the password.** The app reads it from Secrets Manager at
> runtime using its IAM role. Outputting it would print it to the console and
> store it in plaintext anywhere `terraform output` is captured.

> 💡 In Doc 18 (Observability) you'll add a fifth output, `db_identifier`,
> used by CloudWatch RDS alarms. You can add new outputs anytime without
> changing any infrastructure — just re-apply.

---

## 9. Apply & verify

From inside `terraform/database/`:

### Step 1 — Credentials

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1
```

### Step 2 — `terraform init`

```bash
terraform init
```

What this does:
1. Downloads the AWS provider (cached).
2. Downloads the **random** provider (also cached).
3. Connects to S3 to check for `database/terraform.tfstate` (none yet).
4. Connects to the DynamoDB lock table.
5. Writes `.terraform.lock.hcl` pinning both provider versions.

### Step 3 — Lint, validate, plan

```bash
terraform fmt
terraform validate
terraform plan
```

Expect **`Plan: 5 to add, 0 to change, 0 to destroy.`** —

| Resource | Count |
|----------|------:|
| `random_password.db` | 1 |
| Secrets Manager secret + version | 2 |
| DB subnet group | 1 |
| RDS instance | 1 |
| **Total** | **5** |

### Step 4 — Apply

```bash
terraform apply       # type "yes" — creating the RDS instance takes ~5-10 min
```

What happens:
1. DynamoDB lock acquired.
2. `random_password.db` evaluates → a fresh password is stored in state.
3. DB subnet group created (instant).
4. RDS instance **creation begins** — AWS provisions the VM, installs Postgres,
   bootstraps the master user + db_name, sets the password. **Takes ~5–10 min**;
   Terraform sits showing `Still creating... [Nm0s elapsed]` lines.
5. Once the DB is `available`, the secret container is created.
6. Then the secret version is written (it depends on the DB's `address` and
   `port`, hence ordered last).
7. State saved; lock released; outputs printed.

> 💡 **The long pause on RDS creation is normal.** AWS is provisioning real
> hardware, attaching encrypted storage, and bootstrapping the engine. There's
> no log to watch during this — it just takes the time it takes.

### Step 5 — Verify with the CLI

#### Confirm the instance is healthy and private

```bash
aws rds describe-db-instances \
  --db-instance-identifier cloudcare-postgres \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,Public:PubliclyAccessible,Engine:EngineVersion,Class:DBInstanceClass}' \
  --output table
```

**Decoded:**

- `aws rds describe-db-instances` — query RDS instances.
- `--db-instance-identifier cloudcare-postgres` — just our DB.
- `--query 'DBInstances[0].{Status:..., ...}'` — JMESPath: pull the first DB
  instance, pick five fields (renamed) for the table.
- `--output table` — pretty-print.

You want:
- `Status = available` ✅
- `Public = False` ✅ (no public endpoint)
- `MultiAZ = False` ✅ (single-AZ, free tier)
- `Engine = 16.x` ✅
- `Class = db.t3.micro` ✅

#### See the endpoint Terraform recorded

```bash
terraform output db_endpoint
# → cloudcare-postgres.xxxxxx.ap-south-1.rds.amazonaws.com:5432
```

#### Confirm the secret is populated

```bash
aws secretsmanager get-secret-value \
  --secret-id cloudcare/db/credentials \
  --query SecretString --output text
```

**Decoded:**

- `aws secretsmanager get-secret-value` — fetch a secret's current value.
- `--secret-id cloudcare/db/credentials` — by name.
- `--query SecretString --output text` — print just the secret string (the JSON
  blob), as raw text.

Output looks like:
```json
{"username":"cloudcare_admin","password":"...","engine":"postgres","host":"cloudcare-postgres...","port":5432,"dbname":"cloudcare"}
```

> ⚠️ **This command prints the password to your terminal.** Don't run it
> casually, and never paste its output into chat. It exists only to *prove* the
> secret is correctly populated.

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

## 11. Plain-English summary (what you just built)

If asked to explain Phase 3:

1. **One RDS PostgreSQL instance** (`cloudcare-postgres`, version 16.x,
   `db.t3.micro`), single-AZ, in a private DB subnet, with encrypted storage,
   one day of automated backups.
2. **One DB subnet group** spanning both private DB subnets — required by AWS
   even for single-AZ, so a future Multi-AZ flip has somewhere to place the
   standby.
3. **Three locks** on the database:
   - private subnet (no internet route),
   - `db-sg` (only `app-sg` may connect on `:5432`),
   - `publicly_accessible = false` (no public endpoint).
4. **One generated password** (`random_password.db`, 20 chars, RDS-safe specials)
   set as the RDS master password **directly** by Terraform.
5. **One Secrets Manager secret** (`cloudcare/db/credentials`) holding a JSON
   blob with username, password, host, port, dbname — for the **app** to read
   at runtime. RDS and Secrets Manager don't talk to each other; the app is
   the one that fetches the secret.
6. **Four outputs** (endpoint, address, port, secret ARN) for downstream stacks
   — **never the password**.

---

## 12. Interview soundbites

- **Three locks** — *"The database is in a private subnet with no internet
  route, behind a security group that only the app SG can reach, with
  `publicly_accessible = false`. Three independent walls between the internet
  and the data."*

- **Why RDS over self-hosted Postgres** — *"RDS is managed: AWS handles
  backups, patching, storage scaling, and (optional) Multi-AZ failover.
  Self-hosting Postgres on EC2 means I become a part-time DBA — at our scale
  that's the wrong trade-off."*

- **Multi-AZ trade-off** — *"`multi_az = true` creates a synchronous standby in
  another AZ — automatic ~60-second failover, but it doubles the DB cost. For
  the lab we leave it off; the architecture is one flag away from production
  HA."*

- **DB subnet group requires 2 AZs** — *"AWS requires a DB subnet group to span
  ≥2 AZs, even for single-AZ deployments — that way enabling Multi-AZ later
  doesn't require new networking."*

- **Password handling** — *"The password is generated by Terraform and pushed to
  both RDS (as the master password) and Secrets Manager (as a JSON blob with
  the full connection details). RDS and Secrets Manager don't communicate; the
  app reads from Secrets Manager at startup. We never type the password and
  never output it."*

- **Secrets Manager vs SSM Parameter Store** — *"Secrets Manager gives us
  rotation, fine-grained IAM, and audit logs but costs ~$0.40/secret/month.
  Parameter Store SecureString is free but less feature-rich. For database
  credentials, Secrets Manager is the professional default."*

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
- **That RDS and Secrets Manager do not talk to each other** — the app is what
  bridges them.

> With Phases 1–3 done you now have the **entire infrastructure backbone**:
> network, compute, and data. Everything from here builds *on* it.

**Tell me when you've reached this checkpoint** (and that you've destroyed the
compute + database stacks), and I'll write **Phase 4 — The Application**: the
FastAPI backend (reading the DB secret, talking to RDS), the React frontend, and
getting it running locally and on the EC2 app tier — including how we finally give
the private instances the egress they need to pull the app.

Next: **Phase 4 — The Application** (docs 12–14, written when you reach this
checkpoint).
