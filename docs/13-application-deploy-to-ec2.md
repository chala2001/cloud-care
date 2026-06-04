# 13 — Deploy the Backend to the EC2 App Tier

> **Goal of this doc:** run the real FastAPI image (from Doc 12) on the **private**
> EC2 app tier and serve it through the Phase 2 ALB. To do that we solve the
> egress problem we deferred twice: we add a **NAT instance** so private
> instances can pull the image, store the image in **ECR**, let instances read the
> **DB password from Secrets Manager** via their IAM role, and point the ALB
> health check at the real `/health`.

⏱️ Time: ~90 minutes. 💰 Cost: this runs a NAT `t3.micro` + an app `t3.micro` +
the ALB — watch your hours and **destroy after the lab** (§12).

This is the integration doc — everything from Phases 1–4 comes together here.

---

## 0. Beginner read-me first — vocabulary in one place

This doc introduces several brand-new ideas (NAT, ECR, source/dest-check,
iptables MASQUERADE, Terraform-vs-shell interpolation in heredocs). Re-read
this card any time something feels foreign.

| Word | Plain-English meaning |
|---|---|
| **Egress** | **Outbound** traffic (leaving the subnet/VPC). The opposite of *ingress*. |
| **NAT** (Network Address Translation) | A trick where a router rewrites packets' source IP so private machines can reach the internet using **one shared public IP**, then translates the replies back. |
| **NAT instance** | A regular EC2 you configure to do NAT yourself (DIY). Cheap; single AZ; you own its uptime. |
| **NAT Gateway** | AWS's managed NAT product. Highly available, scales automatically. ~$32/mo + data. |
| **VPC interface endpoint** | A private tunnel from your VPC straight to one AWS service (no internet hop). ~$0.01/hr each. The "no-NAT" production alternative. |
| **ECR** (Elastic Container Registry) | AWS's private Docker registry. You push images here; instances pull from here. |
| **Repository URL** | The address of an ECR repo, e.g. `670794226080.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-backend`. |
| **Image tag** | A label on an image (`:latest`, `:v1.2`). The same image can have many tags. |
| **MUTABLE / IMMUTABLE tags** | MUTABLE = you can push a new image to the same tag (`:latest` moves). IMMUTABLE = each tag is permanent (safer for production). |
| **Image scan** | ECR scans pushed images for known CVEs (free, on push). |
| **`force_delete = true`** | On ECR repos, allows `terraform destroy` even if the repo still contains images. Lab-friendly. |
| **`source_dest_check`** | An EC2 setting that drops packets whose dst isn't the instance — anti-spoofing. **Must be `false` for a NAT instance.** |
| **`ip_forward = 1`** | A Linux kernel switch that allows the box to forward packets between network interfaces. Off by default. |
| **`iptables MASQUERADE`** | A Linux NAT rule: "rewrite the source IP of forwarded packets to my own IP." This is what makes the NAT instance work. |
| **`FORWARD` chain** | An iptables chain that decides whether to allow packets passing **through** the box (not destined to it). AL2023's default is REJECT — we change to ACCEPT. |
| **Route table entry** | The line that activates NAT: in the **private** route table, `0.0.0.0/0 → eni-of-NAT-instance`. |
| **`primary_network_interface_id`** | The ID of the EC2's main ENI (Elastic Network Interface). Route entries can target this directly. |
| **Stateless NACL return rule** | The inbound NACL rule for ephemeral ports (1024-65535). Required once egress exists, or replies are dropped at the subnet edge. |
| **Heredoc `${...}` vs `$${...}`** | In a Terraform heredoc: `${expr}` = **Terraform** evaluates and substitutes; `$${expr}` = literal `${expr}` is written into the script (so the shell evaluates it at boot). |
| **`docker login`** | One-time auth handshake that tells your local Docker daemon the credentials to pull/push from a private registry. |
| **`docker pull` / `docker push`** | Download / upload an image from/to a registry. |
| **`docker run -d`** | Start a container in the background ("detached"). |
| **Instance refresh** | The ASG's rolling-replacement mechanism — replaces existing EC2s with new ones built from the latest launch-template version. |
| **`AWS-RunShellScript`** | The SSM document name for running arbitrary shell commands on an instance without SSH. |
| **`get-console-output`** | An EC2 API call that returns the serial-console log of an instance — useful when even SSM isn't reachable. |

Now the problem this doc solves.

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

### What NAT actually does, in one diagram

```
   private EC2 (10.0.10.5)  ─►  packet src=10.0.10.5  dst=registry-1.docker.io
                                                          │
                                  (private route table:  │
                                   0.0.0.0/0 → NAT)      │
                                                          ▼
   NAT instance (public IP 13.234.x.x in public subnet)
                              │
                              ▼  iptables MASQUERADE rewrites SRC →
                              src=13.234.x.x  dst=registry-1.docker.io
                              │
                              ▼  (public route table: 0.0.0.0/0 → IGW)
                          Internet Gateway → internet

   Reply path is exactly reverse — NAT remembers the mapping and
   restores src=registry, dst=10.0.10.5 on the way back in.
```

Three pieces have to be true:
1. The NAT instance can **forward** packets that aren't for itself (`source_dest_check=false`, `ip_forward=1`, `iptables MASQUERADE`).
2. The **private route table** sends `0.0.0.0/0` at the NAT's ENI.
3. The **private NACL** allows return traffic on **ephemeral ports** (1024–65535).

Miss any one and outbound silently breaks. We handle all three.

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

### Order of operations (matters a lot)

The order matters: **create ECR and push the image first**, *then* roll out the
new launch template — otherwise instances boot and find no image to pull. And
apply the **network NACL** change before (or with) the rollout, or the new
instances boot with no working egress.

```
1. terraform apply  (network/)      — add the NACL return-traffic rule
2. terraform apply  (compute/)      — create the ECR repo (just the repo)
3. docker build / tag / push        — populate the repo with :latest
4. terraform apply  (compute/)      — create NAT + IAM grants + new user_data
5. wait for instance refresh        — new EC2s boot, install Docker, pull, run
6. curl through the ALB             — end-to-end test
```

> 🧠 **Why this order matters:** if you push the new launch template before the
> image exists in ECR, the boot script's `docker pull` fails with "manifest
> unknown" and the EC2 sits there with nothing listening on :8000 → ALB marks it
> unhealthy → 502s. You've debugged exactly this case before.

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

### Walk-through — line by line

| Line | Meaning |
|---|---|
| `resource "aws_ecr_repository" "backend"` | Create a private container registry; nickname `backend`. |
| `name = "${var.project}-backend"` | The repo's name → `cloudcare-backend`. Combined with account + region this becomes the **repository URL**: `670794226080.dkr.ecr.ap-south-1.amazonaws.com/cloudcare-backend`. |
| `image_tag_mutability = "MUTABLE"` | You can push a new image to the same tag (`:latest`). Easy for development. **Production usually picks `IMMUTABLE`** — each tag locked once pushed; you push new versions like `:1.2.3`. |
| `image_scanning_configuration.scan_on_push = true` | Every pushed image is scanned for known CVEs. **Free.** Results show in the ECR console. |
| `force_delete = true` | If the repo has images, `terraform destroy` would normally refuse to delete it. `force_delete = true` overrides. **Lab-friendly only** — production would never set this (you don't want a careless apply to nuke shipped images). |

### Apply just the ECR repo first

```bash
cd terraform/compute
terraform apply   # creates the ECR repo (1 to add)
```

**Why apply now (before adding NAT etc)?** Because the next step (building +
pushing the image) needs the repo to **exist**. We're building incrementally so
each step is debuggable in isolation.

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

### Each command and flag, decoded

**Step 0 — set up shell variables:**

| Command | Meaning |
|---|---|
| `export AWS_PROFILE=cloudcare` | Tell `aws` CLI which credentials profile to use. |
| `REGION=ap-south-1` | A shell variable holding the AWS region. |
| `ACCOUNT=$(aws sts get-caller-identity --query Account --output text)` | Run `aws sts get-caller-identity`, pull the `Account` field from the JSON response, store the result. `$()` is shell substitution. |
| `REPO=$(cd terraform/compute && terraform output -raw ecr_repository_url)` | Subshell: `cd` into the compute folder and print the `ecr_repository_url` output **raw** (no quotes). Capture as `REPO`. |

**Step 1 — authenticate Docker to ECR:**

```bash
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
```

| Piece | Meaning |
|---|---|
| `aws ecr get-login-password --region $REGION` | Asks AWS for a **temporary password** valid for 12 hours, scoped to ECR in `$REGION`. |
| `\|` | Shell pipe — feed the previous command's stdout into the next command's stdin. |
| `docker login --username AWS --password-stdin "<registry>"` | Authenticate to that registry. Username is always literally `AWS` for ECR. `--password-stdin` reads the password from stdin (safer than echoing it on the command line). |

After this, your local Docker daemon has cached credentials for the registry.

**Step 2 — build + tag + push:**

| Command | Meaning |
|---|---|
| `cd app/backend` | Change into the directory with the `Dockerfile`. |
| `docker build -t cloudcare-backend .` | Build the image using the `Dockerfile` in `.` (current dir). `-t name` tags the result locally as `cloudcare-backend:latest`. |
| `docker tag cloudcare-backend:latest "$REPO:latest"` | Add a **second tag** to the same image — the full ECR repo URL, also `:latest`. Same image, two names. |
| `docker push "$REPO:latest"` | Upload the image (under its ECR-tagged name) to the registry. |

Confirm it landed:

```bash
aws ecr list-images --repository-name cloudcare-backend --output table
```

This lists images and their tags. You should see at least one row with
`imageTag = latest`. If the table is empty, the push didn't succeed.

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

A `bool` variable defaulting to `true`. Used by `nat.tf` with `count` to
conditionally create the NAT resources.

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

### Walk-through — the two new data sources

| Block | Meaning |
|---|---|
| `data "aws_caller_identity" "current"` | Looks up info about the AWS identity Terraform is running as. We use `.account_id` to build the ECR URL string in user_data. No arguments needed — it just asks "who am I?". |
| `data "terraform_remote_state" "database"` | Same pattern as the network read in Doc 09 — but this time pointing at the **database** stack's state file. We need its `db_secret_arn` output for the IAM grant in §8. |

After applying:

| Reference | Returns |
|---|---|
| `data.aws_caller_identity.current.account_id` | `"670794226080"` |
| `data.terraform_remote_state.database.outputs.db_secret_arn` | the Secrets Manager ARN |

---

## 7. `nat.tf` — the NAT instance and its route

This is the most concept-dense file in the doc. Three resources + one data
source, working together to turn one EC2 into a working NAT gateway.

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

### Block 1 — the NAT security group

```hcl
resource "aws_security_group" "nat" {
  count       = var.enable_nat_instance ? 1 : 0
  ...
}
```

| Field | Meaning |
|---|---|
| `count = var.enable_nat_instance ? 1 : 0` | Ternary: create **1** SG if the toggle is `true`, **0** if `false`. This is how you make a resource optional. References to it use index `[0]`. |
| `vpc_id = ...network.outputs.vpc_id` | Lives in the same VPC. |
| `ingress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = [vpc_cidr] }` | Allow **all** ports + protocols, but only from **inside the VPC** (`10.0.0.0/16`). The NAT shouldn't accept random internet connections — only forward what the VPC sends it. |
| `egress { ... cidr_blocks = ["0.0.0.0/0"] }` | Allow all outbound to the internet. (This is how forwarded traffic actually leaves.) |

### Block 2 — the NAT EC2 itself

This block has **several** unusual settings — each there for a specific reason.

#### Identity & placement

| Line | Meaning |
|---|---|
| `count = var.enable_nat_instance ? 1 : 0` | Conditional creation. |
| `ami = data.aws_ami.al2023.id` | Reuse the Amazon Linux 2023 AMI lookup from Doc 09. |
| `instance_type = "t3.micro"` | Free-tier micro. **In `ap-south-1`, use `t3.micro`, NOT `t2.micro`** — the latter returns "not eligible for Free Tier" at apply time in this region. |
| `subnet_id = ...public_subnet_ids[0]` | **PUBLIC subnet** — the NAT needs a public IP and a route to the IGW. Index `[0]` = AZ-a. (Single-AZ; one node, no HA.) |
| `associate_public_ip_address = true` | Auto-assign a public IP at boot. Without this, the NAT can't actually reach the internet. |
| `vpc_security_group_ids = [aws_security_group.nat[0].id]` | Attach the NAT SG above. |

#### The two NAT-specific settings

```hcl
source_dest_check = false
user_data_replace_on_change = true
```

| Setting | Meaning |
|---|---|
| `source_dest_check = false` | **The one thing everyone forgets.** By default EC2 *drops* packets whose dst IP isn't the instance itself — sane anti-spoofing. A NAT must forward such packets, so we disable the check. |
| `user_data_replace_on_change = true` | `user_data` runs **only on first boot.** If you edit the script, an in-place update *won't* re-run it — the instance keeps the old NAT setup. This setting forces Terraform to **replace** the instance whenever the script changes, so the new logic takes effect. |

> 🧠 **`source_dest_check = false` is the one thing everyone forgets.** By default
> EC2 drops packets whose destination IP isn't the instance itself — a sane
> anti-spoofing default. A NAT *must* forward such packets, so we disable the
> check. Forget this and egress silently fails.

#### The user_data script (turning the box into a router)

```bash
#!/bin/bash
set -euo pipefail

dnf install -y iptables iptables-services

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nat.conf

iptables -P FORWARD ACCEPT
iptables -F FORWARD

IFACE=$(ip route | awk '/default/ {print $5; exit}')
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

service iptables save
systemctl enable iptables
```

| Line | Meaning |
|---|---|
| `#!/bin/bash; set -euo pipefail` | Strict bash mode (same as Doc 09). |
| `dnf install -y iptables iptables-services` | **Critical.** AL2023 doesn't ship the `iptables` CLI by default. **Install it first** — if you call `iptables` before installing it, `set -e` aborts and the NAT silently fails. |
| `sysctl -w net.ipv4.ip_forward=1` | Turn on kernel packet-forwarding **for this session**. Without this, the box drops packets it should forward. |
| `echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nat.conf` | Persist the setting **across reboots**. |
| `iptables -P FORWARD ACCEPT` | Set the default policy of the FORWARD chain to ACCEPT (the AL2023 default is REJECT, which blocks NAT). |
| `iptables -F FORWARD` | Flush any existing FORWARD rules from the shipped default ruleset. |
| `IFACE=$(ip route \| awk '/default/ {print $5; exit}')` | Find the name of the primary network interface (e.g. `ens5`). The `ip route` command lists the default route; `awk` pulls field 5 (interface name); `exit` stops after the first match. |
| `iptables -t nat -F POSTROUTING` | Clear the NAT-table POSTROUTING chain. |
| `iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE` | Append a rule: *"for any packet leaving via `$IFACE`, rewrite its source IP to mine."* **This is the NAT.** |
| `service iptables save; systemctl enable iptables` | Persist current iptables rules to disk and enable the service so it restores them on reboot. |

After the script runs, this box is a working NAT gateway. The Linux kernel
forwards packets between interfaces; iptables MASQUERADE rewrites their source
IP; the box's own public IP becomes the "outside-world" identity for everything
in the VPC.

### Block 3 — look up the private route table by tag

```hcl
data "aws_route_table" "private" {
  filter {
    name   = "tag:Name"
    values = ["${var.project}-private-rt"]
  }
  vpc_id = data.terraform_remote_state.network.outputs.vpc_id
}
```

| Line | Meaning |
|---|---|
| `data "aws_route_table" "private"` | **Look up** an existing route table by filter — don't create. |
| `filter { name = "tag:Name", values = ["cloudcare-private-rt"] }` | Find the route table with `Name = cloudcare-private-rt` (the one we tagged in Phase 1). |
| `vpc_id = ...vpc_id` | Constrain to our VPC. |

**Why look it up instead of importing or modifying the network stack?** The
route table lives in the **network folder's** state, which we don't want to
modify from here (cross-stack writes are messy). Looking it up by tag lets us
add a *route* to it from this stack without touching that one's resources.

### Block 4 — the route entry that activates NAT

```hcl
resource "aws_route" "private_nat" {
  count                  = var.enable_nat_instance ? 1 : 0
  route_table_id         = data.aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[0].primary_network_interface_id
}
```

| Line | Meaning |
|---|---|
| `route_table_id = data.aws_route_table.private.id` | Add the route to the private route table we looked up. |
| `destination_cidr_block = "0.0.0.0/0"` | Match all internet-bound traffic. |
| `network_interface_id = aws_instance.nat[0].primary_network_interface_id` | **Send those packets to the NAT instance's ENI.** Not its public IP — its ENI inside the VPC. AWS routes to ENIs, not IPs. |

After this resource is created, the private subnets have a working egress
path. The route table now contains:

```
10.0.0.0/16  → local        (implicit, AWS-managed)
0.0.0.0/0    → eni-of-NAT   (this resource)
```

> 🧠 **The route is what activates NAT.** Adding `0.0.0.0/0 →` the NAT instance's
> network interface to the *private* route table means private subnets now send
> internet-bound traffic to the NAT, which masquerades it out through its public
> IP. Replies come back the same way. The instances still have **no public IP** —
> they're reachable only via the ALB.

### ⚠️ The NACL fix the NAT exposes

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

### Walk-through

#### Block 1 — attach the AWS-managed ECR-read policy

```hcl
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
```

Adds the **AmazonEC2ContainerRegistryReadOnly** managed policy to the existing
app role. Lets the instance:

- `ecr:GetAuthorizationToken` (for `docker login`)
- `ecr:BatchGetImage` / `ecr:GetDownloadUrlForLayer` (for `docker pull`)

Without it, `docker login` fails with "no basic auth credentials" or `docker
pull` returns 403.

#### Block 2 — write a custom policy: just `GetSecretValue` on just our secret

```hcl
data "aws_iam_policy_document" "read_db_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.terraform_remote_state.database.outputs.db_secret_arn]
  }
}
```

| Line | Meaning |
|---|---|
| `actions = ["secretsmanager:GetSecretValue"]` | **Only** the read action. Not list, not put, not rotate, not delete. |
| `resources = [...db_secret_arn]` | **Only** the one specific secret. Not `*`. The ARN comes from the database stack's outputs. |

This is the smallest possible permission that makes the app work.

#### Block 3 — attach the custom policy

```hcl
resource "aws_iam_role_policy" "read_db_secret" {
  name   = "${var.project}-read-db-secret"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.read_db_secret.json
}
```

`aws_iam_role_policy` (singular, no `_attachment`) is the resource type for
**inline** policies — attached directly to one role, not reusable elsewhere.
That fits a per-app, per-secret policy like this one.

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

### The most important syntax: `${...}` vs `$${...}`

> ⚠️ **`$${...}` vs `${...}` in this heredoc.** Terraform interpolates `${...}`
> (so `${var.aws_region}` and `${data.aws_caller_identity...}` are filled in by
> Terraform). To pass a literal `$` to the *shell* (e.g. `$${ACCOUNT}` → `${ACCOUNT}`
> in the script), you **double** the dollar sign. Mixing these up is the most
> common templating bug here.

Concrete example — what Terraform renders vs what hits the shell:

```hcl
REGION="${var.aws_region}"          ← Terraform substitutes → REGION="ap-south-1"
REPO="$${ACCOUNT}.dkr...$${REGION}" ← Terraform substitutes → REPO="${ACCOUNT}.dkr...${REGION}"
                                       (the shell then expands at boot)
```

Rule of thumb:
- **`${var.X}` / `${data.X}` / `${local.X}`** = Terraform fills in **at apply time**.
- **`$${VAR}`** = a literal `${VAR}` in the script; **shell fills in at boot**.
- **`$(cmd)`** = shell command substitution. No Terraform involvement. Pass through as-is.

### Walk-through — the boot script

#### Build the ECR URL from variables
```bash
REGION="${var.aws_region}"
ACCOUNT="${data.aws_caller_identity.current.account_id}"
REPO="$${ACCOUNT}.dkr.ecr.$${REGION}.amazonaws.com/${var.project}-backend"
```

After Terraform substitution, the third line becomes:
`REPO="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/cloudcare-backend"` — which the
shell expands at boot.

#### Install Docker + jq
```bash
dnf install -y docker jq
systemctl enable --now docker
```

| Command | Meaning |
|---|---|
| `dnf install -y docker jq` | Install Docker (container engine) and `jq` (JSON CLI parser). `-y` answers "yes" to confirmations automatically. |
| `systemctl enable --now docker` | Start the Docker daemon immediately AND on every future boot. |

#### Authenticate Docker to ECR + pull
```bash
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$${ACCOUNT}.dkr.ecr.$${REGION}.amazonaws.com"
docker pull "$${REPO}:latest"
```

Same pattern as the manual login in §4, just run by the instance using its
IAM role's credentials (no `aws configure` needed — the role provides creds via
IMDS).

#### Fetch credentials from Secrets Manager
```bash
CREDS=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "${var.project}/db/credentials" --query SecretString --output text)
```

`aws secretsmanager get-secret-value` returns a JSON like
`{"SecretString":"{\"username\":\"...\", ...}", ...}`. `--query SecretString
--output text` extracts just the inner JSON string. Capture into `CREDS`.

#### Run the container with the credentials as env vars
```bash
docker run -d --restart always -p 8000:8000 \
  -e DB_HOST="$(echo "$CREDS" | jq -r .host)" \
  -e DB_PORT="$(echo "$CREDS" | jq -r .port)" \
  ...
```

| Flag | Meaning |
|---|---|
| `-d` | **Detached** — run in the background, return prompt immediately. |
| `--restart always` | If the container crashes, Docker auto-restarts it. Same idea as the systemd `Restart=always` from Doc 09. |
| `-p 8000:8000` | Publish container's port 8000 → host's port 8000. The ALB target group hits the host on 8000. |
| `-e KEY=VALUE` | Set environment variable `KEY=VALUE` inside the container. |
| `"$(echo "$CREDS" \| jq -r .host)"` | Shell substitution: pipe `$CREDS` through `jq -r .host` to extract the `host` field raw (without JSON quotes). |

After this command, the container is alive, listening on `:8000`, with the DB
connection populated from Secrets Manager.

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

The placeholder from Doc 09 answered `GET /` with 200 (it answered any path
with 200). The real app has a dedicated **`/health`** route designed for
exactly this — fast, dependency-free, returns `{"status":"ok"}`. Changing the
check path makes the ALB hit the right thing.

> 💡 **Why a dedicated health path matters.** If the ALB hit `/patients`
> (a real route), every health check would run a DB query — pounding the DB
> with ~4 queries per second per instance. A dedicated `/health` is free.

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
image → starts).

### Watch the rollout

```bash
# 1. Watch the target health flip:
watch -n 5 'aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --query "TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Desc:TargetHealth.Description}" \
  --output table'
```

You'll see something like:
```
draining   (old placeholder instance being removed)
initial    (new instance just registered)
unhealthy  (Docker still installing / image pulling)
healthy    (✅ container is up and answering /health)
```

The first new instance takes ~2-4 minutes to go healthy because user_data
installs Docker and pulls the image. Subsequent refreshes are similar.

### Hit the real API through the ALB

```bash
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

### When (not if) something is unhealthy

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
> 4. **ECR repo is empty** — boot logs show `manifest unknown`. Re-run §4 build+push.
> 5. **App route mismatch** — `/health` returns 404 means the FastAPI handler is
>    commented out / missing. Check `main.py`.
>
> **To debug from inside a private instance** (no SSH key, no public IP): use SSM
> Session Manager / Run Command — the AL2023 SSM document is **`AWS-RunShellScript`**
> (not `AWS-RunShellCommand`). The instance role already has `AmazonSSMManagedInstanceCore`.
> Useful checks on the box: `sudo docker ps -a`, `sudo docker logs <id>`,
> `sudo tail -50 /var/log/cloud-init-output.log`. Or read the boot log without any
> agent: `aws ec2 get-console-output --instance-id <id> --latest`.

### Concrete diagnostic recipe

If a target is unhealthy, run these in order:

```bash
# A. Get the instance id
INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cloudcare-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# B. Run a bundle of diagnostics on it via SSM (read-only, safe)
CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "echo === containers ===",
    "sudo docker ps -a",
    "echo === container logs ===",
    "sudo docker logs $(sudo docker ps -aq | head -1) 2>&1 | tail -30",
    "echo === cloud-init tail ===",
    "sudo tail -40 /var/log/cloud-init-output.log",
    "echo === local curl test ===",
    "curl -is http://127.0.0.1:8000/health | head -10"
  ]' --query 'Command.CommandId' --output text)

# C. Wait + read the output
aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" \
  --query 'StandardOutputContent' --output text
```

That gives you: are containers running, what do their logs say, what did boot
do, does the app respond locally? 80% of issues become obvious from this.

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

## 13. Plain-English summary (what you just built)

If asked to explain Phase 4 part 2:

1. **One NAT instance** (`cloudcare-nat`, t3.micro) in a public subnet —
   `source_dest_check = false`, `ip_forward = 1`, `iptables MASQUERADE`. The
   **route** added to the private route table (`0.0.0.0/0 → NAT's ENI`) is what
   activates it. Now the private subnets have outbound internet.
2. **One ECR repo** (`cloudcare-backend`) — private Docker registry with
   image-scanning on push.
3. **Image pipeline**: laptop → `docker build` → `docker tag` → `docker push` to
   ECR. (Phase 8 automates this via GitHub Actions.)
4. **Two new IAM grants** on the app role:
   - **ECR-read** (AWS-managed) so `docker pull` works.
   - **Secrets-Manager-`GetSecretValue` scoped to one ARN** — least privilege.
5. **New user_data** in the launch template: install Docker, login to ECR,
   pull image, fetch creds from Secrets Manager, run container with creds as
   env vars.
6. **ALB health check** moved from `/` to `/health` (the real app's dedicated
   endpoint).
7. **NACL fix** in the network stack: inbound ephemeral-port allow on the
   private NACL — required as soon as private subnets have outbound through NAT.
8. **End to end** verified: `curl POST /patients` writes a row to RDS via the
   FastAPI app, with no credentials hardcoded anywhere.

---

## 14. Interview soundbites

- **NAT-instance vs NAT Gateway** — *"NAT Gateway is AWS-managed, HA across AZs,
  and ~$32/mo + data. A NAT instance is a t3.micro you configure yourself —
  free-tier-friendly, single AZ, you own the patching. For a lab the instance
  is right; for production the gateway is. Best of all is VPC interface
  endpoints for AWS services, removing the need for NAT entirely."*

- **The 3 NAT must-haves** — *"On the box: `source_dest_check=false`,
  `ip_forward=1`, and `iptables MASQUERADE` on the egress interface. On the
  network: a `0.0.0.0/0` route in the private route table pointing at the NAT's
  ENI. And in the stateless NACL: an ephemeral-port (1024–65535) ingress rule
  for the return traffic. Miss any one and outbound silently breaks."*

- **No credentials on disk** — *"The DB password isn't on the instance, in the
  image, in the launch template, or in git. The instance reads it from Secrets
  Manager at boot using its IAM role's `GetSecretValue` permission scoped to
  exactly one ARN. The container then runs with those values as env vars."*

- **Least privilege** — *"The IAM role grants `secretsmanager:GetSecretValue`
  on a specific ARN, not `secretsmanager:*` on `*`. If the instance is ever
  compromised, the blast radius is reading **one** DB secret — not every
  secret in the account."*

- **Image lifecycle** — *"We push a tagged image to ECR. The ASG launches
  instances from a launch template; user_data pulls `:latest` from ECR. A new
  image + an instance refresh = zero-downtime deploys (`MinHealthyPercentage`
  controls the safety threshold). CI/CD would automate this whole chain."*

- **`${} vs $${}` in heredocs** — *"In a Terraform heredoc, `${expr}` is
  Terraform interpolation at apply time, `$${expr}` writes a literal `${expr}`
  the shell evaluates at boot. Mixing these up is the most common templating
  bug when scripts have variables of their own."*

---

## ✅ Checkpoint

You're ready for Doc 14 when:

- [ ] The backend image is in ECR and the ASG instances run it.
- [ ] ALB targets are **healthy** on `/health`.
- [ ] `curl http://<alb>/patients` (POST then GET) round-trips through the app to
      **RDS** and back.
- [ ] You can explain: NAT instance vs NAT Gateway, why `source_dest_check=false`,
      and how the instance reads the DB password without any stored credentials.
- [ ] You can read every line of `nat.tf` and the new `user_data` and explain it
      in plain English.

Next: **[14 — The React Frontend](14-application-react-frontend.md)** — a small
React SPA for patients/appointments that calls this API, run locally and built for
production (we serve it globally via S3 + CloudFront in Phase 5).
