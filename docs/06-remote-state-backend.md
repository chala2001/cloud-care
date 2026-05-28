# 06 — Remote State Backend (your first real deploy)

> **Goal of this doc:** create a safe home for Terraform's **state** — an
> encrypted, versioned **S3 bucket** plus a **DynamoDB** lock table — and point
> Terraform at it. This is your **first time creating real AWS resources**, and
> it's nearly free.

By the end you'll have a professional state setup that every later phase reuses.

⏱️ Time: ~45 minutes. 💰 Cost: a few **cents per month** at most (well within
free tier).

---

## 1. Why we don't keep state on your laptop

In Doc 05 your state lived in a local `terraform.tfstate` file. That's fine for a
toy, but it has real problems:

| Problem with local state | Remote backend fixes it by |
|--------------------------|----------------------------|
| Lose the file → Terraform "forgets" everything it owns | Stored durably in S3 (11 nines) + **versioned** (every change kept) |
| Two people/runs at once → corrupt state | **Locking** via DynamoDB blocks concurrent writes |
| State holds secrets in plaintext | S3 **encryption at rest** + private bucket |
| No history of changes | S3 **versioning** lets you roll back |

> 🧠 **Interview-ready summary:** "We use an S3 backend with DynamoDB state
> locking. S3 gives durable, versioned, encrypted storage; the DynamoDB lock
> prevents two applies from racing and corrupting state." Memorize that sentence.

---

## 2. The chicken-and-egg problem (and how we solve it)

To store state in S3, we need an S3 bucket… which we create *with* Terraform…
which needs somewhere to store *its* state. Classic bootstrap problem.

**The standard solution:** create the backend resources in a small dedicated
config using **local state**, then use that bucket for everything else. The
bootstrap's own state is tiny, contains **no secrets**, and we simply keep it
locally (it rarely changes).

```
terraform/
├── bootstrap/        ← creates the S3 bucket + DynamoDB table (LOCAL state)
│                       run this ONCE, leave it running
└── (later phases)    ← VPC, compute, etc. — all use the S3 backend
```

---

## 3. Pick globally-unique names

> 🧠 **S3 bucket names are globally unique across ALL AWS accounts on Earth.** So
> `terraform-state` is long taken. We append your **account ID** to guarantee
> uniqueness.

Get your account ID:

```bash
export AWS_PROFILE=cloudcare
aws sts get-caller-identity --query Account --output text
# e.g. 123456789012
```

We'll name things:
- Bucket: `cloudcare-tfstate-<ACCOUNT_ID>` (e.g. `cloudcare-tfstate-123456789012`)
- Lock table: `cloudcare-tf-locks`

Substitute your real account ID wherever you see `<ACCOUNT_ID>` below.

---

## 4. Write the bootstrap config

Create the folder `terraform/bootstrap/` and these four files.

### `terraform/bootstrap/providers.tf`
```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # NOTE: no `backend` block here on purpose — the bootstrap uses LOCAL state,
  # because it's the thing that *creates* the remote backend.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "cloudcare"
      ManagedBy = "terraform"
      Component = "tfstate-backend"
    }
  }
}
```
> 🧠 `default_tags` auto-applies these tags to **every** resource this provider
> creates. Tags are how you find, group, and bulk-clean project resources later —
> and how you'd attribute cost in Cost Explorer. Free and invaluable.

### `terraform/bootstrap/variables.tf`
```hcl
variable "aws_region" {
  description = "AWS region for the state backend"
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform state"
  type        = string
  # no default — you must pass it, so you can't forget the account-id suffix
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform state locks"
  type        = string
  default     = "cloudcare-tf-locks"
}
```

### `terraform/bootstrap/main.tf`
```hcl
# ---------------------------------------------------------------------------
# S3 bucket that will hold Terraform state for ALL phases of this project.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # Safety net: refuse to destroy this bucket by accident. State buckets should
  # outlive everything else. To intentionally remove it, you'd edit this first.
  lifecycle {
    prevent_destroy = true
  }
}

# Keep every version of the state file (lets you roll back a bad apply).
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest with AWS-managed keys (SSE-S3). State can contain
# secrets (DB passwords), so this is non-negotiable.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block ALL public access to the bucket. State must never be public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB table used as a distributed LOCK so two `terraform apply` runs can't
# write state at the same time. Terraform expects a primary key named "LockID".
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "tf_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST" # on-demand: you pay per request, ~free at our scale
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S" # String
  }
}
```
> 🧠 **Why `PAY_PER_REQUEST`?** DynamoDB has two billing modes: *provisioned*
> (reserve capacity) and *on-demand* (pay per request). Locking is a handful of
> requests per apply, so on-demand costs essentially nothing and needs no
> capacity planning.

### `terraform/bootstrap/outputs.tf`
```hcl
output "state_bucket" {
  description = "Name of the S3 state bucket — use this in backend configs"
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  description = "Name of the DynamoDB lock table — use this in backend configs"
  value       = aws_dynamodb_table.tf_locks.name
}
```

---

## 5. Apply the bootstrap (creates the real resources)

From inside `terraform/bootstrap/`:

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

terraform init      # downloads the AWS provider for THIS folder

terraform fmt
terraform validate

# Pass your unique bucket name. Replace <ACCOUNT_ID> with your real account id.
terraform plan  -var="state_bucket_name=cloudcare-tfstate-<ACCOUNT_ID>"
terraform apply -var="state_bucket_name=cloudcare-tfstate-<ACCOUNT_ID>"
```

Read the plan: you should see **`Plan: 5 to add, 0 to change, 0 to destroy.`**
(bucket + versioning + encryption + public-access-block + dynamodb table). Type
`yes` to apply.

> 💡 Typing the `-var` every time is tedious. You may instead create
> `terraform/bootstrap/terraform.tfvars`:
> ```hcl
> state_bucket_name = "cloudcare-tfstate-123456789012"
> ```
> Then just run `terraform plan` / `terraform apply`. (This file has no secret,
> but `.gitignore` ignores `*.tfvars` by default — that's fine; commit a
> `terraform.tfvars.example` instead if you want a template in git.)

### Verify in the Console and CLI
```bash
aws s3 ls | grep cloudcare-tfstate          # your bucket appears
aws dynamodb list-tables --query TableNames  # cloudcare-tf-locks appears
```
Or look in the Console: **S3** → your bucket (check Properties show *Versioning:
Enabled* and *Encryption: Enabled*), and **DynamoDB → Tables**.

✅ You just created real, production-grade infrastructure with Terraform. 🎉

---

## 6. How later phases will USE this backend

Every *other* Terraform folder (VPC, compute, etc.) will start with a `backend`
block telling Terraform to store its state in your bucket. You'll see this from
Phase 1 onward. Preview:

```hcl
terraform {
  backend "s3" {
    bucket         = "cloudcare-tfstate-<ACCOUNT_ID>" # the bucket we just made
    key            = "network/terraform.tfstate"      # a unique PATH per component
    region         = "ap-south-1"
    dynamodb_table = "cloudcare-tf-locks"             # the lock table
    encrypt        = true
  }
}
```
> 🧠 The **`key`** is the path *inside* the bucket. We give each component its own
> key (`network/…`, `compute/…`, `database/…`) so their states are separate and
> a mistake in one can't corrupt another. This is called **state isolation**.

---

## 7. (Optional) Prove migration works using the sandbox

If you want to *see* a state move from local to S3, migrate the harmless
`learn-terraform` sandbox from Doc 05:

1. Add this to `terraform/learn-terraform/main.tf` inside the existing
   `terraform { ... }` block:
   ```hcl
   backend "s3" {
     bucket         = "cloudcare-tfstate-<ACCOUNT_ID>"
     key            = "sandbox/terraform.tfstate"
     region         = "ap-south-1"
     dynamodb_table = "cloudcare-tf-locks"
     encrypt        = true
   }
   ```
2. Re-init and let Terraform copy the existing state up:
   ```bash
   cd terraform/learn-terraform
   terraform init -migrate-state    # answer "yes" to copy local state to S3
   ```
3. Confirm the state object now exists in S3:
   ```bash
   aws s3 ls s3://cloudcare-tfstate-<ACCOUNT_ID>/sandbox/
   ```
   Your local `terraform.tfstate` is now just a stale copy; S3 is the source of
   truth.

> This step is optional learning. The sandbox has no billable resources, so it's
> a risk-free way to experience `-migrate-state`.

---

## 8. 💰 What this costs, and what to leave running

- **S3 state bucket:** a few KB of objects → effectively **$0** (free tier is
  5 GB; we use kilobytes).
- **DynamoDB lock table:** on-demand, a few requests per apply → effectively
  **$0** (free tier is generous).

> ⚠️ **Do NOT `terraform destroy` the `bootstrap` folder** during the project.
> It holds the state for everything else. It's nearly free and must stay up. We
> only tear it down at the very end of the project (Phase 8), and even then we
> first destroy everything that *uses* it. The `prevent_destroy = true` lifecycle
> rule will stop an accidental deletion.

---

## ✅ Checkpoint — end of Phase 0 🎉

You've completed the entire foundation. You should now have:

- [ ] A secured AWS account (root MFA + `chalaka-admin` IAM user with MFA).
- [ ] Budget + billing alarm + free-tier alerts (SNS email confirmed).
- [ ] AWS CLI v2 + Terraform installed and authenticating as `chalaka-admin`.
- [ ] A successful sandbox run (Doc 05) — you know `init/plan/apply/destroy`.
- [ ] A live **S3 + DynamoDB state backend** created by Terraform.
- [ ] A clear mental model of the architecture and the core concepts.

That is a genuinely strong foundation — most people skip half of this and regret
it. **Tell me when you've reached this checkpoint** (or if you hit any snag), and
I'll write **Phase 1 — Networking (the VPC)**: VPC, public/private subnets across
two AZs, Internet Gateway, route tables, NACLs, and the security-group chain —
the most interview-important phase of the whole project.

> Before you stop a session: you don't need to destroy the bootstrap (leave it).
> There's nothing else running yet, so you're at $0 ongoing.
