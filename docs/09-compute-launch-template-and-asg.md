# 09 — Compute: Launch Template, IAM Role & Auto Scaling Group

> **Goal of this doc:** stand up the **application tier** — a self-healing
> **Auto Scaling Group** of `t2.micro` instances in your private app subnets, each
> booting from a **Launch Template** that runs a tiny placeholder web service on
> port 8000. We wire it to the Phase 1 network by *reading* that stack's outputs
> with `terraform_remote_state`. The load balancer comes in
> [Doc 10](10-compute-application-load-balancer.md).

⏱️ Time: ~75–90 minutes.
💰 Cost: ~$0 if you run **one** `t2.micro` and **destroy after the lab**. This is
the first phase with real free-tier risk — read §12 before you walk away.

This is the start of **Phase 2 — Compute.** Same rhythm: concept → design →
code → apply & verify → destroy.

---

## 0. Beginner read-me first — vocabulary in one place

This doc introduces **a lot** of new terms because compute touches IAM, the OS
boot process, and the cloud's "cattle, not pets" abstraction at once. Re-read
this card whenever something feels foreign.

| Word | Plain-English meaning |
|---|---|
| **EC2** | A virtual computer (server) running inside AWS. Like a rented PC in Amazon's data center. |
| **Instance** | One single running EC2 (one specific machine). |
| **AMI** (Amazon Machine Image) | An "install disk" — a complete OS image you boot the EC2 from. We use Amazon Linux 2023. |
| **Instance type** | The hardware size, e.g. `t2.micro` = 1 vCPU, 1 GB RAM. Free-tier eligible. |
| **Launch Template** | A **recipe** for what kind of EC2 to build (OS, size, security group, boot script). Creates **nothing** by itself. |
| **Auto Scaling Group (ASG)** | A **manager** that keeps N copies of EC2 alive based on a Launch Template. Self-healing. |
| **`min_size`/`max_size`/`desired_capacity`** | ASG's bounds: never fewer than `min`, never more than `max`, normally aim for `desired`. |
| **`vpc_zone_identifier`** | Which **subnets** the ASG places instances into (one or more). Distributes across AZs automatically. |
| **`launch_template { version }`** | Which version of the template to use. `"$Latest"` always uses the newest. |
| **Health check (EC2 vs ELB)** | How the ASG decides if an instance is healthy. `EC2` = AWS's basic ping. `ELB` (used in Doc 10) = the load balancer's HTTP check. |
| **Instance refresh** | Roll out a new version of the template by **replacing** instances one at a time. Zero-downtime deploys. |
| **IAM role** | A "badge" the EC2 wears. Grants AWS-side permissions without storing any keys on disk. |
| **Trust policy** | The rule "who is allowed to wear this role" — for an EC2 role, it lists `ec2.amazonaws.com`. |
| **Instance profile** | The wrapper AWS requires to actually attach a role to an EC2. EC2 ≠ Lambda; EC2 needs this extra step. |
| **SSM Session Manager** | Browser/CLI shell into the instance, without SSH or open ports. Uses the IAM role. |
| **IMDS** (Instance Metadata Service) | A tiny built-in HTTP service inside every EC2 at `http://169.254.169.254/` that returns its metadata (incl. IAM credentials). |
| **IMDSv2** | The hardened version of IMDS — requires a session token, blocks SSRF-based credential theft. We **enforce** it. |
| **cloud-init / user_data** | The boot-time script EC2 runs **as root, once**, on first boot. We use it to install the placeholder service. |
| **`base64encode(...)`** | A Terraform function that wraps a string in base64 — required because the AWS API accepts `user_data` only as base64. |
| **Heredoc `<<-EOF … EOF`** | A way to embed a multi-line string in Terraform. The `-` strips leading whitespace. |
| **systemd** | Linux's modern service manager. We use it to keep the placeholder server restarting on crashes / boots. |
| **`terraform_remote_state`** | A **data source** that reads another stack's outputs from S3. The "cable" between folders. |
| **Pet vs cattle** | "Pets" = hand-built servers you name and nurse. "Cattle" = interchangeable instances from a template, replaced on failure. Cloud = cattle. |

Now the diagram.

---

## 1. What we're building (and how it connects to Phase 1)

```
        (Doc 10 adds the ALB here, in the PUBLIC subnets)
                              │  :8000
   ┌──────────────── Private app subnets (AZ-a, AZ-b) ────────────────┐
   │                                                                   │
   │   Auto Scaling Group  (desired=1, min=1, max=2)                   │
   │     └── Launch Template ── EC2 t2.micro ── runs a health service  │
   │             • AMI: Amazon Linux 2023                              │
   │             • SG:  app-sg  (only :8000 from the ALB)              │
   │             • IAM instance profile (SSM-ready)                    │
   └───────────────────────────────────────────────────────────────────┘
```

Phase 1 gave us the network. **We do not recreate any of it.** Instead, this
folder *reads* the network's outputs (subnet IDs, security-group IDs) from its
remote state. That separation — one stack per concern, connected by outputs — is
exactly how real teams keep blast radius small.

> 🧠 **Launch Template + ASG = the "cattle, not pets" pattern.** You never create
> an instance by hand. You describe *one recipe* (the Launch Template) and tell
> the ASG "keep N healthy copies alive." If one dies, the ASG replaces it
> automatically. This is the single most important reliability idea in compute,
> and interviewers love hearing it phrased that way.

### The two "things" — recipe vs manager

| | **Launch Template** | **Auto Scaling Group** |
|---|---|---|
| What it is | a **blueprint** describing one instance | a **manager** that creates/maintains N instances from the blueprint |
| Creates EC2s itself? | ❌ no | ✅ yes, automatically |
| Stores | OS image, instance type, SG ids, IAM profile, user-data script, tags | min/max/desired count, which subnets, health-check rules, refresh policy |
| Analogy | a cookie cutter | the baker who keeps the tray full |

You'll write **both** in this doc. The ASG references the launch template — that's
the only place they're tied together.

---

## 2. A deliberate simplification: what runs on the instance

The **real** CloudCare FastAPI app (in Docker) arrives in **Phase 4**. Running it
now would need the instances to reach the internet to pull Docker images and
Python packages — but our app subnets are **private with no NAT** (a cost choice
we made in Phase 1). Adding NAT just to test autoscaling would burn money for no
learning.

So for Phase 2 the instances run a **zero-dependency placeholder**: a ~10-line
**Python standard-library** HTTP server (Python 3 ships in Amazon Linux 2023, so
**nothing is downloaded**). It answers on `:8000` with a health message including
its own hostname — perfect for proving that traffic reaches *a specific
instance*, that the ALB load-balances across them, and that the ASG self-heals.

> 🧠 **Why this is the right call.** Phase 2 is about the *compute and
> load-balancing machinery*, not the app. By removing the internet dependency we
> keep the app tier genuinely private (no public IP, no NAT) — the
> architecturally correct, free, and honest version. In Phase 4 we'll introduce
> proper egress (a short-lived NAT instance or a baked AMI / S3 artifact) when the
> real app actually needs it.

---

## 3. The Terraform folder

A new stack, with its own state key (`compute/...`) in the same S3 bucket:

```
terraform/
├── bootstrap/   ← Phase 0 (leave it)
├── network/     ← Phase 1 (leave it running — it's free)
└── compute/     ← Phase 2 — THIS doc and Doc 10
```

Files for this doc:

```
providers.tf       # terraform{} + backend{} (key=compute/...) + provider{}
variables.tf       # region, project, instance_type, ASG sizing
data.tf            # remote state (network), latest AL2023 AMI
iam.tf             # EC2 instance role + instance profile (SSM-ready)
launch-template.tf # the instance "recipe" + user_data
asg.tf             # the Auto Scaling Group
outputs.tf         # ASG name, launch template id
```

### What each file's job is, in one sentence

| File | One-line purpose |
|---|---|
| `providers.tf` | Connect Terraform to AWS; store state in `compute/...` of our S3 bucket. |
| `variables.tf` | Inputs to this stack: region, project name, instance type, ASG sizing. |
| `data.tf` | **Read** two things: the network stack's outputs, and the AMI ID — neither is created here. |
| `iam.tf` | Make an IAM role + instance profile so the EC2 can talk to SSM (no SSH keys). |
| `launch-template.tf` | The recipe for one EC2: AMI, type, SG, profile, hardening, boot script. |
| `asg.tf` | The manager that keeps N copies of the recipe alive across both app subnets. |
| `outputs.tf` | Publish the ASG name and Launch Template id for downstream stacks. |

---

## 4. `providers.tf` — a new backend key

```hcl
# terraform/compute/providers.tf

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "compute/terraform.tfstate" # ← different key = isolated state
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
      Component = "compute"
    }
  }
}
```

### What every line does

This is structurally identical to your network stack's `providers.tf`. The
**only** real difference is the `key` line.

| Line | Meaning |
|---|---|
| `terraform { required_version = ">= 1.5" }` | Refuse old Terraform CLIs. |
| `required_providers { aws = ... }` | "Download the AWS plugin v5.x at init." |
| `backend "s3"` block | "Store this folder's state in S3." Same bucket as bootstrap; **different key** so this folder's state can't collide with another's. |
| `key = "compute/terraform.tfstate"` | The path inside the bucket. **This is the line that defines state isolation.** Network is at `network/...`, this is at `compute/...`. |
| `dynamodb_table = "cloudcare-tf-locks"` | The shared lock — prevents two `terraform apply` runs racing. |
| `provider "aws" { region = ... }` | Region read from a variable. |
| `default_tags { ... }` | Every resource created in this folder gets `Project=cloudcare`, `ManagedBy=terraform`, `Component=compute` stamped on it for free. |

> 🧠 Same bucket, **new `key`**. The network stack owns `network/...`; this stack
> owns `compute/...`. They never touch each other's state — a `terraform destroy`
> here can't harm the VPC.

---

## 5. `variables.tf`

```hcl
# terraform/compute/variables.tf

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix in Name tags"
  type        = string
  default     = "cloudcare"
}

variable "instance_type" {
  description = "EC2 instance type (t2.micro is free-tier eligible)"
  type        = string
  default     = "t2.micro"
}

variable "asg_min_size" {
  description = "Minimum number of app instances"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of app instances (scale to 2 only to demo)"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Normal number of app instances to keep running"
  type        = number
  default     = 1 # one instance = stays inside the 750 free t2.micro hours
}
```

### Each variable in context

| Variable | What it controls | Override how |
|---|---|---|
| `aws_region` | All resources go here. Default = Mumbai. | `-var='aws_region=...'` |
| `project` | Prefix for the `Name` tag on resources. | `-var='project=...'` |
| `instance_type` | The hardware (CPU/RAM) of every EC2. `t2.micro` is free-tier; `t3.micro` is the modern equivalent for new accounts. | `-var='instance_type=t3.micro'` |
| `asg_min_size` | Hard lower bound on the number of running instances. Set to 1 so health-failures still leave a survivor. | `-var='asg_min_size=2'` |
| `asg_max_size` | Hard upper bound. Set to 2 so even an autoscaling explosion can't break your budget. | `-var='asg_max_size=4'` |
| `asg_desired_capacity` | Normal steady-state count. ASG aims for this number, clamping between min and max. | `-var='asg_desired_capacity=2'` |

> 💰 **Why `desired = 1`.** The free tier covers **750 `t2.micro` hours/month** ≈
> one instance running 24/7. Two instances 24/7 ≈ 1,460 hours → you'd pay for
> ~710. We keep one normally and scale to two only briefly to *watch* it work.

> 🧠 **Why min/max bounds exist at all.** AWS autoscaling policies (or a buggy
> manual change) could in theory push the desired count to 100. `max_size = 2`
> means *no matter what any policy says*, the ASG will never exceed 2 instances.
> Hard guard rails are a cost-safety habit worth keeping.

---

## 6. `data.tf` — read the network, find the AMI

```hcl
# terraform/compute/data.tf

# Read the Phase 1 network stack's outputs (subnets, security groups, VPC id).
# This is how stacks share data without redefining resources.
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "network/terraform.tfstate"
    region = "ap-south-1"
  }
}

# Always boot the LATEST Amazon Linux 2023 image, rather than hardcoding an AMI
# ID (AMI IDs differ per region and change as AWS patches them).
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

### The two-data-source pattern in detail

#### `data` vs `resource`

| Block | Meaning |
|---|---|
| `resource "..."` | **Create and manage** a real AWS thing — Terraform owns its lifecycle. |
| `data "..."` | **Look up** an existing AWS thing — Terraform reads but never modifies. |

A `data` block runs **every time you `plan`/`apply`** — so if you build a `data
"aws_ami"` that picks "the latest" image, you always get fresh values without
edits.

#### Data source 1 — `terraform_remote_state.network` (the cross-folder cable)

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "network/terraform.tfstate"   # ← points at the NETWORK folder's state
    region = "ap-south-1"
  }
}
```

| Field | Meaning |
|---|---|
| `data "terraform_remote_state" "network"` | A special data source: read **another Terraform stack's state file** from a backend. Nickname `network`. |
| `backend = "s3"` | "It's stored in S3." (Same type as the backend that wrote it.) |
| `config.bucket / config.key / config.region` | **Where** that state file lives — same S3 bucket, the network folder's key. |

What you get out of it is a `.outputs` map. Read values like:

```hcl
data.terraform_remote_state.network.outputs.app_subnet_ids
data.terraform_remote_state.network.outputs.app_security_group_id
data.terraform_remote_state.network.outputs.vpc_id
```

The network stack's `outputs.tf` is the published "interface" — change a name
there, you need to change it here too.

> 🧠 **`terraform_remote_state` is read-only.** It fetches the *outputs* the
> network stack published (Docs 07–08). You reference them like
> `data.terraform_remote_state.network.outputs.app_subnet_ids`. If you ever change
> an output name in the network stack, update it here too.

#### Data source 2 — `aws_ami.al2023` (find the OS image)

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter { name = "name"               values = ["al2023-ami-2023.*-x86_64"] }
  filter { name = "virtualization-type" values = ["hvm"] }
}
```

An **AMI** is the install disk for an EC2. AWS publishes new AMIs every time
they patch the OS, so the AMI ID itself changes. Hardcoding `ami-0123abc` would
mean every patch breaks your config.

| Field | Meaning |
|---|---|
| `most_recent = true` | If multiple match, take the newest one (by creation date). |
| `owners = ["amazon"]` | Only consider AMIs owned by AWS itself (avoids third-party copies). |
| `filter { name = "name", values = ["al2023-ami-2023.*-x86_64"] }` | Wildcard match on the AMI name pattern. `al2023-ami-2023.*-x86_64` matches all AL2023 builds for 64-bit x86. |
| `filter { name = "virtualization-type", values = ["hvm"] }` | Only HVM (hardware-virtual-machine) images — the modern default. |

The result, after lookup, is available as `data.aws_ami.al2023.id` — a string
like `ami-0abc1234...`. The launch template uses this in §8.

---

## 7. `iam.tf` — an instance role (no SSH keys, ever)

Modern EC2 instances shouldn't have SSH keys or stored AWS credentials. Instead
we attach an **IAM role** via an **instance profile**. We grant the AWS-managed
`AmazonSSMManagedInstanceCore` policy so you *could* open a shell with **SSM
Session Manager** (browser-based, keyless) — and so the CloudWatch agent has a
home later.

```hcl
# terraform/compute/iam.tf

# Trust policy: "EC2 instances are allowed to ASSUME this role."
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.project}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# AWS-managed policy that lets Systems Manager manage the instance (Session
# Manager shell, patching). Least-privilege-friendly and free.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# An instance profile is the wrapper that actually attaches a role to an EC2.
resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app-profile"
  role = aws_iam_role.app.name
}
```

### "Why so many blocks for one role?" (the most-asked question)

A role is built from **4 Lego pieces**, each its own block, because they're
re-usable independently:

```
  ① data "aws_iam_policy_document" "ec2_assume"
        └─ a JSON doc that says "EC2 may assume this role"

  ② resource "aws_iam_role" "app"
        └─ the role itself, with the doc from ① attached as its "trust policy"

  ③ resource "aws_iam_role_policy_attachment" "ssm"
        └─ attaches the AWS-managed SSM permissions policy to the role

  ④ resource "aws_iam_instance_profile" "app"
        └─ the EC2-only wrapper that lets us pin the role onto a server
```

A role has **two sides**:
- **Trust** (who can wear me?) — set by ① and plugged into ② via `assume_role_policy`.
- **Permissions** (what can I do?) — added by ③ (one block per policy; add more
  later for S3, Secrets Manager, etc.).

EC2 specifically also needs the **instance profile** (④) — Lambda and ECS don't.
It's an AWS API quirk we have to live with.

### Block 1 — the trust policy document

```hcl
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
```

| Line | Meaning |
|---|---|
| `data "aws_iam_policy_document"` | A Terraform **helper** that builds a JSON policy document — easier than hand-writing JSON. |
| `statement { ... }` | One rule in the document. Documents can have many; we have one. |
| `actions = ["sts:AssumeRole"]` | The action being allowed: literally *"assume / put on / wear the role."* (STS = Security Token Service.) |
| `principals { type = "Service", identifiers = ["ec2.amazonaws.com"] }` | The **WHO**: only the EC2 service is allowed to wear this role. |

In plain English: *"This document says: only the EC2 service may assume me."*

The output is accessible as `data.aws_iam_policy_document.ec2_assume.json` —
a JSON string ready to plug into the next block.

### Block 2 — the role itself

```hcl
resource "aws_iam_role" "app" {
  name               = "${var.project}-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}
```

| Line | Meaning |
|---|---|
| `resource "aws_iam_role" "app"` | Create the role. Console name: `cloudcare-app-role`. |
| `assume_role_policy = ...` | The **trust policy** = the JSON from Block 1. This is what makes "only EC2 may wear me" stick. |

The role now exists with the right "trust" — but it can't *do* anything yet.

### Block 3 — give the role a permission

```hcl
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

| Line | Meaning |
|---|---|
| `aws_iam_role_policy_attachment` | The "glue" resource between a role and a policy. |
| `role = aws_iam_role.app.name` | Which role. |
| `policy_arn = ".../AmazonSSMManagedInstanceCore"` | Which policy — AWS pre-wrote this one. It contains all the permissions Systems Manager needs (Session Manager + patching + compliance reporting). |

To add S3 read access later, you'd add a **second** identical block with
`policy_arn = ".../AmazonS3ReadOnlyAccess"`. Same shape, different policy.

### Block 4 — the instance profile (the EC2-only wrapper)

```hcl
resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app-profile"
  role = aws_iam_role.app.name
}
```

EC2 cannot directly accept a role — it needs this wrapper. The launch template
then references `aws_iam_instance_profile.app.arn` to clip it onto each EC2.

> 🧠 **Role vs keys (interview answer):** "We attach an IAM *role* to the instance
> via an instance profile. The instance gets short-lived, auto-rotated credentials
> from the instance metadata service — no long-lived keys to leak. SSH is replaced
> by SSM Session Manager, so we don't even open port 22."

> 💡 **Heads-up:** SSM Session Manager needs the instance to reach the SSM
> endpoints. Because our app subnets have **no internet egress** (no NAT), Session
> Manager won't connect *yet*. The role is correct and ready; to actually use a
> shell now you'd add SSM **interface VPC endpoints** (small hourly cost) or a
> temporary NAT instance. For Phase 2 we verify through the load balancer instead,
> so we don't need a shell.

---

## 8. `launch-template.tf` — the instance recipe

```hcl
# terraform/compute/launch-template.tf

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # Attach the APP security group from Phase 1 (only :8000 from the ALB).
  vpc_security_group_ids = [
    data.terraform_remote_state.network.outputs.app_security_group_id
  ]

  # Force IMDSv2 (token-based metadata) — blocks a common SSRF credential-theft
  # path. A cheap, expected security hardening.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Boot script: install NOTHING; run a stdlib HTTP health server on :8000.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    cat >/opt/health.py <<'PY'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import socket
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(("CloudCare healthy from %s\n" % socket.gethostname()).encode())
        def log_message(self, *args):
            return
    HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
    PY

    cat >/etc/systemd/system/cloudcare.service <<'UNIT'
    [Unit]
    Description=CloudCare placeholder health service
    After=network.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/health.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now cloudcare
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project}-app"
    }
  }
}
```

This is the longest block in the project, but it's organized into 7 logical
sections. Let's go through each.

### Section 1 — Identity

```hcl
resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
```

| Line | Meaning |
|---|---|
| `resource "aws_launch_template" "app"` | Create a launch template; nickname it `app`. |
| `name_prefix = "${var.project}-app-"` | AWS auto-appends a random suffix → e.g. `cloudcare-app-xa7b9`. Using `name_prefix` instead of `name` lets new versions of the template be created cleanly when something changes. |

### Section 2 — Which OS, which size

```hcl
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type
```

| Line | Meaning |
|---|---|
| `image_id = data.aws_ami.al2023.id` | The AMI to boot from — set to whatever the AL2023 data lookup returned. Every new instance gets the newest patched OS. |
| `instance_type = var.instance_type` | Hardware shape. Default `t2.micro`. |

### Section 3 — Which IAM badge to wear

```hcl
  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }
```

| Line | Meaning |
|---|---|
| `iam_instance_profile { }` | Nested block: which instance profile to attach. |
| `arn = aws_iam_instance_profile.app.arn` | Reference the profile from `iam.tf` block 4. Every EC2 the ASG launches will wear this badge → so the SSM agent can authenticate to AWS. |

### Section 4 — Which firewall

```hcl
  vpc_security_group_ids = [
    data.terraform_remote_state.network.outputs.app_security_group_id
  ]
```

| Line | Meaning |
|---|---|
| `vpc_security_group_ids = [...]` | A **list** of SG IDs to attach. Note the `[]` — you can attach multiple. |
| `data.terraform_remote_state.network.outputs.app_security_group_id` | Reach into the network stack's state and read the **App SG**'s ID. That's the SG that allows port 8000 only from the ALB. |

This is the **second** time we used `terraform_remote_state` — once for subnet
IDs (in `asg.tf`, coming up), once here for the SG. The same pattern.

### Section 5 — Lock down the metadata service (IMDSv2)

```hcl
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }
```

This section is small but does real security work.

**Background:** every EC2 has a built-in tiny HTTP service at
`http://169.254.169.254/` called **IMDS** (Instance Metadata Service). It
returns info about the instance — including the **temporary AWS credentials**
of the attached IAM role. Anyone (or any process) inside the instance can fetch
those.

- **IMDSv1** (legacy): just send a plain HTTP GET. No proof needed. If your web
  app has an SSRF bug (Server-Side Request Forgery — attacker tricks the app
  into fetching arbitrary URLs), an attacker can request the credentials URL
  and steal the role's credentials.
- **IMDSv2**: requires a short-lived **session token** obtained by first doing
  a `PUT` with a custom header. SSRF bugs can't usually do that.

| Line | Meaning |
|---|---|
| `http_endpoint = "enabled"` | IMDS is **on** (you still need it for the agent to read its credentials). |
| `http_tokens = "required"` | **IMDSv2 only.** v1 is refused. This is the security win. |

> 🧠 **Interview soundbite:** *"`http_tokens = required` enforces IMDSv2, which
> requires a session-token PUT before any metadata request. This blocks the
> classic SSRF-to-credential-theft attack — an attacker exploiting an HTTP-fetch
> bug can't issue the PUT with custom headers needed to obtain the token."*

### Section 6 — `user_data`: the boot script (the big one)

```hcl
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    ...
  EOF
  )
```

`user_data` is a script that AWS runs **as root, exactly once, on the very
first boot** of the instance. It's how you turn a blank Amazon Linux box into
"your app server" without ever SSHing in.

#### The wrapper

| Piece | Meaning |
|---|---|
| `user_data = base64encode(...)` | AWS's API accepts user-data **only as base64**. `base64encode()` is a built-in Terraform function. AWS decodes it inside the instance before running. |
| `<<-EOF ... EOF` | A **heredoc** — a way to write a multi-line string in Terraform. The `-` strips leading whitespace from each line (so your indentation doesn't appear in the actual script). |

#### The shell script inside, line by line

```bash
#!/bin/bash
set -euo pipefail
```

| Line | Meaning |
|---|---|
| `#!/bin/bash` | The **shebang** — tells the kernel "run this with bash." First line of any script. |
| `set -euo pipefail` | Strict mode. **`-e`** exit on any error. **`-u`** error if you use an undefined variable. **`-o pipefail`** if any command in a pipeline fails, the whole pipeline fails. Stops silent failures. |

#### Sub-section: writing the Python file via a nested heredoc

```bash
cat >/opt/health.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import socket
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(("CloudCare healthy from %s\n" % socket.gethostname()).encode())
    def log_message(self, *args):
        return
HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
PY
```

This is **a heredoc inside a heredoc.** The outer `<<-EOF ... EOF` is
Terraform's multi-line string. The inner `<<'PY' ... PY` is shell's heredoc that
feeds text to `cat`.

| Piece | Meaning |
|---|---|
| `cat > /opt/health.py` | Run `cat`, redirecting its output (`>`) into the file `/opt/health.py`. |
| `<<'PY' ... PY` | Heredoc — everything between the markers becomes `cat`'s input → becomes the file's contents. |
| `'PY'` in single quotes | **Critical**: single-quoting the marker disables shell variable expansion inside. So `$something` in Python stays literal, not replaced by the shell. |

The Python file itself is a 10-line HTTP server that responds to any GET with
`200 OK` and the hostname. That's the placeholder app.

#### Sub-section: writing the systemd unit (so the service auto-restarts)

```bash
cat >/etc/systemd/system/cloudcare.service <<'UNIT'
[Unit]
Description=CloudCare placeholder health service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/health.py
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
```

Same `cat + heredoc` trick. This writes a **systemd service unit**.

| Line | Meaning |
|---|---|
| `[Unit] After=network.target` | Wait until networking is up before starting this service. |
| `[Service] ExecStart=...` | What command to run = the Python health script. |
| `Restart=always` | If the script crashes, restart it. **Self-healing.** |
| `[Install] WantedBy=multi-user.target` | Start when the system reaches normal multi-user state (i.e. normal boot). |

#### Activation

```bash
systemctl daemon-reload
systemctl enable --now cloudcare
```

| Command | Meaning |
|---|---|
| `systemctl daemon-reload` | Tell systemd "I just added a new unit file, re-scan." |
| `systemctl enable --now cloudcare` | **`enable`** = start at every future boot. **`--now`** = also start it **right now**. |

After this last line runs, the Python health server is **live on port 8000**.

> 🧠 **`user_data` runs once at first boot** (as root, via cloud-init). Here it
> writes a tiny Python server and a systemd unit so the service **restarts if it
> crashes** and **survives a reboot**. `base64encode(...)` is just how the launch
> template wants the script wrapped.

### Section 7 — Tag the resulting EC2

```hcl
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project}-app"
    }
  }
}
```

Tags on a launch template stay on the **template** by default. This block tells
it to **also stamp the tags on every EC2 instance** the template produces.

| Line | Meaning |
|---|---|
| `tag_specifications { }` | Where to apply tags. |
| `resource_type = "instance"` | Tag the EC2 itself (not the EBS volume — that needs its own block). |
| `tags = { Name = "${var.project}-app" }` | Every produced EC2 gets `Name = cloudcare-app`. |

> 🧠 **No `associate_public_ip`.** The app subnets have
> `map_public_ip_on_launch = false`, so instances get **no public IP** — they're
> unreachable from the internet, exactly as a private app tier should be. The only
> way in is via the ALB on :8000 (Doc 10).

---

## 9. `asg.tf` — the Auto Scaling Group

```hcl
# terraform/compute/asg.tf

resource "aws_autoscaling_group" "app" {
  name             = "${var.project}-app-asg"
  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # Spread instances across BOTH private app subnets (one per AZ).
  vpc_zone_identifier = data.terraform_remote_state.network.outputs.app_subnet_ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # For now, use EC2 status checks for health. Doc 10 upgrades this to "ELB" so
  # the ALB's HTTP health check decides whether an instance is healthy.
  health_check_type         = "EC2"
  health_check_grace_period = 60

  # Tag every launched instance (propagate_at_launch) so they show your project.
  tag {
    key                 = "Name"
    value               = "${var.project}-app"
    propagate_at_launch = true
  }

  # Replace instances one at a time when the launch template changes.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }
}
```

### Walk-through

#### Header + sizing

```hcl
resource "aws_autoscaling_group" "app" {
  name             = "${var.project}-app-asg"
  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity
```

| Line | Meaning |
|---|---|
| `name = "${var.project}-app-asg"` | Console name → `cloudcare-app-asg`. |
| `min_size = var.asg_min_size` | ASG won't drop below this. `1`. |
| `max_size = var.asg_max_size` | ASG won't exceed this. `2`. |
| `desired_capacity = var.asg_desired_capacity` | Aim for this number normally. `1`. |

#### Where to put instances

```hcl
  vpc_zone_identifier = data.terraform_remote_state.network.outputs.app_subnet_ids
```

`vpc_zone_identifier` is poorly named — it really means **"list of subnet IDs
the ASG may place instances in."** Each subnet implies an AZ, so giving multiple
subnets across AZs = multi-AZ deployment.

`data.terraform_remote_state.network.outputs.app_subnet_ids` is a 2-element
list (app-a, app-b). The ASG will balance instances across both AZs.

#### Which recipe to use

```hcl
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
```

| Line | Meaning |
|---|---|
| `launch_template { ... }` | Which Launch Template to bake from. |
| `id = aws_launch_template.app.id` | Reference our template. |
| `version = "$Latest"` | Always use the newest version. Other options: `"$Default"`, or a specific number like `"3"`. |

> 🧠 Launch templates are **versioned**. Every time Terraform changes anything in
> `launch-template.tf`, a new version is created (old ones aren't deleted). `"$Latest"`
> means "always pick the newest" — combined with `instance_refresh` below, this
> gives you safe rolling deploys.

#### Health-check choice

```hcl
  health_check_type         = "EC2"
  health_check_grace_period = 60
```

| Field | Values | Meaning |
|---|---|---|
| `health_check_type` | `"EC2"` or `"ELB"` | **`EC2`** = AWS just pings the hypervisor (is the VM alive?). **`ELB`** = the ALB's HTTP health check decides (does the app respond?). |
| `health_check_grace_period` | seconds | New instances get this many seconds before they're considered "ready" — gives `user_data` time to run. |

For now we use `EC2` because there's no ALB attached yet. **Doc 10 upgrades this
to `ELB`** so an instance that's running but whose app crashed is replaced.

#### Tag propagation

```hcl
  tag {
    key                 = "Name"
    value               = "${var.project}-app"
    propagate_at_launch = true
  }
```

This is the ASG's own way to tag instances it creates (similar but separate
from the launch template's `tag_specifications`). `propagate_at_launch = true`
puts the tag on each new EC2 as it launches.

#### Instance refresh (rolling deploys)

```hcl
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }
```

When you change the launch template (e.g., update the user-data script),
Terraform's plan tells the ASG to refresh. `instance_refresh` controls how:

| Field | Meaning |
|---|---|
| `strategy = "Rolling"` | Replace instances one at a time — never all at once. |
| `min_healthy_percentage = 50` | Don't let the count of healthy instances drop below 50% during the refresh. With `desired=1`, this means *"replace it (briefly drop to 0) only after the new one is healthy."* In production with desired=3, it means *"keep at least 2 healthy as we replace the third."* |

You can trigger a refresh manually too:
```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$(terraform output -raw asg_name)"
```

> 🧠 **`vpc_zone_identifier` across two subnets** is what makes the app tier
> multi-AZ: the ASG balances instances across AZ-a and AZ-b. Lose an AZ and the
> ASG launches replacements in the survivor.

> 💡 **Optional — real autoscaling (the "auto" part).** A target-tracking policy
> adds/removes instances by CPU. Add this to demo it, but it won't trigger under a
> placeholder's tiny load:
> ```hcl
> resource "aws_autoscaling_policy" "cpu" {
>   name                   = "${var.project}-cpu-target"
>   autoscaling_group_name = aws_autoscaling_group.app.name
>   policy_type            = "TargetTrackingScaling"
>   target_tracking_configuration {
>     predefined_metric_specification {
>       predefined_metric_type = "ASGAverageCPUUtilization"
>     }
>     target_value = 50.0
>   }
> }
> ```

---

## 10. `outputs.tf`

```hcl
# terraform/compute/outputs.tf

output "asg_name" {
  description = "Name of the app Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "ID of the app launch template"
  value       = aws_launch_template.app.id
}
```

Two outputs published so downstream stacks (and CLI scripts) can refer to this
compute by name:

| Output | What it's for |
|---|---|
| `asg_name` | Used to trigger instance refreshes (`aws autoscaling start-instance-refresh --auto-scaling-group-name $(terraform output -raw asg_name)`) and watched by Phase 7 observability. |
| `launch_template_id` | Reference, for debugging or to query historical versions in the console. |

(The load-balancer outputs you'll actually `curl` come in Doc 10.)

> 💡 In Doc 18 (Observability) you'll add a third output, `alb_arn_suffix`, used
> by CloudWatch alarms. Don't worry about that now — you can always re-apply this
> folder to add new outputs without changing any infrastructure.

---

## 11. Apply & verify

From inside `terraform/compute/`:

### Step 1 — Credentials

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1
```

`export NAME=value` sets a shell environment variable. Both `terraform` and
`aws` read these to authenticate. They last only in the current terminal
window.

### Step 2 — `terraform init`

```bash
terraform init
```

First time in this folder, `init`:
1. Downloads the AWS provider plugin (cached in `.terraform/`).
2. Connects to the S3 backend; sees `compute/terraform.tfstate` doesn't exist yet.
3. Connects to the DynamoDB lock table (verifies the table exists).
4. Writes `.terraform.lock.hcl` (provider checksum pinning).

You should see:
```
Initializing the backend...
Successfully configured the backend "s3"!
Initializing provider plugins...
- Installing hashicorp/aws v5.x.x...
Terraform has been successfully initialized!
```

### Step 3 — Lint, validate, plan

```bash
terraform fmt
terraform validate
terraform plan
```

| Command | Purpose |
|---|---|
| `terraform fmt` | Auto-format `.tf` files. Safe; just style. |
| `terraform validate` | Check syntax + reference integrity. **Local-only.** Does not touch AWS. |
| `terraform plan` | Refresh data sources (the `aws_ami` lookup runs), compare desired vs current, print what would happen. |

Expect **`Plan: 5 to add, 0 to change, 0 to destroy.`** —

| Resource | Count |
|----------|------:|
| IAM role + role-policy attachment + instance profile | 3 |
| Launch template | 1 |
| Auto Scaling Group | 1 |
| **Total** | **5** |

(The EC2 *instance* the ASG launches is not a Terraform-managed resource, so it
doesn't appear in the count. Terraform only knows about the ASG, not the
ephemeral instances it produces.)

### Step 4 — Apply

```bash
terraform apply       # type "yes"
```

What happens:
1. DynamoDB lock acquired.
2. IAM resources created first (the launch template depends on them).
3. Launch template created (with all 7 sections from §8).
4. ASG created — and immediately starts launching its **first EC2** in one of
   the app subnets.
5. State saved to S3; lock released.
6. Outputs printed.

**The EC2 itself comes online ~30–90 seconds after apply returns.** Terraform
doesn't wait — once the ASG exists, it's the ASG that boots the instance.

### Step 5 — Verify (no shell needed)

#### Check the ASG and its instance(s)

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $(terraform output -raw asg_name) \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,AZ:AvailabilityZone,Health:HealthStatus,State:LifecycleState}}' \
  --output table
```

**Decoded:**

- `aws autoscaling describe-auto-scaling-groups` — describe ASGs.
- `--auto-scaling-group-names $(terraform output -raw asg_name)` — only the ASG
  we just made. The `$( ... )` substitution prints `cloudcare-app-asg`.
- `--query 'AutoScalingGroups[0].{...}'` — JMESPath. Pull the first ASG, then
  build a sub-object with `Desired:DesiredCapacity` and a list of `Instances`
  with id, AZ, health, and lifecycle state.

Expected output:
```
-----------------------------------------------------------
|             DescribeAutoScalingGroups                   |
+---------+-----------------------------------------------+
| Desired |                  Instances                    |
+---------+-----------------------------------------------+
|  1      | [{                                            |
|         |   "Id": "i-0abc...",                          |
|         |   "AZ": "ap-south-1a",                        |
|         |   "Health": "Healthy",                        |
|         |   "State": "InService"                        |
|         | }]                                            |
+---------+-----------------------------------------------+
```

#### Confirm the instance has the right network properties

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cloudcare-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,AZ:Placement.AvailabilityZone,Private:PrivateIpAddress,Public:PublicIpAddress}' \
  --output table
```

**Decoded:**

- `aws ec2 describe-instances` — describe EC2 instances.
- `--filters` two of them:
  - `Name=tag:Name,Values=cloudcare-app` → only ones we tagged.
  - `Name=instance-state-name,Values=running` → only running ones.
- `--query 'Reservations[].Instances[].{...}'` — Instances are nested under
  Reservations in the AWS API; flatten with `Reservations[].Instances[]`.
- Pull `InstanceId`, the AZ, the private IP, and the public IP.

What you want to see:
```
--------------------------------------------------------
|                  DescribeInstances                   |
+---------------------+--------------+--------+--------+
|         Id          |     AZ       |Private | Public |
+---------------------+--------------+--------+--------+
| i-0abc...           | ap-south-1a  |10.0.10.x|  None |
+---------------------+--------------+--------+--------+
```

- ✅ `Private = 10.0.10.x` → it's in an app subnet (our `/24` range).
- ✅ `Public = None` → no public IP. The instance is **invisible to the internet**.
- ✅ `LifecycleState = InService` → ASG considers it healthy.

The placeholder is serving on `:8000`, but nothing can reach it yet — that's
the load balancer's job (next doc).

> 🧠 **Self-healing demo (optional, satisfying):** terminate the instance —
> `aws ec2 terminate-instances --instance-ids <id>` — wait ~1–2 minutes, and
> re-run the ASG query. A brand-new instance appears with no action from you.
> *That* is the ASG earning its keep.

---

## 12. 💰 Cost & teardown (read before you stop)

This is the first phase that can cost money if you forget it:

| Resource | Free-tier status |
|----------|------------------|
| 1× `t2.micro` (desired=1) | ✅ within 750 hrs/month for 12 months |
| 2× `t2.micro` (scaled) 24/7 | ⚠️ exceeds 750 hrs — only scale to 2 briefly |
| Launch template, ASG, IAM | ✅ free |
| EBS root volume (8 GB gp3) | ✅ within 30 GB free-tier |

> 💰 **Teardown habit:** when you finish a lab session, destroy the compute stack:
> ```bash
> terraform destroy   # in terraform/compute/
> ```
> This removes the EC2 instance(s), ASG, launch template, and IAM role — back to
> $0 compute. **Leave `network/` and `bootstrap/` up** (they're free). Recreate
> compute anytime with `terraform apply`. We'll keep it up across Doc 10 so you
> can test the ALB, then tear both down together.

---

## 13. Plain-English summary (what you just built)

If asked to explain Phase 2 part 1:

1. **One Launch Template** (`cloudcare-app-xxxx`) describes a single EC2:
   AL2023 image, `t2.micro` size, wearing the IAM role (`cloudcare-app-role`)
   that grants SSM permissions, with the App SG attached (only `:8000` from the
   ALB), IMDSv2 enforced, and a user-data script that writes a tiny Python
   health server + a systemd unit and starts it on boot.
2. **One Auto Scaling Group** (`cloudcare-app-asg`) keeps **1** copy of that
   template alive (min=1, max=2, desired=1) **spread across both app subnets**
   (multi-AZ). Health checks use EC2 status (Doc 10 upgrades to ELB).
3. The **IAM** stack is four blocks: a trust doc, the role, an SSM policy
   attachment, and the instance-profile wrapper EC2 needs.
4. The compute folder **does not own any network resources** — it reads the
   network stack's outputs (subnet IDs, security-group IDs) via
   `terraform_remote_state`.
5. The first EC2 boots ~30–90 seconds after apply, sits in an app subnet with a
   `10.0.10.x` private IP, **no public IP**, running the placeholder on `:8000`.
6. Nothing in the world can reach `:8000` yet — that's Doc 10's job (ALB).

---

## 14. Interview soundbites

- **Pet vs cattle** — *"We don't hand-create EC2s. A launch template describes
  one server; an ASG keeps N copies alive across two subnets in two AZs and
  replaces them when they die. Instances are interchangeable, named only by tag,
  and recreated freely — that's the cattle-not-pets pattern."*

- **IAM role, no SSH** — *"Each instance wears an IAM role through an instance
  profile. Credentials are issued by the metadata service, short-lived, and
  auto-rotated. We don't open port 22 — operators use SSM Session Manager,
  authenticated via IAM, audited in CloudTrail."*

- **IMDSv2** — *"`http_tokens = required` enforces IMDSv2, which requires a
  session-token PUT before any metadata GET. That blocks the classic SSRF →
  credential-theft attack chain."*

- **Multi-AZ from the ASG** — *"`vpc_zone_identifier` lists both app subnets,
  one in each AZ. The ASG balances instances across them and self-heals into
  the surviving AZ if one fails."*

- **Why placeholder, not the real app** — *"Phase 2 is about the compute
  machinery — launch template, ASG, security, network placement. The app subnets
  have no internet, so we run a stdlib Python server with zero dependencies.
  The real FastAPI in Docker comes in Phase 4 alongside a NAT instance for ECR
  pulls."*

- **Instance refresh** — *"`instance_refresh.strategy = Rolling` with
  `min_healthy_percentage` controls zero-downtime deploys: when the launch
  template changes, the ASG replaces instances one at a time, keeping the
  fleet's healthy fraction above the threshold."*

---

## ✅ Checkpoint

You're ready for Doc 10 when:

- [ ] `terraform/compute/` applied (`Apply complete! Resources: 5 added`).
- [ ] The ASG shows **1 instance, `InService`**, in a private app subnet.
- [ ] That instance has a **private IP and no public IP**.
- [ ] You can explain: Launch Template vs ASG, why instances use an IAM **role**,
      and why the app tier has no public IP.
- [ ] You can read every line in `iam.tf`, `launch-template.tf`, and `asg.tf`
      and explain it in plain English.

Next: **[10 — Compute: Application Load Balancer](10-compute-application-load-balancer.md)**
— we put an internet-facing ALB in the public subnets, point it at these
instances on :8000, and finally `curl` CloudCare end-to-end.
