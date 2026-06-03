# 07 — Networking: the VPC, Subnets, IGW & Routing

> **Goal of this doc:** build the **network fabric** of CloudCare with Terraform —
> a custom VPC, six subnets (public/app/db across two AZs), an Internet Gateway,
> and the route tables that decide what is "public" and what is "private". This is
> the foundation every later phase plugs into, and the **single most
> interview-important** chunk of the whole project.

⏱️ Time: ~60–90 minutes (go slow — understanding beats speed here).
💰 Cost: **$0.** Everything in this doc (VPC, subnets, IGW, route tables) is free.
We deliberately avoid the one networking thing that costs money — the NAT Gateway.

This is the start of **Phase 1**. We follow the usual rhythm: **concept →
design → code → apply & verify → (optionally) destroy.**

---

## 1. Where we are and what we're adding

In Phase 0 you created a secured account and an S3 + DynamoDB **state backend**
(Doc 06). Nothing else is running. Now we lay down the network.

Recall the target from [Doc 01](01-architecture-overview.md): a VPC split into
three tiers, each spread across two Availability Zones for resilience.

```
                ┌──────────── VPC  10.0.0.0/16 (ap-south-1) ────────────┐
                │                                                        │
   Internet ───►│  Internet Gateway                                      │
                │        │                                               │
                │        ▼                                               │
                │  ┌──── Public subnets ────┐   10.0.0.0/24  (AZ-a)      │
                │  │  (ALB lives here)       │   10.0.1.0/24  (AZ-b)      │
                │  └─────────────────────────┘                           │
                │  ┌──── Private app subnets ┐   10.0.10.0/24 (AZ-a)      │
                │  │  (EC2 / FastAPI)         │   10.0.11.0/24 (AZ-b)      │
                │  └─────────────────────────┘                           │
                │  ┌──── Private db subnets ─┐   10.0.20.0/24 (AZ-a)      │
                │  │  (RDS PostgreSQL)        │   10.0.21.0/24 (AZ-b)      │
                │  └─────────────────────────┘                           │
                └────────────────────────────────────────────────────────┘
```

This doc builds **everything except the firewalls** (security groups + NACLs) —
those come in [Doc 08](08-networking-security-groups-and-nacls.md), in the *same*
Terraform folder.

> 🧠 **Why two AZs from day one?** A subnet lives in exactly one AZ. If we put
> everything in `ap-south-1a` and that data center has an outage, CloudCare is
> down. Pairs of subnets (one per AZ) let the ALB, Auto Scaling Group, and RDS
> each survive losing an AZ. Interviewers will ask "how is this highly
> available?" — the honest answer starts here, at the subnet layout.

---

## 2. The Terraform folder & our first use of the remote backend

Every component gets its own folder and its own **state key** in the S3 bucket
(Doc 06 called this *state isolation*). Create a new folder:

```
terraform/
├── bootstrap/      ← Phase 0: the S3 bucket + DynamoDB lock table (leave it)
└── network/        ← Phase 1: THIS doc (and Doc 08) — the VPC and friends
```

We will create these files inside `terraform/network/`:

```
providers.tf    # terraform{} + backend{} + provider{}
variables.tf    # inputs: region, CIDRs, project name
vpc.tf          # the VPC, the Internet Gateway, the AZ lookup
subnets.tf      # the six subnets
routing.tf      # route tables + subnet associations
outputs.tf      # IDs other phases will consume
```

> 🧠 **Why split into several files?** Terraform reads *all* `.tf` files in a
> folder as one config — the split is purely for humans. Grouping by purpose
> (`vpc`, `subnets`, `routing`) keeps each file short and reviewable. We promised
> this convention back in Doc 05 §7; here's where we start using it.

---

## 3. `providers.tf` — wiring up the S3 backend (the new part)

This is the **first time** a Terraform folder stores its state in S3 instead of
on your laptop. The `backend "s3"` block is the only real difference from the
bootstrap's providers file.

```hcl
# terraform/network/providers.tf

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Store THIS folder's state in the S3 bucket we created in Doc 06.
  # `key` is the path inside the bucket — unique per component (state isolation).
  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "network/terraform.tfstate"
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
      Component = "network"
    }
  }
}
```

> 🧠 **Read the `backend` block carefully:**
> - `bucket` — the exact bucket from Doc 06 (`cloudcare-tfstate-670794226080`).
> - `key` — `network/terraform.tfstate`. The *compute* phase will use
>   `compute/...`, the *database* phase `database/...`. Separate keys mean a
>   mistake in one phase can't corrupt another's state.
> - `dynamodb_table` — the `cloudcare-tf-locks` table. Now **two applies can't
>   race**: whoever starts first takes the lock; the second waits.
> - `encrypt = true` — the state object is encrypted at rest in S3.
>
> 💡 Backend settings **cannot use variables** (they're read before variables
> exist). That's why the bucket name is hardcoded here. If your account ID
> differs, edit it to match `terraform output state_bucket` from the bootstrap
> folder.

---

## 4. `variables.tf` — the CIDR plan as inputs

These defaults encode the exact IP plan from [Doc 02 §3.2](02-core-concepts.md).
Putting them in variables (not hardcoded) is what lets you reuse this module for a
second environment later by passing different CIDRs.

```hcl
# terraform/network/variables.tf

variable "aws_region" {
  description = "AWS region for all networking resources"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix in resource Name tags"
  type        = string
  default     = "cloudcare"
}

variable "vpc_cidr" {
  description = "CIDR block for the whole VPC (65,536 addresses)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the public subnets — one per AZ (ALB tier)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "app_subnet_cidrs" {
  description = "CIDRs for the private application subnets — one per AZ (EC2 tier)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDRs for the private database subnets — one per AZ (RDS tier)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}
```

> 🧠 **Why a `list(string)` per tier?** Each list has one CIDR per AZ. We'll loop
> over the list with `count` so adding a third AZ later is just adding a third
> CIDR — no new resource blocks. This is the "design for change" habit that
> separates juniors from seniors.

---

## 5. `vpc.tf` — the VPC, the AZ lookup, and the Internet Gateway

```hcl
# terraform/network/vpc.tf

# Ask AWS which AZs are usable in this region, then take the first TWO.
# Using a data source (not hardcoding "ap-south-1a/b") makes the code portable.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# The VPC itself — our private, isolated network. Everything hangs off this.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # let resources resolve DNS names inside the VPC
  enable_dns_hostnames = true # give instances internal DNS hostnames (needed by RDS later)

  tags = {
    Name = "${var.project}-vpc"
  }
}

# The Internet Gateway — the VPC's single door to the public internet.
# Creating it does nothing on its own; a subnet only becomes "public" once a
# route table points 0.0.0.0/0 at this IGW (see routing.tf).
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-igw"
  }
}
```

> 🧠 **`slice(..., 0, 2)`** takes elements 0 and 1 — the first two AZ names AWS
> reports (e.g. `ap-south-1a`, `ap-south-1b`). `local.azs` is now a 2-element list
> we reuse everywhere, so every tier lands in the *same* two AZs consistently.

> 🧠 **Why turn on `enable_dns_hostnames`?** RDS (Phase 3) needs it to hand out a
> resolvable endpoint hostname. Cheap to enable now, annoying to discover missing
> later.

---

## 6. `subnets.tf` — six subnets via `count`

Instead of writing six near-identical blocks, we write **three** (one per tier)
and use `count` to make two of each — one per AZ.

```hcl
# terraform/network/subnets.tf

# PUBLIC subnets (one per AZ) — hold internet-facing things (the ALB).
# map_public_ip_on_launch = true → anything launched here gets a public IP.
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

# PRIVATE application subnets (one per AZ) — the EC2/FastAPI tier. No public IPs.
resource "aws_subnet" "app" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = var.app_subnet_cidrs[count.index]

  tags = {
    Name = "${var.project}-app-${local.azs[count.index]}"
    Tier = "app"
  }
}

# PRIVATE database subnets (one per AZ) — RDS lives here. The most isolated tier.
resource "aws_subnet" "db" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = var.db_subnet_cidrs[count.index]

  tags = {
    Name = "${var.project}-db-${local.azs[count.index]}"
    Tier = "db"
  }
}
```

> 🧠 **`count` and `count.index`.** `count = length(local.azs)` (= 2) makes
> Terraform create the block twice. `count.index` is the loop counter (0, then 1),
> so `local.azs[0]` pairs with `public_subnet_cidrs[0]`, and so on. The resources
> become an *indexed list*: `aws_subnet.public[0]`, `aws_subnet.public[1]`.

> 🧠 **The only thing that makes these "private":** the *app* and *db* subnets are
> identical to *public* except (a) no `map_public_ip_on_launch`, and (b) their
> route table has no internet route. Privacy is a **routing** property, not a
> checkbox — exactly the point Doc 02 hammered.

---

## 7. `routing.tf` — the route tables that define public vs private

This file is where "public" and "private" actually *happen*.

```hcl
# terraform/network/routing.tf

# PUBLIC route table: send all non-local traffic to the Internet Gateway.
# This single 0.0.0.0/0 route is what MAKES the public subnets public.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project}-public-rt"
  }
}

# Tie BOTH public subnets to the public route table.
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# PRIVATE route table: NO 0.0.0.0/0 route. AWS auto-adds an implicit "local"
# route for 10.0.0.0/16, so these subnets can talk WITHIN the VPC but cannot
# reach — or be reached from — the internet. That is the whole point.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-private-rt"
  }
}

# Tie all FOUR private subnets (app + db) to the private route table.
resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  count          = length(aws_subnet.db)
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.private.id
}
```

> 🧠 **Why one shared private route table for both app and db?** Because neither
> has an internet route — their routing is identical (local-only). If we later add
> a NAT for the app tier (to let it pull OS updates), we'd split this into
> `private-app-rt` (with a NAT route) and `private-db-rt` (still local-only). For
> now, one table is simpler and free.

> 💰 **The NAT Gateway we're NOT creating.** A real production private subnet
> usually has `0.0.0.0/0 → NAT Gateway` so instances can reach the internet
> *outbound* (e.g. `yum update`) without being reachable inbound. A NAT Gateway is
> **~$32/month + data** — the #1 surprise AWS bill. We omit it. When the app needs
> packages later, we'll bake them into the AMI or use a VPC endpoint / short-lived
> NAT instance, then tear it down. **Say this in an interview and you sound
> cost-aware.**

---

## 8. `outputs.tf` — hand IDs to the next phases

Later phases (compute, database) don't redeclare the VPC — they **read** these
outputs from this folder's remote state. So we export the IDs they'll need.

```hcl
# terraform/network/outputs.tf

output "vpc_id" {
  description = "ID of the CloudCare VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (ALB tier)"
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "IDs of the private application subnets (EC2 tier)"
  value       = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  description = "IDs of the private database subnets (RDS tier)"
  value       = aws_subnet.db[*].id
}
```

> 🧠 **`aws_subnet.public[*].id`** is a *splat expression*: "the `.id` of every
> instance in the indexed list." It returns `["subnet-aaa", "subnet-bbb"]`.

> 💡 **Preview of how Phase 2 reads these:** the compute folder will add a
> `terraform_remote_state` data source pointing at `key = "network/..."` and then
> use `data.terraform_remote_state.network.outputs.app_subnet_ids`. That's why
> good outputs here pay off later. (We'll write that wiring when we get there.)

---

## 9. Apply & verify

From inside `terraform/network/`:

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

# 1) Init — this time it configures the S3 BACKEND (downloads provider too).
terraform init
```

On `init` you should see Terraform say it's using the **s3** backend. If it asks
to copy existing state, there isn't any here, so just proceed.

```bash
# 2) Tidy + sanity check
terraform fmt
terraform validate

# 3) Dry run — READ THIS before applying.
terraform plan.
```

You should see **`Plan: 16 to add, 0 to change, 0 to destroy.`** That's:

| Resource | Count |
|----------|------:|
| VPC | 1 |
| Internet Gateway | 1 |
| Subnets (public 2 + app 2 + db 2) | 6 |
| Route tables (public + private) | 2 |
| Route table associations (2+2+2) | 6 |
| **Total** | **16** |

```bash
# 4) Make it real (type "yes").
terraform apply
```

### Verify with outputs and the CLI

```bash
# The IDs we exported:
terraform output

# The VPC exists with the right CIDR:
aws ec2 describe-vpcs \
  --filters Name=tag:Project,Values=cloudcare \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' --output table

# All six subnets, with their AZ and CIDR:
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,AZ:AvailabilityZone,CIDR:CidrBlock}' \
  --output table
```

You should see two subnets each for public/app/db, split across `ap-south-1a`
and `ap-south-1b`.

> ✅ **The key thing to confirm:** the **public** subnets' route table has a
> `0.0.0.0/0 → igw-...` route, and the **private** one does **not**. In the
> Console: **VPC → Route tables →** select each → **Routes** tab. This is the
> single most important thing to be able to point at and explain.

---

## 10. 💰 Cost & whether to destroy

Everything here is **free**: VPCs, subnets, route tables, IGWs, and (next doc)
security groups and NACLs carry no charge. The only networking resources that
cost money are NAT Gateways and unattached Elastic IPs — we created neither.

**So: leave the network stack running.** Phases 2 and 3 build directly on top of
it, and re-creating it each session adds nothing but friction. This is the same
exception we made for the state backend in Doc 06: *we only leave running the
things that are both free and foundational.*

> 💡 If you *want* to practice teardown, you can run `terraform destroy` in this
> folder — it's safe and free to recreate with `terraform apply`. But you'll just
> have to re-apply before Phase 2. Most people leave it up.

> ⚠️ Do **not** destroy the `bootstrap/` folder — it holds this folder's state.

---

## ✅ Checkpoint

You're ready for the next doc when:

- [ ] `terraform/network/` applied cleanly (`Apply complete! Resources: 16 added`).
- [ ] `terraform output` prints the VPC ID and three lists of subnet IDs.
- [ ] You confirmed (Console or CLI) that **public** subnets route to the IGW and
      **private** subnets do not.
- [ ] You can explain, from memory: *what makes a subnet public*, *why we use two
      AZs*, and *why we skipped the NAT Gateway*.

Next: **[08 — Networking: Security Groups & NACLs](08-networking-security-groups-and-nacls.md)**
— we add the two firewall layers (the stateful security-group chain
`ALB → App → DB`, plus stateless NACL backstops) to this same folder, completing
Phase 1.
