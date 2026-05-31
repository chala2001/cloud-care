# 13 — Deploy the Backend to the EC2 App Tier

> **Goal of this doc:** run the real FastAPI image (from Doc 12) on the **private**
> EC2 app tier and serve it through the Phase 2 ALB. To do that we solve the
> egress problem we deferred twice: we add a **NAT instance** so private
> instances can pull the image, store the image in **ECR**, let instances read the
> **DB password from Secrets Manager** via their IAM role, and point the ALB
> health check at the real `/health`.

⏱️ Time: ~90 minutes. 💰 Cost: this runs a NAT `t3.micro` + an app `t3.micro` +
the ALB — watch your hours and **destroy after the lab** (§9).

This is the integration doc — everything from Phases 1–4 comes together here.

---

## 1. The egress problem (finally addressed)

Our app subnets are **private with no internet route** (Phase 1, on purpose — we
skipped the ~$32/mo NAT Gateway). But to *run* the real app, an instance must, at
boot:

1. `dnf install docker` — needs the Amazon Linux package repos (internet).
2. `docker pull` the image — needs the registry (internet).
3. `aws secretsmanager get-secret-value` — needs the AWS API (internet).

So the instances need **outbound** internet. Two ways to give it to them:

| Option | Cost | Complexity | We use |
|--------|------|------------|--------|
| **NAT instance** (a `t3.micro` doing NAT) | ~free (instance hours) | one EC2 + a route | ✅ this doc |
| Managed **NAT Gateway** | ~$32/mo + data | trivial | ❌ too costly |
| VPC **interface endpoints** (ECR/Secrets/Logs) + no internet | ~$0.01/hr each | several endpoints, repo quirks | 💡 the production "fully private" alternative |

> 🧠 **NAT instance vs NAT Gateway (interview favorite):** both let private
> subnets reach *out* without being reachable *in*. The **Gateway** is managed,
> scalable, and pricey; a **NAT instance** is a plain EC2 you configure to forward
> traffic — cheap but you own its availability and patching. For a solo learner on
> a budget, the NAT instance is the right trade-off; for production you'd use the
> Gateway (or, best, private VPC endpoints so you need no NAT at all).

---

## 2. What changes in `terraform/compute/`

We extend the compute stack (Phase 2). New/edited files:

```
terraform/compute/
├── ecr.tf            # NEW — a private image registry
├── nat.tf            # NEW — the NAT instance + route + its SG
├── data.tf           # EDIT — also read the DATABASE stack (secret ARN) + account id
├── iam.tf            # EDIT — add ECR-read + Secrets-read to the app role
├── launch-template.tf# EDIT — user_data now installs Docker + runs the real image
├── alb.tf            # EDIT — health check path → /health
└── variables.tf      # EDIT — add enable_nat_instance toggle
```

Plus one edit **outside** the compute stack:

```
terraform/network/
└── nacls.tf          # EDIT — private NACL must allow inbound return traffic
                      #        (ephemeral ports) now that the subnets egress via NAT
```

The order matters: **create ECR and push the image first**, *then* roll out the
new launch template — otherwise instances boot and find no image to pull. And
apply the **network NACL** change before (or with) the rollout, or the new
instances boot with no working egress.

---

## 3. `ecr.tf` — a private registry for the image

```hcl
# terraform/compute/ecr.tf

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true # free vulnerability scan on every push
  }

  force_delete = true # learning: allow `terraform destroy` even if images exist
}

output "ecr_repository_url" {
  description = "Push the backend image here"
  value       = aws_ecr_repository.backend.repository_url
}
```

Apply just this much first, then build & push (next section):

```bash
cd terraform/compute
terraform apply   # creates the ECR repo (1 to add)
```

> 💰 **ECR free tier:** 500 MB of storage/month for 12 months. Our slim image is
> well under that. `force_delete = true` lets the lab tear down cleanly.

---

## 4. Build and push the image (from your laptop)

> 📁 **Run these from the repository root**, not from inside `terraform/compute`.
> The paths below (`cd terraform/compute`, `cd app/backend`) are relative to the
> repo root — running them from another directory makes the `cd`s fail, `$REPO`
> comes back empty, and `docker push` errors with `":latest" is not a valid
> repository/tag`.

```bash
export AWS_PROFILE=cloudcare
REGION=ap-south-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO=$(cd terraform/compute && terraform output -raw ecr_repository_url)

# 1) Authenticate Docker to your ECR registry:
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

# 2) Build the image from Doc 12 and push it as :latest
cd app/backend
docker build -t cloudcare-backend .
docker tag cloudcare-backend:latest "$REPO:latest"
docker push "$REPO:latest"
```

Confirm it landed:

```bash
aws ecr list-images --repository-name cloudcare-backend --output table
```

> 🧠 This manual build-and-push is exactly what **Phase 8 CI/CD** will automate
> with GitHub Actions. Doing it by hand once makes the automation obvious later.

---

## 5. `variables.tf` — add the NAT toggle

```hcl
# add to terraform/compute/variables.tf

variable "enable_nat_instance" {
  description = "Run a NAT instance so private app instances have internet egress"
  type        = bool
  default     = true
}
```

> 💡 Keep this `true` whenever app instances might boot (including ASG
> replacements), because they fetch the image + secret at every launch. Set it
> `false` only if you're tearing the app tier down.

---

## 6. `data.tf` — read the database stack + account id

Append to the existing `terraform/compute/data.tf`:

```hcl
# Account id (for building the ECR URL inside user_data).
data "aws_caller_identity" "current" {}

# Read the DATABASE stack to get the Secrets Manager ARN to grant access to.
data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "database/terraform.tfstate"
    region = "ap-south-1"
  }
}
```

---

## 7. `nat.tf` — the NAT instance and its route

```hcl
# terraform/compute/nat.tf

# Security group: accept anything from inside the VPC (so private subnets can
# route through it), allow all outbound to the internet.
resource "aws_security_group" "nat" {
  count       = var.enable_nat_instance ? 1 : 0
  name        = "${var.project}-nat-sg"
  description = "NAT instance: forward traffic from the VPC to the internet"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description = "All traffic from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr]
  }

  egress {
    description = "All outbound to the internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-nat-sg" }
}

# The NAT instance itself — a t3.micro in a PUBLIC subnet with a public IP.
# NOTE: in ap-south-1 the free-tier micro is **t3.micro**, not t2.micro. Using
# t2.micro here returns "not eligible for Free Tier" at apply time.
resource "aws_instance" "nat" {
  count                       = var.enable_nat_instance ? 1 : 0
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = data.terraform_remote_state.network.outputs.public_subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.nat[0].id]

  # CRITICAL for a NAT: the instance must forward packets NOT addressed to itself.
  source_dest_check = false

  # user_data only runs on FIRST boot, and an in-place change doesn't recreate the
  # instance by default — so force a replacement whenever this script changes.
  user_data_replace_on_change = true

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    # Amazon Linux 2023 does NOT ship the iptables CLI — install it FIRST. (If you
    # call iptables before installing it, `set -e` aborts and NAT silently fails.)
    dnf install -y iptables iptables-services
    # Turn the box into a router:
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nat.conf
    # iptables-services ships a default ruleset whose FORWARD chain REJECTs traffic.
    # Clear it and default FORWARD to ACCEPT so the VPC can route THROUGH this box.
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD
    # Masquerade outbound traffic on the primary network interface:
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    # Persist the iptables rules across reboots:
    service iptables save
    systemctl enable iptables
  EOF
  )

  tags = { Name = "${var.project}-nat" }
}

# Send the PRIVATE route table's default route through the NAT instance.
# We look up the private route table (created in Phase 1) by its Name tag, so we
# don't have to modify the network stack. It has no other 0.0.0.0/0 route, so
# there's no conflict.
data "aws_route_table" "private" {
  filter {
    name   = "tag:Name"
    values = ["${var.project}-private-rt"]
  }
  vpc_id = data.terraform_remote_state.network.outputs.vpc_id
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_instance ? 1 : 0
  route_table_id         = data.aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[0].primary_network_interface_id
}
```

> 🧠 **`source_dest_check = false` is the one thing everyone forgets.** By default
> EC2 drops packets whose destination IP isn't the instance itself — a sane
> anti-spoofing default. A NAT *must* forward such packets, so we disable the
> check. Forget this and egress silently fails.

> 🧠 **The route is what activates NAT.** Adding `0.0.0.0/0 →` the NAT instance's
> network interface to the *private* route table means private subnets now send
> internet-bound traffic to the NAT, which masquerades it out through its public
> IP. Replies come back the same way. The instances still have **no public IP** —
> they're reachable only via the ALB.

> ⚠️ **Prerequisite the NAT exposes: the private NACL must allow return traffic.**
> The Phase 1 **private NACL** (Doc 08) only allowed inbound from `10.0.0.0/16`.
> That was fine while the subnets had no egress — but the moment traffic routes
> out through the NAT, the **replies arrive from public IPs on ephemeral ports**
> and the NACL (stateless!) silently drops them. The symptom is brutal to debug:
> the route, SGs, and `source_dest_check` all look perfect, the NAT's `MASQUERADE`
> counter climbs, but connections hang at `SYN_RECV` and `dnf`/`docker pull` time
> out. **Fix in `terraform/network/nacls.tf`** — add to the `private` NACL:
> ```hcl
>   ingress {
>     rule_no    = 110
>     action     = "allow"
>     protocol   = "tcp"
>     from_port  = 1024
>     to_port    = 65535
>     cidr_block = "0.0.0.0/0"
>   }
> ```
> then `cd terraform/network && terraform apply`. (The *public* NACL already had
> this rule; the private one was missing it.)

---

## 8. `iam.tf` — let instances pull from ECR and read the secret

Append to `terraform/compute/iam.tf`:

```hcl
# Pull images from ECR (AWS-managed read-only policy).
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Read ONLY the CloudCare DB secret — least privilege, scoped to one ARN.
data "aws_iam_policy_document" "read_db_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.terraform_remote_state.database.outputs.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "read_db_secret" {
  name   = "${var.project}-read-db-secret"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.read_db_secret.json
}
```

> 🧠 **Least privilege in action.** We don't grant `secretsmanager:*` on `*`. We
> grant exactly `GetSecretValue` on exactly the one secret ARN. If this instance
> is ever compromised, the blast radius is "can read one DB secret", not "can read
> every secret in the account". This is the single most important habit to show in
> a security-minded interview.

---

## 9. `launch-template.tf` — run the real image

Replace the placeholder `user_data` from Doc 09 with this (the rest of the launch
template — instance profile, security group, IMDSv2, tags — stays the same):

```hcl
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    REGION="${var.aws_region}"
    ACCOUNT="${data.aws_caller_identity.current.account_id}"
    REPO="$${ACCOUNT}.dkr.ecr.$${REGION}.amazonaws.com/${var.project}-backend"

    # The AWS CLI and Python ship with Amazon Linux 2023. Add Docker + jq.
    dnf install -y docker jq
    systemctl enable --now docker

    # Authenticate Docker to ECR and pull our image.
    aws ecr get-login-password --region "$REGION" \
      | docker login --username AWS --password-stdin "$${ACCOUNT}.dkr.ecr.$${REGION}.amazonaws.com"
    docker pull "$${REPO}:latest"

    # Read DB credentials from Secrets Manager (allowed by the instance role).
    CREDS=$(aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id "${var.project}/db/credentials" --query SecretString --output text)

    # Run the container, injecting the DB connection as environment variables.
    docker run -d --restart always -p 8000:8000 \
      -e DB_HOST="$(echo "$CREDS" | jq -r .host)" \
      -e DB_PORT="$(echo "$CREDS" | jq -r .port)" \
      -e DB_NAME="$(echo "$CREDS" | jq -r .dbname)" \
      -e DB_USER="$(echo "$CREDS" | jq -r .username)" \
      -e DB_PASSWORD="$(echo "$CREDS" | jq -r .password)" \
      "$${REPO}:latest"
  EOF
  )
```

> ⚠️ **`$${...}` vs `${...}` in this heredoc.** Terraform interpolates `${...}`
> (so `${var.aws_region}` and `${data.aws_caller_identity...}` are filled in by
> Terraform). To pass a literal `$` to the *shell* (e.g. `$${ACCOUNT}` → `${ACCOUNT}`
> in the script), you **double** the dollar sign. Mixing these up is the most
> common templating bug here.

> 🔒 **A real hardening note.** We inject the password as a container env var,
> which is visible via `docker inspect` on the box. Because we shipped `boto3` in
> Doc 12, a more secure pattern is to have the *app* call Secrets Manager directly
> with its role and never put the password in an env var. We keep the env-var
> approach for clarity; mention the boto3-in-app alternative in interviews.

---

## 10. `alb.tf` — health-check the real endpoint

Update the target group's health check `path` from `/` to `/health`:

```hcl
  health_check {
    path                = "/health" # the real app's cheap health endpoint
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
```

---

## 11. Apply, roll out, and verify

```bash
cd terraform/compute
terraform fmt
terraform validate
terraform plan
```

Expect roughly **`Plan: 5 to add, 2 to change, 0 to destroy.`** — NAT instance +
NAT SG + NAT route + the two IAM attachments add; the launch template (new
`user_data`) and target group (new health path) change. Changing the launch
template triggers the ASG's **instance refresh** (from Doc 09), which rolls
replacement instances that boot with the real app.

```bash
terraform apply   # type "yes"
```

Give it a few minutes (NAT boots → app instance boots → installs Docker → pulls
image → starts). Then:

```bash
# Targets should go healthy on /health:
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --query 'TargetHealthDescriptions[].TargetHealth.State' --output text

# Hit the REAL API through the ALB:
ALB=$(terraform output -raw alb_dns_name)
curl "http://$ALB/health"
curl -X POST "http://$ALB/patients" -H "Content-Type: application/json" \
  -d '{"full_name":"Asha Perera","date_of_birth":"1990-04-12","phone":"0771234567"}'
curl "http://$ALB/patients"
```

🎉 That last `curl` proves the **entire stack**: internet → ALB (public) → EC2
(private) → **RDS (private)** → back. A patient you create is written to the
PostgreSQL database from Phase 3, by an app that read its password from Secrets
Manager using its IAM role. That's the whole 3-tier architecture, working.

> 🧠 **If targets stay unhealthy** it's almost always boot-time egress. Work down
> this list (in the order they actually bit us):
> 1. **NACL return traffic** — the private NACL must allow inbound TCP 1024–65535
>    from `0.0.0.0/0` (see the ⚠️ box in §7). Without it everything *looks* right
>    but connections hang at `SYN_RECV`.
> 2. **NAT not forwarding** — confirm the NAT is running, `source_dest_check` is
>    false, and the private route table shows `0.0.0.0/0 → eni-...`. On AL2023 the
>    NAT's `iptables` must be installed *before* use and the `FORWARD` policy set
>    to `ACCEPT` (see §7).
> 3. **Instance refresh didn't auto-trigger** — the ASG pins the launch template to
>    `$Latest`, so publishing a new version doesn't change the ASG's tracked config
>    and the rolling refresh never fires on its own. Kick it manually:
>    `aws autoscaling start-instance-refresh --auto-scaling-group-name $(terraform output -raw asg_name) --preferences '{"MinHealthyPercentage":0}'`.
>
> **To debug from inside a private instance** (no SSH key, no public IP): use SSM
> Session Manager / Run Command — the AL2023 SSM document is **`AWS-RunShellScript`**
> (not `AWS-RunShellCommand`). The instance role already has `AmazonSSMManagedInstanceCore`.
> Useful checks on the box: `sudo docker ps -a`, `sudo docker logs <id>`,
> `sudo tail -50 /var/log/cloud-init-output.log`. Or read the boot log without any
> agent: `aws ec2 get-console-output --instance-id <id> --latest`.

---

## 12. 💰 Cost & teardown (important — most resources running yet)

You now have the **most** running at once: NAT `t3.micro` + app `t3.micro` + ALB
(+ the RDS from Phase 3 if you left it up).

| Resource | Note |
|----------|------|
| NAT instance (t3.micro) | counts against the 750 free hours alongside the app instance |
| App instance (t3.micro) | 1 instance fits 750 hrs; NAT makes it **two** micros → watch it |
| ALB | 750 hrs free for 12 months |
| ECR storage | tiny, within 500 MB free |

> 💰 **Two `t3.micro` (app + NAT) running 24/7 ≈ 1,460 hrs → over the 750 free.**
> So **don't leave this up**. When you finish a session:
> ```bash
> terraform destroy   # in terraform/compute/  (removes NAT, ASG, ALB, ECR, IAM)
> # and, if it's up:
> cd ../database && terraform destroy
> ```
> Leave only `network/` and `bootstrap/`. To resume: re-apply database, re-apply
> compute, re-push the image if the repo was emptied, start an instance refresh.

---

## ✅ Checkpoint

You're ready for Doc 14 when:

- [ ] The backend image is in ECR and the ASG instances run it.
- [ ] ALB targets are **healthy** on `/health`.
- [ ] `curl http://<alb>/patients` (POST then GET) round-trips through the app to
      **RDS** and back.
- [ ] You can explain: NAT instance vs NAT Gateway, why `source_dest_check=false`,
      and how the instance reads the DB password without any stored credentials.

Next: **[14 — The React Frontend](14-application-react-frontend.md)** — a small
React SPA for patients/appointments that calls this API, run locally and built for
production (we serve it globally via S3 + CloudFront in Phase 5).
