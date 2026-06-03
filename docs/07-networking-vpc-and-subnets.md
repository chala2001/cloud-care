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

## 0. Beginner read-me first — vocabulary in one place

Before the diagrams, here are every weird word that's about to appear, in plain
English. Re-read this whenever a term feels fuzzy.

| Word | What it means in one sentence |
|---|---|
| **VPC** (Virtual Private Cloud) | Your own private *network* inside AWS — like an isolated office building with its own internal address book that nothing outside can see by default. |
| **CIDR block** | A range of IP addresses written like `10.0.0.0/16`. The `/16` part says how big the range is (more on this in §1). |
| **Subnet** | A slice of the VPC. Every subnet lives in **exactly one** Availability Zone. Think "one floor of the building." |
| **AZ** (Availability Zone) | A physically separate data center inside one AWS region (e.g. `ap-south-1a` and `ap-south-1b` are two different buildings near Mumbai). |
| **Public subnet** | A subnet whose **route table** sends internet-bound traffic through the **Internet Gateway**. Instances *can* reach (and be reachable from) the internet. |
| **Private subnet** | A subnet whose route table has **no** internet route. Instances inside can talk to each other but the public internet can't see them at all. |
| **Internet Gateway (IGW)** | The single legal "door" between a VPC and the public internet. Just creating it does nothing — a route table has to point at it. |
| **Route table** | A list of rules a packet checks before leaving a subnet: *"if you're going to address X, go via Y."* This is the **navigation system** — it does NOT decide allow/deny, only direction. |
| **Tag** | A label like `Name=cloudcare-vpc` you attach to any AWS resource. Free, optional, and what you'll search by later. |
| **Terraform `resource`** | "Create and manage this real AWS thing." |
| **Terraform `data` source** | "Look up an existing AWS thing — don't create it." |
| **Terraform `local`** | A reusable named expression inside one folder ("local constant"). |
| **`count` / `count.index`** | Terraform's simplest way to ask for **N copies** of a resource. `count.index` is the loop counter (0, 1, 2, …). |
| **Splat expression `[*]`** | "Give me an attribute from *every* instance in a counted list." Yields a list. |

Keep this card handy. Now the diagram.

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

### Understanding `10.0.0.0/16` (the CIDR notation) — quick refresher

CIDR is just *"a range of IP addresses, written compactly."*

```
   10.0.0.0  /16
       ▲      ▲
       │      └─ how many of the leading bits are FIXED.
       │           /16 = first 16 bits fixed → first 2 octets (10.0) locked
       │           → addresses 10.0.0.0  through  10.0.255.255  (= 65,536 IPs)
       └─ the starting IP

   10.0.0.0/24 = "first 24 bits fixed" → 10.0.0.0 through 10.0.0.255 (= 256 IPs)
```

**Smaller number = bigger range.** `/16` is huge; `/24` is one small slice of it.

Our VPC is **one big `/16`** (the whole office), then we carve out **six `/24`**
slices (one floor each). Each `/24` slice holds 256 addresses — plenty for a
learning lab (AWS reserves 5 of those, so you actually get 251 usable).

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

### Why split into multiple `.tf` files?

Terraform **reads every `.tf` file in a folder as one merged document** before
doing anything. The filenames are purely human convenience — Terraform doesn't
care which line lives in which file. We split them by *topic* so:

- you can open just `routing.tf` to think about routing,
- code reviews are smaller,
- `git diff` is easier to follow,
- finding things in 4 small files is faster than scrolling one giant `main.tf`.

You can mix conventions per folder. The **always-keep-separate** files are
`providers.tf`, `variables.tf`, and `outputs.tf` (the "plumbing"). Topic files
like `vpc.tf` / `subnets.tf` / `routing.tf` are optional but standard.

### Why one folder = one component (state isolation)

Each folder is its own Terraform **root module** with its own:
- `providers.tf` (its own AWS connection)
- `terraform.tfstate` (its own memory of what it created)
- `terraform plan/apply` lifecycle

A `terraform apply` in `network/` will *never* touch resources in `bootstrap/`,
and a mistake in `network/` can't corrupt `bootstrap/`'s state. The folders
communicate **only** through declared `output` blocks read via
`data "terraform_remote_state"` — we'll see that pattern from Phase 2 onwards.

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

### Walk-through — line by line

#### The `terraform { }` block — global settings

| Line | What it does (plain English) |
|---|---|
| `terraform { ... }` | A special meta-block. Anything inside configures **Terraform itself**, not AWS. |
| `required_version = ">= 1.5"` | Refuse to run if the user's Terraform CLI is older than 1.5. Prevents surprises when a teammate has an old CLI. |
| `required_providers { ... }` | Declare which plugins this folder needs. Terraform downloads them during `init`. |
| `aws = { source = "hashicorp/aws", version = "~> 5.0" }` | "Use the AWS provider published by HashiCorp at registry.terraform.io, any version `5.x` (the `~>` operator means *allow up to but not including the next major*)." |

#### The `backend "s3" { }` block — where state is stored

This is **the** block to memorize. Every later folder will have one almost
identical to it (just a different `key`).

| Field | Plain English |
|---|---|
| `backend "s3"` | "Use the S3 backend type." Terraform supports many backends (s3, gcs, azurerm, http, …). |
| `bucket = "cloudcare-tfstate-670794226080"` | Exact name of the bucket from Doc 06. **Hard-coded** because backend settings can't use variables. |
| `key = "network/terraform.tfstate"` | The **path inside** the bucket. The `network/` prefix is what isolates this folder's state from `compute/`, `database/`, etc. |
| `region = "ap-south-1"` | Where the bucket lives. |
| `dynamodb_table = "cloudcare-tf-locks"` | The table from Doc 06 used as a **distributed lock** — only one apply at a time. |
| `encrypt = true` | Encrypt the state object at rest using S3's server-side encryption. |

> 💡 **Why can't `backend` use variables?** Terraform reads the `backend` block
> **before** it parses variables, because it needs to fetch the state file *first*
> in order to know what variables are. So everything inside is plain literals.

> ⚠️ **If your account ID is different from `670794226080`,** edit the `bucket` to
> match what `terraform output state_bucket` printed at the end of Doc 06.

#### The `provider "aws" { }` block — how to talk to AWS

| Line | Meaning |
|---|---|
| `provider "aws" { ... }` | Configure the AWS plugin from `required_providers`. |
| `region = var.aws_region` | Read the region from `variables.tf` (default `ap-south-1`). All resources in this folder go to this region. |
| `default_tags { tags = { ... } }` | Apply these tags **to every resource the AWS provider creates**. So every subnet, route table, etc. gets `Project=cloudcare`, `ManagedBy=terraform`, `Component=network` automatically — no need to repeat in each resource block. |

> 🧠 **Why these specific tags?** `Project` is for cost attribution in Cost
> Explorer. `ManagedBy` lets you immediately spot resources Terraform owns vs.
> hand-created ones (so you don't accidentally `terraform destroy` something
> important). `Component` distinguishes folders within the same project so you
> can filter "show me everything `Component=network`."

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

### What every line of a `variable` block does

A variable block has three settings you'll see everywhere:

| Field | Required? | Meaning |
|---|---|---|
| `description` | optional but always include | Shown in CLI prompts and docs. Future-you will thank you. |
| `type` | optional but always include | `string`, `number`, `bool`, `list(string)`, `map(string)`, `object({...})`. Terraform validates that the value matches. |
| `default` | optional | If omitted, Terraform **prompts** for it at `apply`. If given, you can override via `-var=name=value`, `*.tfvars` file, or env var `TF_VAR_name`. |

#### Each of our six variables, in context

- **`aws_region`** — Lets you redeploy to a different region by overriding it
  (`-var='aws_region=eu-west-1'`) without editing code. Default `ap-south-1`
  (Mumbai) for cost/latency reasons covered in Doc 03.
- **`project`** — Used as the prefix for every `Name` tag in this folder. Set to
  `cloudcare`. If you fork this for another project, change one variable instead
  of 50 strings.
- **`vpc_cidr`** — `10.0.0.0/16`. The whole VPC. 65,536 possible IPs (we'll
  actually use ~1,500 of them).
- **`public_subnet_cidrs` / `app_subnet_cidrs` / `db_subnet_cidrs`** — A list of
  `/24` blocks per tier, **one entry per AZ**. The 10/11/20/21 split is just to
  make tiers visually distinct (10s = app, 20s = db, 0s = public).

> 🧠 **Why a `list(string)` per tier?** Each list has one CIDR per AZ. We'll loop
> over the list with `count` so adding a third AZ later is just adding a third
> CIDR — no new resource blocks. This is the "design for change" habit that
> separates juniors from seniors.

> 💡 **Reading the CIDRs.** Public is `10.0.0.0/24` (256 IPs from `10.0.0.0` to
> `10.0.0.255`) and `10.0.1.0/24` (`10.0.1.0`–`10.0.1.255`). They don't overlap
> with app (`10.0.10.x`, `10.0.11.x`) or db (`10.0.20.x`, `10.0.21.x`). AWS
> requires non-overlapping subnet CIDRs within one VPC.

---

## 5. `vpc.tf` — the VPC, the AZ lookup, and the Internet Gateway

This file does three things: looks up which AZs are usable, creates the VPC,
creates the IGW.

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

### Walk-through — every block explained

#### Block 1 — `data "aws_availability_zones"` (lookup, not create)

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}
```

**`data` blocks query AWS for existing information.** They never create or
modify anything. At `plan`/`apply` time, Terraform calls AWS's
`DescribeAvailabilityZones` API and stores the result.

| Line | Meaning |
|---|---|
| `data "aws_availability_zones"` | Resource *type* from the AWS provider |
| `"available"` | Your nickname for this lookup, used as `data.aws_availability_zones.available.…` |
| `state = "available"` | Filter: only return AZs marked "available" (skip unhealthy ones) |

The result has many attributes; the one we care about is `.names`, a list like
`["ap-south-1a", "ap-south-1b", "ap-south-1c"]`.

> 🧠 **Why look up instead of hardcoding?** Different regions have different AZ
> names and counts. By looking them up, this exact `.tf` file works in Mumbai
> (3 AZs), Tokyo (4 AZs), or Frankfurt (3 AZs) without edits.

#### Block 2 — `locals { azs = slice(...) }` (named expression)

```hcl
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
```

**`locals` define reusable named values.** Different from `variable` (no
external input) and from `resource` (no real AWS thing). They're just shorthand
to avoid repeating expressions.

`slice(LIST, START, END)` is a built-in Terraform function. `slice(names, 0, 2)`
returns elements at indices 0 and 1 (the `END` index is exclusive). So:

```
names      = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
local.azs  = ["ap-south-1a", "ap-south-1b"]   ← first two only
```

We use this 2-element list to place exactly one subnet of each tier in each AZ.

#### Block 3 — `resource "aws_vpc" "main"`

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project}-vpc" }
}
```

This **creates** the VPC.

| Line | Meaning |
|---|---|
| `resource "aws_vpc" "main"` | Make a new VPC; nickname it `main` |
| `cidr_block = var.vpc_cidr` | Use the IP range from the variable (`10.0.0.0/16`) |
| `enable_dns_support = true` | Let resources inside resolve DNS (look up names → IPs). Required for AWS service endpoints to work. |
| `enable_dns_hostnames = true` | Auto-assign hostnames like `ip-10-0-1-23.ap-south-1.compute.internal` to instances. RDS *requires* this to give its endpoint a real DNS name. |
| `tags = { Name = "${var.project}-vpc" }` | The console shows the `Name` tag as the VPC's title. `${var.project}` is interpolation — Terraform substitutes the variable value (`cloudcare-vpc`). |

> 🧠 **Why turn on `enable_dns_hostnames`?** RDS (Phase 3) needs it to hand out a
> resolvable endpoint hostname. Cheap to enable now, annoying to discover missing
> later.

#### Block 4 — `resource "aws_internet_gateway" "main"`

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project}-igw" }
}
```

Creates an Internet Gateway and **attaches** it to your VPC.

| Line | Meaning |
|---|---|
| `resource "aws_internet_gateway" "main"` | Make a new IGW |
| `vpc_id = aws_vpc.main.id` | Attach it to the VPC we just made. **This reference creates the dependency** — Terraform now knows the VPC must exist before the IGW. |

> 🧠 **The IGW is just an "attach point" on the VPC.** Creating the IGW does
> NOT route any traffic. A subnet only becomes internet-reachable once a route
> table sends `0.0.0.0/0` at it (which we do in `routing.tf` next).

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

### Understanding `count` (the most-used Terraform looping pattern)

A `count` line transforms **one block** into **N blocks** at apply time.

```hcl
resource "aws_subnet" "public" {
  count = length(local.azs)        # = length(["ap-south-1a","ap-south-1b"]) = 2
  ...
}
```

That tells Terraform to make **two** copies of this resource. Inside the block,
`count.index` is the loop counter (0, then 1). So:

```
First copy   →  count.index = 0  →  AZ = local.azs[0] = "ap-south-1a"
                                  →  CIDR = var.public_subnet_cidrs[0] = "10.0.0.0/24"
Second copy  →  count.index = 1  →  AZ = local.azs[1] = "ap-south-1b"
                                  →  CIDR = var.public_subnet_cidrs[1] = "10.0.1.0/24"
```

After apply, you can reference each one as:
- `aws_subnet.public[0]` — the AZ-a subnet
- `aws_subnet.public[1]` — the AZ-b subnet
- `aws_subnet.public[*].id` — *list of both IDs* (splat expression)

### Walk-through — every argument in a subnet block

| Line | Meaning |
|---|---|
| `count = length(local.azs)` | Loop count = number of AZs we picked (2). Adding a 3rd AZ in `vpc.tf`'s `slice(...,0,3)` would make this **automatically** create 3 subnets per tier. |
| `vpc_id = aws_vpc.main.id` | Which VPC this subnet lives in. |
| `availability_zone = local.azs[count.index]` | Which AZ. `count.index=0` → `ap-south-1a`. |
| `cidr_block = var.public_subnet_cidrs[count.index]` | The subnet's IP range. Picks element `[0]` or `[1]` of the list from `variables.tf`. |
| `map_public_ip_on_launch = true` | **Public-only.** Any instance launched here auto-gets a public IP. App/db subnets omit this. |
| `tags = { Name = ..., Tier = ... }` | `Name` becomes the console title; `Tier` is our own label for filtering ("show me all `Tier=db` subnets"). |

### Two interpolations in the `Name` tag

```hcl
Name = "${var.project}-public-${local.azs[count.index]}"
```

The `${...}` syntax injects a value into a string. After interpolation:
- copy 0: `cloudcare-public-ap-south-1a`
- copy 1: `cloudcare-public-ap-south-1b`

This naming is what lets you scan the AWS Console and instantly know which AZ a
subnet is in.

> 🧠 **The only thing that makes these "private":** the *app* and *db* subnets are
> identical to *public* except (a) no `map_public_ip_on_launch`, and (b) their
> route table has no internet route (next section). Privacy is a **routing**
> property, not a checkbox — exactly the point Doc 02 hammered.

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

### Mental model: a route table is a navigation card

Every subnet is associated with **one** route table. When a packet wants to
leave a subnet, the route table is checked. Each row says *"if the destination
is `X`, send it via `Y`."* The packet uses the **most specific match**.

A VPC ALWAYS has an implicit row: *"if dest is inside the VPC (e.g.
`10.0.0.0/16`), keep it local."* You never write this — AWS adds it for free.

The only row YOU add for a public subnet is:
```
0.0.0.0/0  →  via the Internet Gateway
```
`0.0.0.0/0` means "everywhere I don't have a more-specific match" — i.e. the
internet. That single row is **what makes a subnet public**.

### Walk-through — every block explained

#### Block 1 — Public route table + its internet rule

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}
```

| Line | Meaning |
|---|---|
| `resource "aws_route_table" "public"` | Create a route table; nickname `public` |
| `vpc_id = aws_vpc.main.id` | Belongs to our VPC |
| `route { ... }` | **Inline route rule** (you can have many of these). |
| `cidr_block = "0.0.0.0/0"` | Match all destinations not already covered by a more-specific route |
| `gateway_id = aws_internet_gateway.main.id` | Send those packets through the IGW |

This single `route` block is the *only* reason public subnets are public.

#### Block 2 — Associating subnets with the public route table

```hcl
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

| Line | Meaning |
|---|---|
| `aws_route_table_association` | The "link" resource between one subnet and one route table |
| `count = length(aws_subnet.public)` | Loop over both public subnets (2) |
| `subnet_id = aws_subnet.public[count.index].id` | Pick subnet[0] then subnet[1] |
| `route_table_id = aws_route_table.public.id` | Always the public RT |

So we create **2** associations: public-a → public-rt, public-b → public-rt.

> 💡 **AWS provides a "main route table" per VPC automatically.** Any subnet not
> explicitly associated falls back to the main RT. We don't want surprises, so we
> explicitly associate every subnet with a route table of our choice.

#### Block 3 — Private route table (deliberately empty of internet routes)

```hcl
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.project}-private-rt" }
}
```

Notice the difference from public: **no `route { ... }` block.** The implicit
local rule (`10.0.0.0/16 → local`) is still there because AWS adds it — but
there's no `0.0.0.0/0` route. So packets bound for the internet have **nowhere
to go** and get dropped.

That single missing line is the entire reason these subnets are private.

#### Blocks 4 & 5 — Associating the 4 private subnets

```hcl
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

Same pattern, repeated for app (2) and db (2). All 4 → the single private RT.

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

### What an `output` block is, and what `[*]` means

An `output` block declares a **published value** that:
1. Prints after `terraform apply`.
2. Is queryable with `terraform output <name>` or `terraform output -raw <name>`.
3. Is **readable by other folders** via `data "terraform_remote_state"`.

Output #3 is the whole point in this project — `compute/`, `database/`, etc.
will all reach into this folder's state to grab subnet IDs.

The **splat expression `[*]`** turns a list of resources into a list of one of
their attributes:

```hcl
aws_subnet.public[*].id
        ↑       ↑   ↑
        │       │   └─ for each, take .id
        │       └─ splat: "for every element in the list"
        └─ the counted resource is treated as a list because of `count`

→ ["subnet-0abc...", "subnet-0def..."]
```

Without `[*]`, you'd have to write `[aws_subnet.public[0].id,
aws_subnet.public[1].id]` — verbose and breaks if you add a 3rd AZ.

> 💡 **Preview of how Phase 2 reads these:** the compute folder will add a
> `terraform_remote_state` data source pointing at `key = "network/..."` and then
> use `data.terraform_remote_state.network.outputs.app_subnet_ids`. That's why
> good outputs here pay off later. (We'll write that wiring when we get there.)

---

## 9. Apply & verify

Now we make all this real. Run commands from inside `terraform/network/`.

### Step 1 — Set your AWS credentials

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1
```

**What each line does:**

- `export VAR=value` is a **shell builtin** that sets an environment variable
  *visible to every program* the shell launches next (including `terraform` and
  `aws`).
- `AWS_PROFILE=cloudcare` tells the AWS SDK (used by both `terraform` and
  `aws`) to read credentials from the `[cloudcare]` section of
  `~/.aws/credentials`. We set up that profile back in Doc 04.
- `AWS_REGION=ap-south-1` is a fallback in case anything doesn't pick up the
  region from the provider block.

> 💡 These exports **only last for the current shell session.** If you open a
> new terminal you have to re-export them (or put them in `.bashrc`).

### Step 2 — `terraform init`

```bash
terraform init
```

**What this command does (every step):**

1. Reads `providers.tf`'s `required_providers` block.
2. **Downloads the AWS provider plugin** (v5.x) from `registry.terraform.io` into
   `.terraform/providers/`.
3. Reads the `backend "s3"` block.
4. **Connects to S3** (using your AWS credentials) to check if `network/
   terraform.tfstate` exists. (It won't, this is the first time.)
5. Creates `.terraform.lock.hcl` — a checksum file pinning exact provider
   versions for reproducible installs.
6. Creates `.terraform/` directory with everything cached.

You should see lines like:
```
Initializing the backend...
Successfully configured the backend "s3"!
Initializing provider plugins...
- Installing hashicorp/aws v5.x.x...
Terraform has been successfully initialized!
```

> ⚠️ **If `init` errors with `failed to get shared config profile`,** your shell
> has `AWS_PROFILE` set to something that doesn't exist. Either `unset
> AWS_PROFILE` (use `default`) or create the `cloudcare` profile with `aws
> configure --profile cloudcare`.

> 🧠 **`init` is safe and idempotent.** Run it any time you change providers or
> the backend block. It only adds the `-reconfigure` flag is needed if the
> backend itself changes.

### Step 3 — `terraform fmt` and `terraform validate` (sanity)

```bash
terraform fmt
```

`fmt` = auto-format all `.tf` files in this folder. Standardizes indentation
(2-space), alignment of `=`, and quote style. If anything got reformatted, the
file paths print. **Safe; just style.**

```bash
terraform validate

# 3) Dry run — READ THIS before applying.
terraform plan
```

**What plan does (and why you should always read it):**

1. Reads your current state from S3 (empty, this is first run).
2. Refreshes data sources (calls `DescribeAvailabilityZones` etc.).
3. Compares **desired state** (your code) vs **current state** (S3).
4. Prints **every** resource it will create/change/destroy, and exits without
   touching anything.

At the bottom you should see:

```
Plan: 16 to add, 0 to change, 0 to destroy.
```

That's:

| Resource | Count |
|----------|------:|
| VPC | 1 |
| Internet Gateway | 1 |
| Subnets (public 2 + app 2 + db 2) | 6 |
| Route tables (public + private) | 2 |
| Route table associations (2+2+2) | 6 |
| **Total** | **16** |

> 🧠 **`plan` does not lock the state.** Two people can `plan` at the same time
> safely. Only `apply` takes the DynamoDB lock.

### Step 5 — `terraform apply`

```bash
terraform apply
```

Same output as `plan`, but at the end it asks:

```
Do you want to perform these actions?
  Enter a value: yes
```

Typing `yes` (lowercase, exactly) commits. Anything else aborts. While running:

- Terraform acquires the **DynamoDB lock** so no one else can apply simultaneously.
- Resources are created in dependency order (computed from references — VPC
  before IGW, subnets before associations, etc.).
- Independent resources are created **in parallel** (up to 10 concurrent ops by
  default). The 6 subnets, for example, are made together.
- After each resource, the state file in S3 is updated.
- On success, the lock is released and outputs are printed.

You should see:
```
Apply complete! Resources: 16 added, 0 changed, 0 destroyed.

Outputs:

app_subnet_ids    = ["subnet-...", "subnet-..."]
db_subnet_ids     = ["subnet-...", "subnet-..."]
public_subnet_ids = ["subnet-...", "subnet-..."]
vpc_cidr          = "10.0.0.0/16"
vpc_id            = "vpc-..."
```

> 💡 **If apply errors midway**, what was already created stays. Re-running
> apply continues from where it left off (Terraform compares state vs. AWS).

### Step 6 — Verify with the AWS CLI

The outputs from `apply` are useful but let's also confirm directly with AWS:

```bash
# Show this folder's outputs again any time:
terraform output
```

This re-reads the state and prints the `output` blocks. Add `-raw <name>` to
get just one value without quotes (useful in scripts).

```bash
# Confirm the VPC exists in AWS, filtered by our project tag:
aws ec2 describe-vpcs \
  --filters Name=tag:Project,Values=cloudcare \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' --output table
```

**Decoded:**

- `aws ec2 describe-vpcs` — AWS CLI command to list VPCs.
- `--filters Name=tag:Project,Values=cloudcare` — filter by tag (only VPCs
  tagged `Project=cloudcare`).
- `--query '...'` — a **JMESPath expression**: from each item in the `Vpcs`
  array, pick `VpcId` (alias `ID`) and `CidrBlock` (alias `CIDR`).
- `--output table` — pretty-print as a table.

Expected output:
```
-----------------------------------------
|             DescribeVpcs              |
+-------------+-------------------------+
|    CIDR     |          ID             |
+-------------+-------------------------+
|  10.0.0.0/16|  vpc-0123abcdef         |
+-------------+-------------------------+
```

```bash
# List all six subnets in this VPC with their AZ and CIDR:
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,AZ:AvailabilityZone,CIDR:CidrBlock}' \
  --output table
```

**Decoded:**

- `--filters Name=vpc-id,Values=$(terraform output -raw vpc_id)` — filter by
  VPC ID; the `$( ... )` runs the inner command first and substitutes its output.
- `--query 'Subnets[].{...}'` — for each subnet, pick three fields:
  - `Name:Tags[?Key==\`Name\`]|[0].Value` — drill into the `Tags` array, pick
    the one with `Key==Name`, take its `Value`.
  - `AZ:AvailabilityZone`
  - `CIDR:CidrBlock`

Expected (6 rows total):
```
-----------------------------------------------------
|                  DescribeSubnets                  |
+--------------+---------------------+---------------+
|     AZ       |       CIDR          |     Name      |
+--------------+---------------------+---------------+
| ap-south-1a  | 10.0.0.0/24         | cloudcare-public-ap-south-1a |
| ap-south-1b  | 10.0.1.0/24         | cloudcare-public-ap-south-1b |
| ap-south-1a  | 10.0.10.0/24        | cloudcare-app-ap-south-1a    |
| ap-south-1b  | 10.0.11.0/24        | cloudcare-app-ap-south-1b    |
| ap-south-1a  | 10.0.20.0/24        | cloudcare-db-ap-south-1a     |
| ap-south-1b  | 10.0.21.0/24        | cloudcare-db-ap-south-1b     |
+--------------+---------------------+---------------+
```

### Step 7 — Visual verification (the high-value bit)

> ✅ **The single most important thing to confirm:** the **public** route
> table has a `0.0.0.0/0 → igw-...` route, and the **private** one does **not**.

In the AWS Console: **VPC → Route tables →** select `cloudcare-public-rt` →
look at the **Routes** tab. You should see two rows:

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `local` (the implicit row) |
| `0.0.0.0/0` | `igw-...` (your IGW) |

Then select `cloudcare-private-rt`. You should see **only one row**:

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `local` |

**That difference of one row is the entire definition of "public vs private."**
Be ready to walk this in an interview.

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

## 11. Plain-English summary (everything you just built)

If someone asks *"what does this network do?"*, you should be able to say,
without looking:

1. We made **one VPC** (`cloudcare-vpc`, range `10.0.0.0/16`) — our private
   network in AWS.
2. Inside it, **six subnets** — two per tier (public, app, db), one per AZ
   (`ap-south-1a` and `ap-south-1b`). Each subnet is a `/24` slice (256 IPs).
3. **One Internet Gateway** is attached to the VPC — the only legal door to the
   public internet.
4. **Two route tables**:
   - `cloudcare-public-rt`: has a `0.0.0.0/0 → IGW` rule → its associated subnets
     can reach (and be reached by) the internet.
   - `cloudcare-private-rt`: has no internet rule → its associated subnets stay
     internal.
5. **Associations** wire each subnet to its route table — that's the step that
   actually decides which subnet is public vs private.
6. **Five outputs** (`vpc_id`, `vpc_cidr`, three subnet-ID lists) are
   published to S3 state for downstream stacks (compute, database) to consume
   via `terraform_remote_state`.

---

## 12. Interview soundbites

You can reuse these almost verbatim:

- **Architecture overview** —
  *"One VPC, three tiers (public/app/db), one subnet per tier per AZ across two
  AZs — six subnets total. Public subnets host the ALB. App and DB tiers are
  private — no public IPs, no internet route. The whole layout is built for
  AZ-level fault tolerance from day one."*

- **What makes a subnet 'public' vs 'private'** —
  *"It's purely a routing decision. A subnet is public when its route table
  sends `0.0.0.0/0` traffic to an Internet Gateway. Without that route, the
  subnet is private — its instances can still talk inside the VPC, but the
  internet has no path to or from them."*

- **Why we skipped the NAT Gateway** —
  *"NAT Gateway is ~$32/month plus data charges — the #1 surprise AWS bill. For
  a learning lab we omit it. In production you'd use a NAT Gateway (or VPC
  endpoints for AWS services) so private instances can install updates without
  being publicly reachable."*

- **High availability** —
  *"Every tier has a subnet in each of two AZs. The ALB requires ≥2 subnets in
  ≥2 AZs by definition; the ASG spreads EC2s across both; the RDS subnet group
  covers both so Multi-AZ standby is a one-flag opt-in later."*

- **State isolation** —
  *"Each Terraform folder writes its state to a different S3 key — `network/`,
  `compute/`, `database/`. State is encrypted at rest, locked via DynamoDB,
  and downstream folders read upstream outputs through
  `terraform_remote_state`."*

---

## ✅ Checkpoint

You're ready for the next doc when:

- [ ] `terraform/network/` applied cleanly (`Apply complete! Resources: 16 added`).
- [ ] `terraform output` prints the VPC ID and three lists of subnet IDs.
- [ ] You confirmed (Console or CLI) that **public** subnets route to the IGW and
      **private** subnets do not.
- [ ] You can explain, from memory: *what makes a subnet public*, *why we use two
      AZs*, and *why we skipped the NAT Gateway*.
- [ ] You can read any line in `vpc.tf`, `subnets.tf`, or `routing.tf` and
      explain in plain English what it does.

Next: **[08 — Networking: Security Groups & NACLs](08-networking-security-groups-and-nacls.md)**
— we add the two firewall layers (the stateful security-group chain
`ALB → App → DB`, plus stateless NACL backstops) to this same folder, completing
Phase 1.
