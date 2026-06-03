# 10 — Compute: the Application Load Balancer

> **Goal of this doc:** put an internet-facing **Application Load Balancer (ALB)**
> in your public subnets, point it at the Auto Scaling Group from Doc 09 via a
> **target group** on port 8000, and finally reach CloudCare end-to-end with a
> plain `curl`. This completes **Phase 2 — Compute**.

⏱️ Time: ~45–60 minutes. 💰 Cost: the ALB has **750 free hours/month** for 12
months (≈ one ALB running all month), but **destroy it after the lab** — see §10.

We keep working in the **same folder**, `terraform/compute/`, adding one new file
and making one small edit to `asg.tf`.

---

## 0. Beginner read-me first — vocabulary in one place

The ALB part of AWS has its own dictionary. Memorize this card; nothing else in
the doc invents a new term.

| Word | Plain-English meaning |
|---|---|
| **Load balancer** | A traffic distributor. Receives client requests, picks a backend, forwards the request, returns the reply. |
| **ALB** (Application Load Balancer) | AWS's Layer-7 (HTTP/HTTPS-aware) load balancer. Understands URLs and headers; can route by path/host. |
| **ELB** (Elastic Load Balancing) | The **umbrella service name**. ALB is one product within ELB. NLB, GWLB, Classic LB are the others. So "ELB" ≠ "Classic LB" in modern AWS — it usually means *the whole family*. |
| **`aws_lb`** | The Terraform resource for an ALB or NLB. (The legacy `aws_elb` is for Classic LB only — avoid.) |
| **Target group** | A pool of backends (instance IDs or IPs) + the health-check definition the ALB uses to decide who's healthy. The ALB itself doesn't "know" backends — it knows target groups. |
| **Target type** | `"instance"` (registers EC2 IDs — what we use), `"ip"` (registers raw IPs — Fargate/ENI), `"lambda"` (registers a Lambda). |
| **Listener** | The "I'll accept traffic on port X and forward it" config on the ALB. Each ALB has ≥1 listener (e.g. one for `:80`, one for `:443`). |
| **Listener rule** | Within a listener, an optional routing condition ("if path starts with `/api/`, send to target group A"). The **default rule** is what runs when nothing else matches. |
| **DNS name** | The auto-generated public address of the ALB, e.g. `cloudcare-alb-12345678.ap-south-1.elb.amazonaws.com`. Browsers/curl use this. |
| **Zone ID** | An identifier used by Route 53 alias records to point a custom domain at the ALB. |
| **`internal` (true/false)** | `false` (default) = **internet-facing** ALB with a public DNS. `true` = internal-only, only reachable from inside the VPC. |
| **Health check** | An HTTP GET (or TCP probe) the ALB makes to each target on a schedule. If targets fail, they stop receiving traffic. |
| **`matcher`** | Which HTTP status codes count as "healthy" (e.g. `"200"`, `"200-299"`). |
| **`healthy_threshold` / `unhealthy_threshold`** | How many consecutive passes/fails before flipping state. |
| **`interval` / `timeout`** | Seconds between checks / how long each one waits. |
| **`autoscaling_attachment`** | The glue resource linking an ASG to a target group, so new EC2s auto-register and terminated ones auto-deregister. |
| **5xx Gateway errors** | `502` = ALB couldn't get a usable response from the target. `503` = no healthy targets. `504` = target took too long. Specific symptoms with specific causes. |

Now the diagram.

---

## 1. Where the ALB sits

```
   Users (browser / curl)
        │  HTTP :80
        ▼
   ┌──────────────── PUBLIC subnets (AZ-a, AZ-b) ────────────────┐
   │   Application Load Balancer  (SG: alb-sg, allows 80/443)      │
   │        │  listener :80  ──►  target group :8000              │
   └────────┼─────────────────────────────────────────────────────┘
            │  :8000  (alb-sg ──► app-sg)
   ┌────────▼──────── PRIVATE app subnets (AZ-a, AZ-b) ──────────┐
   │   Auto Scaling Group  →  EC2 instances (Doc 09)              │
   └───────────────────────────────────────────────────────────────┘
```

The ALB lives in the **public** subnets (it needs an internet-facing address);
the instances stay **private**. The security-group chain from Phase 1 already
permits exactly this path: internet → `alb-sg` (80/443) → `app-sg` (8000).

> 🧠 **Why a load balancer at all?** It's the single, stable front door. It
> spreads requests across healthy instances in both AZs, runs **health checks**
> and stops sending traffic to sick ones, and lets the ASG add/remove instances
> behind it without clients noticing. One DNS name, many disposable instances.

### One ALB ≠ one box

A common misconception: people think "one ALB" = "one server somewhere." It's
actually a **regional service**. When you create an ALB across two subnets in
two AZs, AWS places a **node in each AZ subnet**, all sharing one DNS name. The
DNS name resolves to multiple IPs (one per AZ). If the AZ-a node fails, the
AZ-b node keeps serving traffic. You manage one logical thing; AWS runs it
redundantly.

---

## 2. The pieces of an ALB (three resources + one glue)

An "ALB" in Terraform is actually **three** resources working together, plus
one connector:

| Resource | Role | Analogy |
|----------|------|---------|
| `aws_lb` | the load balancer itself (DNS name, lives in subnets, wears an SG) | the front desk |
| `aws_lb_target_group` | the pool of backends + the **health check** | the staff roster + check-in clipboard |
| `aws_lb_listener` | "traffic arriving on port X → forward to this target group" | the receptionist who hands visitors to staff |
| `aws_autoscaling_attachment` | registers the ASG's instances into the target group automatically | HR adding new hires (and removing leavers) from the roster |

You **must** have all four wired correctly — miss any one and traffic stops at
that hop. We'll create them in that order.

---

## 3. `alb.tf`

Create `terraform/compute/alb.tf`:

```hcl
# terraform/compute/alb.tf

# 1) The load balancer — internet-facing, in the PUBLIC subnets, using alb-sg.
resource "aws_lb" "app" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [
    data.terraform_remote_state.network.outputs.alb_security_group_id
  ]
  subnets = data.terraform_remote_state.network.outputs.public_subnet_ids

  tags = { Name = "${var.project}-alb" }
}

# 2) The target group — the instances answer on :8000. The health check hits "/"
#    and expects HTTP 200 (our placeholder returns exactly that).
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id
  target_type = "instance"

  health_check {
    path                = "/"
    port                = "traffic-port" # = 8000, the target group's port
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.project}-app-tg" }
}

# 3) The listener — accept HTTP on :80 and forward to the target group.
#    (HTTPS/:443 needs an ACM certificate; we add that with CloudFront in Phase 5.)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# 4) Connect the ASG to the target group. New instances auto-register; terminated
#    ones auto-deregister. This is the glue between Doc 09 and this doc.
resource "aws_autoscaling_attachment" "app" {
  autoscaling_group_name = aws_autoscaling_group.app.id
  lb_target_group_arn    = aws_lb_target_group.app.arn
}
```

### Block 1 — the load balancer itself

```hcl
resource "aws_lb" "app" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [
    data.terraform_remote_state.network.outputs.alb_security_group_id
  ]
  subnets = data.terraform_remote_state.network.outputs.public_subnet_ids

  tags = { Name = "${var.project}-alb" }
}
```

| Line | Meaning |
|---|---|
| `resource "aws_lb" "app"` | Create a load balancer; nickname `app`. (`aws_lb` is the modern resource — handles both ALB and NLB.) |
| `name = "${var.project}-alb"` | Console-visible name → `cloudcare-alb`. AWS auto-appends a random suffix to its DNS hostname. |
| `load_balancer_type = "application"` | **ALB** (Layer 7, HTTP-aware). Alternatives: `"network"` (NLB, Layer 4) or `"gateway"` (GWLB). |
| `internal = false` | **Internet-facing.** Gets a public DNS name. `true` would make it only reachable from inside the VPC. |
| `security_groups = [...]` | A **list** of SGs to attach. We read the **ALB SG** from the network stack — the one that allows `80/443` from `0.0.0.0/0`. |
| `subnets = ...public_subnet_ids` | A list of **public** subnet IDs (one per AZ). AWS drops a load-balancer **node** into each subnet. ALB requires ≥2 subnets in ≥2 AZs. |

> 🧠 **Note the cross-stack reference twice in this block.** The SG and the
> subnets both come from `data.terraform_remote_state.network.outputs.*`. The
> compute folder never recreates the network — it just reads it.

### Block 2 — the target group + health check

```hcl
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id
  target_type = "instance"

  health_check { ... }
  tags = { ... }
}
```

The target group is the ALB's **roster of backends**. The ALB by itself doesn't
know about your EC2s — it only knows about target groups, and target groups
contain the actual targets.

| Line | Meaning |
|---|---|
| `resource "aws_lb_target_group" "app"` | Create a target group; nickname `app`. |
| `name = "${var.project}-app-tg"` | Console name → `cloudcare-app-tg`. |
| `port = 8000` | The **port the targets are listening on**. Our placeholder runs on `:8000`. |
| `protocol = "HTTP"` | The ALB will talk HTTP to the target (not HTTPS — the connection from ALB → EC2 is *inside* your VPC, where TLS would be optional). |
| `vpc_id = ...network.outputs.vpc_id` | Which VPC the group lives in (must match the ALB's VPC). |
| `target_type = "instance"` | Register **EC2 instance IDs** as targets. Other values: `"ip"` (raw IPs, for ENIs / Fargate), `"lambda"` (register a Lambda function). |

#### Health check fields, one by one

```hcl
health_check {
  path                = "/"
  port                = "traffic-port"
  protocol            = "HTTP"
  matcher             = "200"
  interval            = 15
  timeout             = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
}
```

| Field | Meaning |
|---|---|
| `path = "/"` | The URL path the ALB requests. Our placeholder answers any GET. Real apps usually expose a dedicated `/health` endpoint. |
| `port = "traffic-port"` | **Use the same port the target group does** (`8000`). Could be a specific number to health-check on a different port from traffic. |
| `protocol = "HTTP"` | HTTP probe (not HTTPS, not TCP). |
| `matcher = "200"` | Treat **only** `200 OK` as healthy. You can also write `"200-299"` (any 2xx) or `"200,202"`. |
| `interval = 15` | Run a check every 15 seconds. |
| `timeout = 5` | Each check waits ≤5 seconds for a response. |
| `healthy_threshold = 2` | A target needs **2 consecutive passes** to flip from unhealthy → healthy. With `interval=15`, that's ~30 seconds to come online. |
| `unhealthy_threshold = 2` | A target needs **2 consecutive failures** to flip from healthy → unhealthy. With `interval=15`, that's ~30 seconds to be cut off. |

> 🧠 **`matcher = "200"`** means "an instance is healthy only if `GET /` returns
> HTTP 200." Our placeholder always returns 200, so targets go healthy within
> ~30s. In Phase 4 the real app will expose a dedicated `/health` path.

> 🧠 **Why two-threshold check (not one)?** A single failure could be a flaky
> network blip. Requiring **2 in a row** before marking unhealthy avoids
> false-positive removals while still cutting off truly bad targets quickly.

### Block 3 — the listener

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

A listener says: *"when traffic arrives at the ALB on port X, what do I do
with it?"*

| Line | Meaning |
|---|---|
| `resource "aws_lb_listener" "http"` | Create a listener; nickname `http`. |
| `load_balancer_arn = aws_lb.app.arn` | Which ALB this listener attaches to. |
| `port = 80` | The ALB will accept incoming traffic on port 80 (HTTP). |
| `protocol = "HTTP"` | Plain HTTP (no TLS). For HTTPS you'd use `"HTTPS"` + an `ssl_policy` + `certificate_arn`. |
| `default_action { type = "forward", target_group_arn = ... }` | The fallback rule: **forward** everything not matched by another rule to the target group. |

For now we only have a single default rule (forward all). Listener rules let
you do path-based routing (`/api/*` → group A, `/*` → group B), which we'll
exercise in Phase 5 via CloudFront. The ALB itself can do it too, but we don't
need to here.

> 💡 **HTTPS comes from CloudFront, not the ALB, in this project.** A proper
> HTTPS listener needs an **ACM certificate** for a real domain. We let
> CloudFront terminate TLS at the edge (Phase 5) and keep the ALB on plain HTTP
> behind it. Both patterns are valid; this saves us from buying a domain just
> for the lab.

### Block 4 — autoscaling attachment (the glue)

```hcl
resource "aws_autoscaling_attachment" "app" {
  autoscaling_group_name = aws_autoscaling_group.app.id
  lb_target_group_arn    = aws_lb_target_group.app.arn
}
```

| Line | Meaning |
|---|---|
| `autoscaling_group_name = aws_autoscaling_group.app.id` | Reference the ASG from Doc 09. |
| `lb_target_group_arn = aws_lb_target_group.app.arn` | Reference the target group we just made. |

This single block wires them together. After it's applied:
- Every **new** EC2 the ASG launches is **automatically registered** as a target.
- Every **terminated** EC2 is **automatically deregistered**.
- You **never** add/remove targets by hand.

Without this block, the target group stays empty and the ALB has nothing
healthy to forward to → `503 Service Unavailable`.

> 🧠 **`target_type = "instance"`** registers EC2 instance IDs (the ASG manages
> which ones). The other common type, `ip`, is for Fargate/ENI targets — name-drop
> it if asked, but instance targets are right for an EC2 ASG.

---

## 4. One edit: let the ALB decide instance health

In Doc 09 we set the ASG's `health_check_type = "EC2"` (is the VM running?). Now
that an ALB exists, upgrade it to **`ELB`** so the ASG trusts the **HTTP health
check** (is the *app* actually answering?). Edit `terraform/compute/asg.tf`:

```hcl
  # was: health_check_type = "EC2"
  health_check_type         = "ELB"
  health_check_grace_period = 90
```

### What changes

| Setting | "EC2" mode (Doc 09) | "ELB" mode (now) |
|---|---|---|
| What "healthy" means | the hypervisor reports the VM is running | the ALB's HTTP health check on the target group returns 200 |
| Catches "VM up, app crashed"? | ❌ no — sees the instance as healthy forever | ✅ yes — ASG terminates and replaces |
| When to use | no ALB yet | as soon as an ALB is fronting the fleet |

`health_check_grace_period = 90` bumps the grace from 60s → 90s. This is the
window after boot during which **health-check failures don't count** — gives
`user_data` time to install the Python service before the ALB starts judging.
With our placeholder, 30–60s is enough; 90s is a comfortable safety margin.

> 🧠 **EC2 vs ELB health check:** "EC2" only knows the instance is powered on.
> "ELB" knows your *application* responds. With "ELB", if the app crashes but the
> VM stays up, the ASG notices and replaces the instance. That's the behavior you
> want — and a great interview detail.

---

## 5. Add the load-balancer outputs

Append to `terraform/compute/outputs.tf`:

```hcl
# --- append to terraform/compute/outputs.tf ---

output "alb_dns_name" {
  description = "Public DNS name of the load balancer — open/curl this"
  value       = aws_lb.app.dns_name
}

output "alb_zone_id" {
  description = "Hosted-zone ID of the ALB (for Route 53 / CloudFront later)"
  value       = aws_lb.app.zone_id
}

output "target_group_arn" {
  description = "ARN of the app target group"
  value       = aws_lb_target_group.app.arn
}
```

| Output | What it is | Used where later |
|---|---|---|
| `alb_dns_name` | the public DNS hostname AWS gives the ALB, e.g. `cloudcare-alb-xxx.ap-south-1.elb.amazonaws.com` | what you `curl`; what **CloudFront** uses as its origin in Phase 5 |
| `alb_zone_id` | AWS-managed hosted-zone ID for the ALB | needed if you later use **Route 53** alias records to map a custom domain |
| `target_group_arn` | full ARN of the target group | used in Phase 7 (observability) for target-health alarms |

---

## 6. Apply & verify (the payoff)

Still in `terraform/compute/`:

### Step 1 — Set credentials (if needed)

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1
```

### Step 2 — Plan

```bash
terraform fmt
terraform validate
terraform plan
```

Expect **`Plan: 4 to add, 1 to change, 0 to destroy.`**

| Change | What |
|--------|------|
| +4 add | ALB, target group, listener, autoscaling attachment |
| ~1 change | the ASG's `health_check_type` flip (EC2 → ELB), plus the grace period |

### Step 3 — Apply

```bash
terraform apply       # type "yes"
```

What happens during apply:

1. Lock acquired.
2. ALB created — takes ~2–3 minutes; AWS provisions the per-AZ nodes and the
   shared DNS name.
3. Target group created.
4. Listener created (after ALB exists).
5. Autoscaling attachment created — your existing EC2 gets registered as a
   target. Health check starts.
6. ASG settings updated (health-check type flips to `"ELB"`).
7. State saved; lock released; outputs printed including `alb_dns_name`.

The instance from Doc 09 is **already running**. The moment the target group is
attached, the ALB starts health-checking it. After ~30 seconds it's healthy and
the ALB forwards traffic to it.

### Step 4 — Watch the target turn healthy

```bash
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}' \
  --output table
```

**Decoded:**

- `aws elbv2 describe-target-health` — query the health state of a target group's targets.
- `--target-group-arn $(terraform output -raw target_group_arn)` — pass the ARN of *our* target group.
- `--query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}'` — JMESPath: from the array of target-health descriptions, pull each target's `Target.Id` (instance ID) and current `TargetHealth.State`.

Expected progression:
```
initial   →   unhealthy   →   healthy        (over ~30–60 seconds)
```

States you can see:

| State | Meaning |
|---|---|
| `initial` | just registered; first health check still pending |
| `unhealthy` | failing the health check |
| `healthy` | ✅ passing → ALB will forward traffic |
| `unused` | the autoscaling attachment isn't wired |
| `draining` | being deregistered (terminating instance) |

### Step 5 — The moment of truth — `curl` end-to-end

```bash
ALB=$(terraform output -raw alb_dns_name)
curl "http://$ALB/"
# → CloudCare healthy from ip-10-0-10-xx
```

**Decoded:**

- `ALB=$(...)` — shell variable assignment. Runs the inner command and stores its output.
- `terraform output -raw alb_dns_name` — print the value of the `alb_dns_name` output without quotes.
- `curl "http://$ALB/"` — make an HTTP GET to that hostname's root path.

🎉 A request just traveled **internet → ALB (public subnet) → EC2 (private
subnet) → back**. That is the core 3-tier data path working.

#### What happened on the network, hop by hop

```
1. your-laptop:54321  →  ALB:80               (over the internet)
   - public NACL ingress rule 100  → allow (port 80)
   - ALB-SG ingress (80 from 0.0.0.0/0)       → allow

2. ALB:50000  →  EC2:8000                     (ALB acts as client to backend)
   - public NACL egress (all)                  → allow (leaving public subnet)
   - private NACL ingress (from VPC CIDR)      → allow (entering app subnet)
   - app-SG ingress (8000 from ALB-SG)         → allow

3. EC2:8000  →  ALB:50000                     (reply)
   - app-SG stateful → reply auto-allowed
   - private NACL egress (all) → allow
   - public NACL ingress rule 120 (ephemeral)  → allow

4. ALB:80  →  your-laptop:54321               (final reply over internet)
   - ALB-SG stateful → reply auto-allowed
   - public NACL egress (all) → allow
```

Every hop required at least two checks (SG + NACL). They all passed → you got a
response.

> 💡 **See load balancing happen.** Temporarily scale to two instances:
> ```bash
> aws autoscaling set-desired-capacity \
>   --auto-scaling-group-name $(terraform output -raw asg_name) \
>   --desired-capacity 2
> ```
> Wait ~90s for the second target to go healthy, then run
> `curl http://$ALB/` a handful of times — the **hostname in the response
> alternates** between the two instances. Scale back to 1 when done (free-tier!):
> ```bash
> aws autoscaling set-desired-capacity \
>   --auto-scaling-group-name $(terraform output -raw asg_name) \
>   --desired-capacity 1
> ```
> (Setting it via the CLI is just for the demo; your Terraform `desired = 1`
> remains the source of truth — the next `apply` would reconcile it back.)

---

## 7. Troubleshooting (the usual suspects)

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Target stuck `unhealthy` | app-sg doesn't allow :8000 from alb-sg | re-check Phase 1 `app` SG rule references `alb-sg` |
| `curl` hangs / times out | alb-sg missing inbound :80 | re-check Phase 1 `alb` SG ingress 80 |
| Target `unused`/not registered | autoscaling attachment missing | confirm `aws_autoscaling_attachment` applied |
| 502 Bad Gateway | app not listening on :8000 | the placeholder service failed to start (check `user_data`) |
| 503 Service Unavailable | no healthy targets at all | target group is empty or all unhealthy |
| 504 Gateway Timeout | target took too long to respond | check the app's actual response time |
| Health check 404 not 200 | wrong `path`/`matcher` | path `/`, matcher `200` |

> 🧠 90% of "ALB doesn't work" cases are a **security group** problem — the ALB
> can't reach the instance, or you can't reach the ALB. Trace the chain
> `you → :80 alb-sg → :8000 app-sg` and one link is missing.

### How to diagnose without guessing

If something doesn't work, run these in order:

```bash
# 1) Is there a healthy target?
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --output table
```

- All `unhealthy` → app isn't responding on `:8000`. Check the EC2 (via SSM, or
  `aws ssm send-command` with a `curl 127.0.0.1:8000`).
- No targets at all → the autoscaling attachment didn't register them.

```bash
# 2) Is the ALB even running?
aws elbv2 describe-load-balancers \
  --names $(terraform output -raw alb_dns_name | cut -d. -f1) \
  --query 'LoadBalancers[0].State' --output text
```
Should print `active`.

```bash
# 3) Does the EC2 itself reply locally?
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $(terraform output -raw asg_name) \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["curl -s http://127.0.0.1:8000/ | head"]'
```
If this returns the placeholder text, the **app is fine** — your problem is between the ALB and the instance (security group, target registration).

---

## 8. Plain-English summary (what you just built)

If asked to explain Phase 2:

1. **The ALB** (`cloudcare-alb`) is an internet-facing Application Load Balancer
   spanning both public subnets (one node per AZ). It wears the **ALB SG**
   (inbound 80/443 from anywhere).
2. The **target group** (`cloudcare-app-tg`) is the ALB's roster of backends.
   Targets are EC2 **instances**; the health check is `GET /` expecting `200`,
   every 15s, 2-of-2 thresholds.
3. The **HTTP listener** on `:80` has one default rule: *forward to that target
   group*.
4. The **autoscaling attachment** wires the Doc-09 ASG into the target group, so
   every new EC2 auto-registers and every terminated one auto-deregisters.
5. The ASG's `health_check_type` was upgraded from `"EC2"` to `"ELB"` — now it
   trusts the ALB's HTTP check, so it'll replace instances whose **app**
   crashed (not just whose VM is dead).
6. End to end: `curl http://<alb_dns_name>/` returns
   `CloudCare healthy from ip-10-0-10-xx` — proving the full path
   internet → ALB → private EC2 → reply.

---

## 9. Interview soundbites

- **The ALB trio + glue** — *"In Terraform, an ALB is four resources: `aws_lb`
  (the LB itself), `aws_lb_target_group` (backends + health check),
  `aws_lb_listener` (port → forward rules), and `aws_autoscaling_attachment`
  (auto-register the ASG's instances). Miss any one and traffic stops at that
  hop."*

- **Multi-AZ from a single ALB** — *"An ALB across two subnets in two AZs gets a
  node in each AZ subnet, sharing one DNS name that resolves to multiple IPs.
  If an AZ fails the other node keeps serving — no client-side change."*

- **Why ELB-mode health checks** — *"With `health_check_type = ELB`, the ASG
  uses the ALB's HTTP check, not just EC2 status. That catches the
  'VM-running-but-app-crashed' case — the ASG terminates and replaces those
  instances automatically."*

- **Target group target types** — *"We use `target_type = instance` because the
  ASG manages EC2 IDs. For Fargate or ENIs you'd use `ip`; for Lambda fronting
  you'd use `lambda`. Same target group concept, different attachment style."*

- **Why HTTPS comes later (via CloudFront)** — *"The ALB terminates plain HTTP
  in this project. HTTPS termination happens at the edge in CloudFront with an
  ACM cert in Phase 5. Both ALB-direct and CDN-fronted TLS are valid patterns;
  fronting with CloudFront also adds caching and DDoS protection."*

- **Common 5xx breakdown** — *"`502` = backend gave a malformed response or the
  connection failed. `503` = no healthy targets. `504` = backend took too long.
  In practice, 90% of new-deployment ALB issues are SG misconfigurations
  blocking the ALB → target hop."*

---

## 10. 💰 Cost & teardown (important this phase)

| Resource | Free-tier status |
|----------|------------------|
| ALB | ✅ 750 hrs/month + 15 LCUs free for 12 months (≈ one ALB all month) |
| ALB after 12 months / a 2nd ALB | ⚠️ ~$0.025/hr (~$18/mo) + LCU/data |
| 1× `t2.micro` instance | ✅ within 750 hrs |
| Target group, listener | ✅ free |

> 💰 **Destroy the compute stack when you're done learning for the day:**
> ```bash
> terraform destroy   # in terraform/compute/  — removes ALB + ASG + instances
> ```
> The ALB is the most expensive thing you've created so far if left running for
> months. Tearing it down returns you to ~$0. **Leave `network/` and `bootstrap/`
> up** — they're free and everything else depends on them. Recreate the whole
> compute tier anytime with `terraform apply` (the ALB DNS name will change).

---

## ✅ Checkpoint — end of Phase 2 🎉

You've built CloudCare's compute tier. You should now have, in
`terraform/compute/` (state key `compute/...`):

- [ ] A Launch Template (Amazon Linux 2023, app-sg, IMDSv2, placeholder service).
- [ ] An Auto Scaling Group across both private app subnets, health-checked by the
      ALB (`health_check_type = "ELB"`).
- [ ] An internet-facing ALB in the public subnets, with a target group on :8000
      and an HTTP :80 listener.
- [ ] A successful `curl http://<alb_dns_name>/` returning a healthy response from
      a **private** instance.

And you can explain, from memory:

- The ALB trio: load balancer, target group (+ health check), listener.
- How an Auto Scaling Group self-heals and stays multi-AZ.
- The full request path internet → ALB → EC2 and why the EC2 has no public IP.
- EC2 vs ELB health checks, and why instances use an IAM role not SSH keys.
- The difference between `502`, `503`, and `504` from an ALB.

> This phase + Phase 1 are the heart of an SRE interview. Practice drawing the
> whole path — public/private subnets, the ALB, the ASG, the SG chain — and
> narrating a request through it.

**Tell me when you've reached this checkpoint** (and whether you destroyed the
compute stack), and I'll write **Phase 3 — Database**: an RDS PostgreSQL instance
in the private **db** subnets, a DB subnet group, the `db-sg` you already built,
and the DB password stored in **Secrets Manager** (never in code).

Next: **Phase 3 — Database** (doc 11, written when you reach this checkpoint).
