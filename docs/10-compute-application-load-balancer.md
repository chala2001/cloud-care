# 10 — Compute: the Application Load Balancer

> **Goal of this doc:** put an internet-facing **Application Load Balancer (ALB)**
> in your public subnets, point it at the Auto Scaling Group from Doc 09 via a
> **target group** on port 8000, and finally reach CloudCare end-to-end with a
> plain `curl`. This completes **Phase 2 — Compute**.

⏱️ Time: ~45–60 minutes. 💰 Cost: the ALB has **750 free hours/month** for 12
months (≈ one ALB running all month), but **destroy it after the lab** — see §8.

We keep working in the **same folder**, `terraform/compute/`, adding one new file
and making one small edit to `asg.tf`.

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

---

## 2. The pieces of an ALB (vocabulary)

An "ALB" in Terraform is actually **three** resources working together:

| Resource | Role |
|----------|------|
| `aws_lb` | the load balancer itself (gets a public DNS name, lives in subnets) |
| `aws_lb_target_group` | the pool of targets + the **health check** definition |
| `aws_lb_listener` | "traffic arriving on port X → forward to this target group" |

Plus one connector: `aws_autoscaling_attachment` registers the ASG's instances
into the target group automatically as they come and go.

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

> 🧠 **`target_type = "instance"`** registers EC2 instance IDs (the ASG manages
> which ones). The other common type, `ip`, is for Fargate/ENI targets — name-drop
> it if asked, but instance targets are right for an EC2 ASG.

> 🧠 **`matcher = "200"`** means "an instance is healthy only if `GET /` returns
> HTTP 200." Our placeholder always returns 200, so targets go healthy within
> ~30s. In Phase 4 the real app will expose a dedicated `/health` path.

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

---

## 6. Apply & verify (the payoff)

Still in `terraform/compute/`:

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

terraform fmt
terraform validate
terraform plan
```

Expect **`Plan: 4 to add, 1 to change, 0 to destroy.`**

| Change | What |
|--------|------|
| +4 add | ALB, target group, listener, autoscaling attachment |
| ~1 change | the ASG's `health_check_type` flip (EC2 → ELB) |

```bash
terraform apply       # type "yes"
```

### Watch the target turn healthy, then curl it

```bash
# 1) Target health — give it ~30-60s after apply to flip to "healthy".
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}' \
  --output table

# 2) The moment of truth — reach CloudCare through the ALB:
ALB=$(terraform output -raw alb_dns_name)
curl "http://$ALB/"
# → CloudCare healthy from ip-10-0-10-xx
```

🎉 A request just traveled **internet → ALB (public subnet) → EC2 (private
subnet) → back**. That is the core 3-tier data path working.

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
| 502 Bad Gateway | app not listening on :8000 | the placeholder service failed to start (check user_data) |
| Health check 404 not 200 | wrong `path`/`matcher` | path `/`, matcher `200` |

> 🧠 90% of "ALB doesn't work" cases are a **security group** problem — the ALB
> can't reach the instance, or you can't reach the ALB. Trace the chain
> `you → :80 alb-sg → :8000 app-sg` and one link is missing.

---

## 8. 💰 Cost & teardown (important this phase)

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

> This phase + Phase 1 are the heart of an SRE interview. Practice drawing the
> whole path — public/private subnets, the ALB, the ASG, the SG chain — and
> narrating a request through it.

**Tell me when you've reached this checkpoint** (and whether you destroyed the
compute stack), and I'll write **Phase 3 — Database**: an RDS PostgreSQL instance
in the private **db** subnets, a DB subnet group, the `db-sg` you already built,
and the DB password stored in **Secrets Manager** (never in code).

Next: **Phase 3 — Database** (doc 11, written when you reach this checkpoint).
