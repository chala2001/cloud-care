# 09 — Compute: Launch Template, IAM Role & Auto Scaling Group

> **Goal of this doc:** stand up the **application tier** — a self-healing
> **Auto Scaling Group** of `t2.micro` instances in your private app subnets, each
> booting from a **Launch Template** that runs a tiny placeholder web service on
> port 8000. We wire it to the Phase 1 network by *reading* that stack's outputs
> with `terraform_remote_state`. The load balancer comes in
> [Doc 10](10-compute-application-load-balancer.md).

⏱️ Time: ~75–90 minutes.
💰 Cost: ~$0 if you run **one** `t2.micro` and **destroy after the lab**. This is
the first phase with real free-tier risk — read §9 before you walk away.

This is the start of **Phase 2 — Compute.** Same rhythm: concept → design →
code → apply & verify → destroy.

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

> 💰 **Why `desired = 1`.** The free tier covers **750 `t2.micro` hours/month** ≈
> one instance running 24/7. Two instances 24/7 ≈ 1,460 hours → you'd pay for
> ~710. We keep one normally and scale to two only briefly to *watch* it work.

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

> 🧠 **`terraform_remote_state` is read-only.** It fetches the *outputs* the
> network stack published (Docs 07–08). You reference them like
> `data.terraform_remote_state.network.outputs.app_subnet_ids`. If you ever change
> an output name in the network stack, update it here too.

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

> 🧠 **`user_data` runs once at first boot** (as root, via cloud-init). Here it
> writes a tiny Python server and a systemd unit so the service **restarts if it
> crashes** and **survives a reboot**. `base64encode(...)` is just how the launch
> template wants the script wrapped.

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

(The load-balancer outputs you'll actually `curl` come in Doc 10.)

---

## 11. Apply & verify

From inside `terraform/compute/`:

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

terraform init        # configures the compute/ backend + downloads provider
terraform fmt
terraform validate
terraform plan
```

Expect **`Plan: 5 to add, 0 to change, 0 to destroy.`** —

| Resource | Count |
|----------|------:|
| IAM role + role-policy attachment + instance profile | 3 |
| Launch template | 1 |
| Auto Scaling Group | 1 |
| **Total** | **5** |

(The EC2 *instance* the ASG launches is not a Terraform-managed resource, so it
doesn't appear in the count.)

```bash
terraform apply       # type "yes"
```

### Verify (no shell needed)

```bash
# The ASG exists and reports 1 instance:
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $(terraform output -raw asg_name) \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,AZ:AvailabilityZone,Health:HealthStatus,State:LifecycleState}}' \
  --output table

# The instance is running, in an app subnet, with NO public IP (good!):
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cloudcare-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,AZ:Placement.AvailabilityZone,Private:PrivateIpAddress,Public:PublicIpAddress}' \
  --output table
```

You want: one instance, `LifecycleState = InService`, a private IP like
`10.0.10.x`, and **`Public = null`**. The placeholder is serving on `:8000`, but
nothing can reach it yet — that's the load balancer's job (next doc).

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

## ✅ Checkpoint

You're ready for Doc 10 when:

- [ ] `terraform/compute/` applied (`Apply complete! Resources: 5 added`).
- [ ] The ASG shows **1 instance, `InService`**, in a private app subnet.
- [ ] That instance has a **private IP and no public IP**.
- [ ] You can explain: Launch Template vs ASG, why instances use an IAM **role**,
      and why the app tier has no public IP.

Next: **[10 — Compute: Application Load Balancer](10-compute-application-load-balancer.md)**
— we put an internet-facing ALB in the public subnets, point it at these
instances on :8000, and finally `curl` CloudCare end-to-end.
