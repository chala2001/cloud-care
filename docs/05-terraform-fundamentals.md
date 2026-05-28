# 05 — Terraform Fundamentals

> **Goal of this doc:** understand how Terraform *thinks* — declarative code,
> providers, resources, variables, outputs, and (crucially) **state** and the
> **plan/apply** workflow. We finish with a tiny, **100% free** hands-on run so
> the workflow is in your fingers before we build anything real.

This is the most important conceptual doc in Phase 0. Read slowly.

---

## 1. What is Infrastructure as Code (IaC)?

Normally you'd create AWS resources by clicking around the Console ("click-ops").
That's slow, error-prone, and impossible to review or reproduce. **IaC** means
you *describe* your infrastructure in text files, commit them to Git, and a tool
builds it for you — repeatably.

**Terraform** is the most popular IaC tool. You write `.tf` files describing the
**desired end state** ("I want a VPC with these subnets"), and Terraform figures
out the API calls to make reality match.

> 🧠 **Declarative vs imperative.** Imperative = "do step 1, then step 2"
> (a script). Declarative = "here's what the world should look like" (Terraform).
> You don't tell Terraform *how* to create a subnet; you say *that one should
> exist*, and it computes the difference between now and your description.

**Why interviewers love IaC:** it's reproducible (rebuild prod in any region),
reviewable (diffs in pull requests), and self-documenting (the code *is* the
architecture). It's the backbone of modern SRE/DevOps.

---

## 2. The mental model: desired state, real state, and *state file*

Terraform juggles three things:

1. **Configuration** (`.tf` files) — what you *want*.
2. **Real infrastructure** — what *actually exists* in AWS.
3. **State** (`terraform.tfstate`) — Terraform's *record* of what it created and
   the mapping between your code and real AWS resource IDs.

When you run `terraform apply`, Terraform:
- reads your config (desired),
- reads its state (what it thinks exists),
- refreshes against the real AWS API (what truly exists),
- computes a **diff**, and
- makes the minimal changes to reconcile them.

> 🧠 **Why state matters (and is dangerous):** the state file is the source of
> truth linking `aws_vpc.main` in your code to `vpc-0abc123` in AWS. If you lose
> it, Terraform "forgets" it owns those resources. If you commit it to Git, you
> may leak secrets (DB passwords live there in plaintext). **That's why Doc 06
> moves state to a locked, encrypted S3 backend.** For now, just know: state is
> precious and sensitive.

---

## 3. HCL — the language you write Terraform in

Terraform files use **HCL (HashiCorp Configuration Language)**. The whole
language is basically **blocks** containing **arguments**.

```hcl
block_type "label_one" "label_two" {
  argument_name = value
  nested_block {
    other = "thing"
  }
}
```

A concrete example:

```hcl
resource "aws_vpc" "main" {        # block_type=resource, type="aws_vpc", name="main"
  cidr_block = "10.0.0.0/16"       # an argument
  tags = {                         # a map argument
    Name = "cloudcare-vpc"
  }
}
```

**Value types you'll use:**
- string `"hello"`, number `42`, bool `true`
- list `["a", "b"]`
- map `{ Name = "x", Env = "dev" }`

**Comments:** `#` or `//` for one line, `/* ... */` for blocks.

---

## 4. The five building blocks you'll use constantly

### 4.1 `terraform` block — settings about Terraform itself
```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"   # where to download the AWS provider
      version = "~> 5.0"          # any 5.x version
    }
  }
}
```
> `~> 5.0` means "5.x but not 6.0" — pinning versions keeps your builds
> reproducible. The `required_providers` block tells Terraform which plugins to
> download during `init`.

### 4.2 `provider` block — configures a platform (AWS)
```hcl
provider "aws" {
  region = "ap-south-1"
  # credentials come from your AWS_PROFILE / ~/.aws — never hardcode keys here!
}
```
> 🧠 A **provider** is a plugin that knows how to talk to one platform's API
> (AWS, GitHub, Cloudflare...). The AWS provider turns your `resource` blocks
> into AWS API calls. It reads the *same* credentials the AWS CLI uses (Doc 04).

### 4.3 `resource` block — something Terraform creates & manages
```hcl
resource "aws_s3_bucket" "uploads" {
  bucket = "cloudcare-uploads-12345"
}
```
- `"aws_s3_bucket"` = the **resource type** (defined by the AWS provider).
- `"uploads"` = the **local name** you choose, used to reference it elsewhere as
  `aws_s3_bucket.uploads`.
- Terraform will **create, update, or delete** this to match your code.

### 4.4 `data` source — something Terraform *reads* but doesn't manage
```hcl
data "aws_availability_zones" "available" {
  state = "available"
}
```
Use a **data source** to look up existing info (AZs in the region, your account
ID, the latest AMI). It creates nothing; it just *queries*. Referenced as
`data.aws_availability_zones.available.names`.

### 4.5 `variable` and `output` — inputs and results
```hcl
variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "dev"
}

output "vpc_id" {
  description = "The ID of the created VPC"
  value       = aws_vpc.main.id
}
```
- **Variables** are inputs you can change per run/environment (set via
  `-var`, a `.tfvars` file, env vars, or `default`).
- **Outputs** are values Terraform prints after apply and that other configs can
  consume (e.g., "here's the VPC ID").

> 💡 **`locals`** are named expressions for reuse within a config (not inputs):
> ```hcl
> locals {
>   name_prefix = "cloudcare-${var.environment}"
> }
> ```
> Reference as `local.name_prefix`. Great for consistent naming/tagging.

### 4.6 Referencing & interpolation
You wire resources together by referencing attributes:
```hcl
resource "aws_subnet" "public_a" {
  vpc_id     = aws_vpc.main.id          # use the VPC's real ID once created
  cidr_block = "10.0.0.0/24"
}
```
`"${...}"` injects a value into a string: `"cloudcare-${var.environment}"`.
Terraform reads these references to figure out **dependency order** (it knows the
subnet needs the VPC first) — you rarely specify order manually.

---

## 5. The core workflow (memorize these five commands)

```
terraform init      → download providers, set up the working dir / backend
terraform fmt       → auto-format your .tf files (tidy, consistent)
terraform validate  → check syntax & internal consistency (no AWS calls)
terraform plan      → show exactly what WILL change (a dry run) — read it!
terraform apply     → make the changes (asks you to type "yes")
terraform destroy   → delete everything this config manages
```

**The discipline that prevents disasters:** *always read the `plan` output before
`apply`.* It tells you precisely what will be **+ created**, **~ changed**, or
**- destroyed**. A change you didn't expect (especially a destroy) is your cue to
stop.

```
Plan: 3 to add, 0 to change, 0 to destroy.
```

> 🧠 `terraform apply` without arguments runs a fresh plan and asks for
> confirmation. In CI you'd `terraform plan -out=tfplan` then
> `terraform apply tfplan` to apply *exactly* the reviewed plan. We'll do the
> simple interactive form while learning.

---

## 6. Hands-on: your first Terraform run (zero cost)

We'll run the full workflow against AWS **without creating any billable
resource** — we only *read* your account identity and the region's AZs using data
sources. This builds muscle memory safely.

### 6.1 Create the scratch folder and file

Make a folder `terraform/learn-terraform/` and a file `main.tf` inside it with:

```hcl
# terraform/learn-terraform/main.tf

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

# DATA SOURCES — read-only lookups. These create nothing and cost nothing.
data "aws_caller_identity" "current" {}      # who am I?
data "aws_region" "current" {}               # which region?
data "aws_availability_zones" "available" {  # which AZs are usable here?
  state = "available"
}

# OUTPUTS — print useful info after apply.
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "current_region" {
  value = data.aws_region.current.name
}

output "availability_zones" {
  value = data.aws_availability_zones.available.names
}
```

### 6.2 Run the workflow

From inside `terraform/learn-terraform/`:

```bash
# Make sure your credentials are active (from Doc 04)
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

# 1) Initialize: downloads the AWS provider into ./.terraform/
terraform init

# 2) Format & validate (optional but good habit)
terraform fmt
terraform validate

# 3) Plan: since there are only data sources, it will say it will add 0 resources
terraform plan

# 4) Apply: type "yes" when prompted. It reads your account & prints outputs.
terraform apply
```

Expected tail of `apply`:

```
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.

Outputs:
account_id         = "123456789012"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
current_region     = "ap-south-1"
```

🎉 You just ran the entire Terraform workflow end-to-end. **0 resources created =
$0.** You also discovered the AZ names we'll use to spread subnets in Phase 1.

### 6.3 Look at what Terraform created locally

```bash
ls -la
```
You'll see:
- `.terraform/` — downloaded provider plugins (don't commit; it's in `.gitignore`).
- `.terraform.lock.hcl` — locks exact provider versions (**do** commit this).
- `terraform.tfstate` — local state. Here it's tiny and harmless, but this is the
  file we'll relocate to S3 in the next doc.

### 6.4 Clean up

```bash
terraform destroy   # type "yes"; since nothing billable exists, this is instant
```
Output: `Destroy complete! Resources: 0 destroyed.` (Data sources aren't
"destroyed" — there's simply nothing to remove. The command confirms a clean
slate.)

> 💡 Keep this `learn-terraform` folder around as a sandbox. Whenever you want to
> test a snippet or a data source without risk, do it here.

---

## 7. File layout conventions (we'll follow these)

By convention a Terraform "module" (a folder of `.tf` files) splits code by
purpose. Terraform reads *all* `.tf` files in a folder together, so the split is
purely for humans:

```
main.tf         # the resources/data sources
variables.tf    # variable declarations (inputs)
outputs.tf      # output declarations (results)
providers.tf    # terraform{} + provider{} config
terraform.tfvars# values for variables (NOT committed if it has secrets)
```

We'll use this structure starting in Phase 1.

---

## 8. Common beginner gotchas

- **"Error: No valid credential sources found"** → `AWS_PROFILE` not set, or keys
  not configured. Re-check Doc 04.
- **Editing the wrong file / nothing changes** → remember Terraform reads *every*
  `.tf` in the folder; make sure you're in the right directory.
- **Hardcoding secrets in `.tf`** → never. Use variables + Secrets Manager.
- **Committing `terraform.tfstate`** → never (secrets + merge conflicts). Use the
  remote backend (next doc).
- **Running `apply` without reading `plan`** → the #1 way people accidentally
  delete things. Always read the plan.

---

## ✅ Checkpoint

You're ready for the next doc when:

- [ ] You ran `init → plan → apply → destroy` in `learn-terraform/` successfully.
- [ ] Your outputs showed your account ID and the `ap-south-1` AZ names.
- [ ] You can explain: what state is, why we don't commit it, and what `plan`
      does.
- [ ] You can name the difference between a `resource` and a `data` source.

Next: **[06 — Remote State Backend](06-remote-state-backend.md)** — we create a
real (but nearly free) S3 + DynamoDB backend so your state is safe, encrypted,
and lockable. This is your first time creating real AWS resources with Terraform.
