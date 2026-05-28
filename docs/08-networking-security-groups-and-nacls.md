# 08 — Networking: Security Groups & NACLs

> **Goal of this doc:** add the two **firewall layers** to the VPC you built in
> Doc 07 — the stateful **security-group chain** (`internet → ALB → App → DB`)
> and the stateless **NACL** backstops. By the end, Phase 1 (networking) is
> complete and CloudCare has proper, layered, defense-in-depth network security.

⏱️ Time: ~45–60 minutes. 💰 Cost: **$0** — security groups and NACLs are free.

We keep working in the **same folder**, `terraform/network/`, adding two new
files. Doc 02 §3.8 explained the *concepts*; here we turn them into code.

---

## 1. The two firewalls, side by side (the interview question)

You **will** be asked the difference. Here it is, then we'll build both.

| | **Security Group (SG)** | **Network ACL (NACL)** |
|---|---|---|
| Attaches to | a resource (an instance/ENI) | a whole **subnet** |
| State | **Stateful** — reply traffic auto-allowed | **Stateless** — you must allow return traffic too |
| Rules | **allow** only | **allow and deny** |
| Evaluation | all rules together | numbered, lowest first, stops at first match |
| Our role for it | **primary, precise** control | **coarse** subnet-wide backstop |

> 🧠 **Stateful vs stateless — the one that trips everyone.** A security group
> remembers outgoing connections, so the response is automatically allowed back
> in. A NACL has no memory: if you allow a request *in*, you must *separately*
> allow the response *out* (and vice-versa) — on the **ephemeral ports**
> (1024–65535) the OS uses for replies. Forgetting this is the classic "my NACL
> broke everything" bug. We'll handle it explicitly below.

Our plan: do the **precise** work with security groups, and keep NACLs **coarse**
(allow broad, sane traffic) so they're a guardrail, not a footgun.

---

## 2. The security-group chain we're building

From [Doc 02 §3.9](02-core-concepts.md):

```
Internet ──(80/443)──► ALB-SG ──(8000)──► App-SG ──(5432)──► DB-SG
```

Each tier accepts traffic **only from the tier directly in front of it** — not
from the internet, not from random things in the VPC. That layering is
*defense in depth*: even if one tier is compromised, it can't freely reach the
next.

- **ALB-SG**: allow `80`/`443` from anywhere (`0.0.0.0/0`).
- **App-SG**: allow `8000` **only from the ALB-SG**.
- **DB-SG**: allow `5432` (PostgreSQL) **only from the App-SG**.

> 🧠 **The key trick: reference a security group, not an IP range.** When App-SG
> says "allow 8000 from the ALB-SG", it doesn't matter what IP the ALB has or how
> many instances scale up — membership in the group *is* the rule. This is how you
> express "the app tier" abstractly, and it's the single most important SG pattern
> to know.

---

## 3. `security-groups.tf`

Create `terraform/network/security-groups.tf`:

```hcl
# terraform/network/security-groups.tf
# -------------------------------------------------------------------------
# The three-tier chain:  internet --(80/443)--> ALB --(8000)--> App --(5432)--> DB
# Each tier only accepts traffic from the tier directly in front of it.
# -------------------------------------------------------------------------

# 1) ALB SG — the public edge. Anyone on the internet may reach 80/443.
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Public edge: allow HTTP/HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (so the ALB can reach the app instances)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 = all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb-sg" }
}

# 2) App SG — the FastAPI tier. Accept 8000 ONLY from the ALB SG (not the
#    internet). Note `security_groups`, not `cidr_blocks` — that's the chain.
resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "App tier: allow 8000 only from the ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "FastAPI port, from the ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (to reach the DB, and later to pull updates)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-app-sg" }
}

# 3) DB SG — PostgreSQL. Accept 5432 ONLY from the App SG. The database is
#    unreachable from anywhere else — including other things inside the VPC.
resource "aws_security_group" "db" {
  name        = "${var.project}-db-sg"
  description = "DB tier: allow 5432 only from the app security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL, from the app tier only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-db-sg" }
}
```

> 🧠 **Why `egress` "allow all" is OK here.** Security groups are stateful, so the
> risk is almost always *inbound*. Locking egress down hard is a real
> hardening step, but it's fiddly (the app must reach the DB, DNS, package
> mirrors, AWS APIs…) and easy to get wrong while learning. We lock **inbound**
> tightly — which is where the chain lives — and leave egress open. Mention in an
> interview that *production* often restricts egress too.

> 💡 **A note on style.** We used inline `ingress`/`egress` blocks because they
> read top-to-bottom like a sentence ("this group allows X in, Y out"). The modern
> AWS-recommended alternative is **standalone** rule resources
> (`aws_vpc_security_group_ingress_rule` / `..._egress_rule`), one per rule —
> better for large rule sets and avoiding drift. Either is fine; know both names.

> ⚠️ **Don't mix the two styles on one SG.** If you ever add a standalone
> `aws_vpc_security_group_ingress_rule` to a group that *also* has inline
> `ingress {}` blocks, Terraform will fight itself (each "fixes" what the other
> "added") on every apply. Pick one style per security group.

---

## 4. `nacls.tf` — the stateless backstop

NACLs guard the **subnet** edge. Because they're stateless, every rule below has
a deliberate partner for **return traffic** on ephemeral ports. We keep them
coarse on purpose — the security groups already do the precise work.

Create `terraform/network/nacls.tf`:

```hcl
# terraform/network/nacls.tf
# -------------------------------------------------------------------------
# NACLs are STATELESS, subnet-level guardrails. Unlike security groups, you
# must explicitly allow RETURN traffic (the ephemeral 1024-65535 ports).
# We keep these coarse and let the security groups above do the precise work.
# -------------------------------------------------------------------------

# PUBLIC NACL — attached to the public subnets (the ALB tier).
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id

  # ---- inbound ----
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidr_block = "0.0.0.0/0"
  }
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidr_block = "0.0.0.0/0"
  }
  ingress {
    # Return traffic for connections this tier OPENED outbound (e.g. responses
    # from the app instances, and replies coming back to web clients).
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # ---- outbound ----
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }

  tags = { Name = "${var.project}-public-nacl" }
}

# PRIVATE NACL — attached to BOTH app and db subnets. Only accept traffic that
# originates INSIDE the VPC; allow all outbound (replies + intra-VPC calls).
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = concat(aws_subnet.app[*].id, aws_subnet.db[*].id)

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = var.vpc_cidr # 10.0.0.0/16 — only traffic from within the VPC
  }

  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }

  tags = { Name = "${var.project}-private-nacl" }
}
```

> 🧠 **Walk through the public NACL as a story.** A browser hits the ALB on `443`
> → matched by inbound rule `110`. The ALB's reply leaves on an ephemeral port →
> allowed by outbound rule `100` (all). The ALB then opens a connection *out* to
> an app instance on `8000` → outbound `100`; the app's response comes *back in*
> on an ephemeral port → inbound rule `120`. Every direction is covered. Remove
> rule `120` and responses silently vanish — that's the stateless trap.

> 🧠 **Why the private NACL only allows `var.vpc_cidr` inbound.** The app and db
> subnets have **no internet route** (Doc 07), so the only legitimate traffic is
> intra-VPC: ALB→app and app→db. Allowing only `10.0.0.0/16` inbound is a clean,
> coarse "nothing from outside the VPC, ever" backstop that can't accidentally
> break the security-group chain.

> 💡 **Why not lock NACLs down further?** You *could* enumerate exact ports per
> subnet, but stateless rules get error-prone fast and the security groups already
> enforce the precise policy. Coarse NACL + precise SG is the pattern AWS itself
> recommends, and exactly what Doc 02 promised.

---

## 5. Add the security outputs

Append these to your existing `terraform/network/outputs.tf` — the compute and
database phases will attach instances/RDS to these groups by ID.

```hcl
# --- append to terraform/network/outputs.tf ---

output "alb_security_group_id" {
  description = "Security group for the load balancer (used by the compute phase)"
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group for the EC2/app tier"
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "Security group for the RDS tier"
  value       = aws_security_group.db.id
}
```

---

## 6. Apply & verify

Still inside `terraform/network/` (the same folder from Doc 07):

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

terraform fmt
terraform validate
terraform plan
```

Because the VPC/subnets from Doc 07 already exist in state, the plan only adds the
**new** resources: **`Plan: 5 to add, 0 to change, 0 to destroy.`**

| New resource | Count |
|--------------|------:|
| Security groups (alb + app + db) | 3 |
| NACLs (public + private) | 2 |
| **Total** | **5** |

> 🧠 The inline `ingress`/`egress` and NACL rules are *part of* their parent
> resource, so they don't show as separate counted resources — but the plan text
> will still list each rule under its group. Read it to confirm the ports are
> right (80/443 on ALB, 8000 on App, 5432 on DB).

```bash
terraform apply   # type "yes"
```

### Verify the chain with the CLI

```bash
# All three security groups and their inbound rules:
aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'SecurityGroups[].{Name:GroupName,Ingress:IpPermissions[].{Port:FromPort}}' \
  --output table

# Confirm the App SG's 8000 rule references the ALB SG (not a CIDR):
aws ec2 describe-security-groups \
  --group-ids $(terraform output -raw app_security_group_id) \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`8000`].UserIdGroupPairs[].GroupId' \
  --output text
# → should print the ALB security group's ID

# The two custom NACLs and their subnet associations:
aws ec2 describe-network-acls \
  --filters Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'NetworkAcls[?!IsDefault].{Name:Tags[?Key==`Name`]|[0].Value,Subnets:Associations[].SubnetId}' \
  --output table
```

> ✅ **The thing to be able to explain on a whiteboard:** point at App-SG and say
> "inbound 8000 *from ALB-SG*", point at DB-SG and say "inbound 5432 *from
> App-SG*". If you can trace why a packet from the internet **cannot** reach the
> database directly, you understand the most important security idea in the
> project.

---

## 7. 💰 Cost & teardown

Security groups and NACLs are **free**. As in Doc 07, **leave the network stack
running** — Phases 2 and 3 attach to these groups. Nothing here drains your
credit.

If you practiced `terraform destroy` at the end of Doc 07, just re-run
`terraform apply` in `terraform/network/` (with both docs' files present) before
starting Phase 2 — you'll get all 21 resources back in one shot.

---

## ✅ Checkpoint — end of Phase 1 🎉

You've built CloudCare's entire network. You should now have, in
`terraform/network/`, one stack (state key `network/...`) containing:

- [ ] A VPC (`10.0.0.0/16`) with DNS enabled.
- [ ] 6 subnets — public/app/db × 2 AZs — matching the Doc 02 CIDR plan.
- [ ] An Internet Gateway and public/private route tables (public → IGW; private
      local-only).
- [ ] The `ALB → App → DB` security-group chain, each tier allowing only the tier
      in front of it.
- [ ] Custom public/private NACLs as a stateless backstop.
- [ ] Outputs exporting the VPC, subnet, and security-group IDs for later phases.

And you can explain, from memory:

- What makes a subnet public vs private (routing, not a flag).
- Security Group vs NACL — stateful/stateless, resource/subnet, allow-only/allow+deny.
- Why the DB is unreachable from the internet (private subnet **and** an SG that
  only trusts the app tier).
- Why we avoided the NAT Gateway and what we'd use instead.

> This is the phase interviewers probe hardest. Practice drawing the whole VPC —
> boxes, AZs, the IGW, the three SGs and their arrows — until it's automatic.

**Tell me when you've reached this checkpoint** (or hit any snag), and I'll write
**Phase 2 — Compute**: a Launch Template, an Auto Scaling Group of `t2.micro`
FastAPI instances across both app subnets, and an Application Load Balancer in the
public subnets — wired to this network via `terraform_remote_state`.

Next: **Phase 2 — Compute** (docs 09–10, written when you reach this checkpoint).
