# 08 — Networking: Security Groups & NACLs

> **Goal of this doc:** add the two **firewall layers** to the VPC you built in
> Doc 07 — the stateful **security-group chain** (`internet → ALB → App → DB`)
> and the stateless **NACL** backstops. By the end, Phase 1 (networking) is
> complete and CloudCare has proper, layered, defense-in-depth network security.

⏱️ Time: ~45–60 minutes. 💰 Cost: **$0** — security groups and NACLs are free.

We keep working in the **same folder**, `terraform/network/`, adding two new
files. Doc 02 §3.8 explained the *concepts*; here we turn them into code.

---

## 0. Beginner read-me first — vocabulary in one place

This doc throws a lot of firewall terminology at you. Re-read this card whenever
a term feels fuzzy. Many of these were also in our conversational explanations —
they're collected here so you don't have to dig.

| Word | Plain-English meaning |
|---|---|
| **Firewall** | A rules-engine that allows or denies network traffic. AWS has two: security groups and NACLs. |
| **Security Group (SG)** | A *firewall on a resource* (an instance, ALB, RDS, etc.). Stateful. Allow-only. |
| **NACL (Network ACL)** | A *firewall on a subnet*. Stateless. Allow **and** deny. |
| **Ingress** | **Inbound** traffic — coming **INTO** the resource/subnet. |
| **Egress** | **Outbound** traffic — going **OUT** of the resource/subnet. |
| **Stateful** | Remembers "I let this connection start" → the **reply is automatically allowed**. (security groups) |
| **Stateless** | Has no memory. Each packet checked independently. **Reply traffic must be explicitly allowed.** (NACLs) |
| **Port** | A numbered "service desk" on a server. HTTP=80, HTTPS=443, Postgres=5432, our FastAPI=8000. |
| **`from_port` / `to_port`** | A **port RANGE** (start/end). Same number means one port. **NOT** "inbound port / outbound port." |
| **Ephemeral port** | A temporary random port in **1024–65535** that a client uses as its source address. Replies come back to this port. |
| **Protocol** | `"tcp"`, `"udp"`, `"icmp"`, or `"-1"` (= "all"). |
| **`cidr_blocks`** | A list of IP ranges allowed (the **WHO**, by IP). `"0.0.0.0/0"` = anyone on the internet. |
| **`security_groups`** (in an SG rule) | A list of *other* SG IDs allowed (the **WHO**, by group membership — not by IP). |
| **`rule_no`** | NACL-only. The evaluation **order** — lowest first, **stop at first match**. |
| **`action`** | NACL-only. `"allow"` or `"deny"`. |
| **Defense in depth** | Layering multiple security controls so a single misconfig doesn't break everything. |
| **SYN_RECV** | A half-open TCP state. When you see connections stuck here, it almost always means **NACL is dropping the reply**. |

Two **classic beginner confusions** the doc will keep correcting:

1. `from_port` / `to_port` are a **range**, not directions. `from=80, to=80` means "exactly port 80."
2. `0.0.0.0/0` (an IP wildcard, "anyone") is **different** from `from_port=0, to_port=0, protocol=-1` (a port/protocol wildcard, "all ports"). Both contain a `0`, but they mean very different things.

---

## 1. The two firewalls, side by side (the interview question)

You **will** be asked the difference. Here it is, then we'll build both.

| | **Security Group (SG)** | **Network ACL (NACL)** |
|---|---|---|
| Attaches to | a resource (an instance/ENI) | a whole **subnet** |
| State | **Stateful** — reply traffic auto-allowed | **Stateless** — you must allow return traffic too |
| Rules | **allow** only | **allow and deny** |
| Evaluation | all rules together (any allow wins) | numbered, lowest first, **stops at first match** |
| Default | implicit-deny everything | implicit-deny everything |
| Our role for it | **primary, precise** control | **coarse** subnet-wide backstop |

> 🧠 **Stateful vs stateless — the one that trips everyone.** A security group
> remembers outgoing connections, so the response is automatically allowed back
> in. A NACL has no memory: if you allow a request *in*, you must *separately*
> allow the response *out* (and vice-versa) — on the **ephemeral ports**
> (1024–65535) the OS uses for replies. Forgetting this is the classic "my NACL
> broke everything" bug. We'll handle it explicitly below.

Our plan: do the **precise** work with security groups, and keep NACLs **coarse**
(allow broad, sane traffic) so they're a guardrail, not a footgun.

### The two-question model

Every firewall rule answers **two questions**:

| Question | Where it lives in the rule |
|---|---|
| **WHAT** traffic? | `from_port`, `to_port`, `protocol` |
| **WHO** is allowed? | `cidr_blocks` (by IP) OR `security_groups` (by group membership) |

Plus, NACLs add two more:
- **ORDER**: `rule_no`
- **VERDICT**: `action` (`allow` or `deny`)

If you can spot those bits in every block below, the syntax stops feeling
magical.

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

### Why ports 80, 443, 8000, 5432?

- **80** = HTTP (plain web). The Internet's standard port for unencrypted web
  traffic. Browsers connect here when you type `http://...`.
- **443** = HTTPS (encrypted web). The Internet's standard port for the lock-icon
  encrypted version. Browsers connect here when you type `https://...`. We open
  both because old `http://` links should still reach the ALB (it'll redirect to
  `https://`).
- **8000** = our **internal app port**. FastAPI/Uvicorn listens on it by
  convention. Could be any port; the ALB will forward to whatever the app
  listens on, so this is a pure internal contract.
- **5432** = **PostgreSQL's** default port. RDS will listen here.

You'll see all four numbers throughout this doc — that's why.

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

### Walk-through — the ALB security group, line by line

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Public edge: allow HTTP/HTTPS from the internet"
  vpc_id      = aws_vpc.main.id
  ...
}
```

| Line | Meaning |
|---|---|
| `resource "aws_security_group" "alb"` | Create a security group; nickname it `alb` (we'll reference it as `aws_security_group.alb`). |
| `name = "${var.project}-alb-sg"` | The console-visible name → `cloudcare-alb-sg`. |
| `description = "..."` | **AWS requires** SGs to have a non-empty description. |
| `vpc_id = aws_vpc.main.id` | Bind this SG to our VPC. SGs live inside one VPC. |

Now the **rules** inside it:

#### Ingress rule for port 80

```hcl
ingress {
  description = "HTTP from anywhere"
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
```

| Field | Meaning |
|---|---|
| `ingress { }` | An **inbound** rule (traffic coming IN to anything wearing this SG). |
| `description = "..."` | Human note shown in the console. Always include it. |
| `from_port = 80` | **Range start.** |
| `to_port = 80` | **Range end.** Same number → exactly port 80, no range. |
| `protocol = "tcp"` | TCP only. Other valid values: `"udp"`, `"icmp"`, `"-1"` (all). |
| `cidr_blocks = ["0.0.0.0/0"]` | **WHO is allowed** — IP-based. `0.0.0.0/0` means "any IP address on Earth." |

In plain English: *"Allow TCP traffic on port 80 from any IP."*

#### Ingress rule for port 443

Identical to port 80 except `from_port = to_port = 443`. Plain English:
*"Allow TCP on port 443 from anywhere."*

#### Egress (outbound) rule

```hcl
egress {
  description = "All outbound (so the ALB can reach the app instances)"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}
```

| Field | Meaning |
|---|---|
| `egress { }` | **Outbound** rule. |
| `from_port = 0, to_port = 0` + `protocol = "-1"` | A **special combo** meaning **"all ports, all protocols."** When `protocol="-1"`, the port range is ignored. |
| `cidr_blocks = ["0.0.0.0/0"]` | To anywhere. |

Plain English: *"Allow all outbound traffic to anywhere."* This is necessary so
the ALB can reach the app instances (port 8000) and so its replies can go back
out to clients.

> ⚠️ **Two different zeros, very different meanings.** `0.0.0.0/0` (in
> `cidr_blocks`) = "any IP". `0` / `0` / `-1` (in `from_port`/`to_port`/`protocol`)
> = "all ports + all protocols." Don't confuse them.

### Walk-through — the App SG (with the chain trick)

```hcl
resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "App tier: allow 8000 only from the ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "FastAPI port, from the ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]   # ← THE TRICK
  }

  egress { ... }
  tags  = { ... }
}
```

The **single most important line** in the whole network is the one I marked:

```hcl
security_groups = [aws_security_group.alb.id]
```

Instead of `cidr_blocks = [<some IP range>]`, the App SG says **"WHO is allowed:
anything wearing the ALB security group."** The set of "things wearing ALB-SG"
changes dynamically (the ALB has 2 nodes; both wear the SG), and this rule
**stays correct forever** — no IP to update.

| `cidr_blocks` vs `security_groups` | When to use |
|---|---|
| `cidr_blocks = ["0.0.0.0/0"]` | Internet-facing rules ("anyone may reach me") |
| `cidr_blocks = ["10.0.0.0/16"]` | "Anyone inside the VPC" |
| `cidr_blocks = ["1.2.3.4/32"]` | A specific external IP (e.g. office IP) |
| `security_groups = [other_sg.id]` | **Cross-tier chain** — the production pattern |

### Walk-through — the DB SG

```hcl
ingress {
  from_port       = 5432
  to_port         = 5432
  protocol        = "tcp"
  security_groups = [aws_security_group.app.id]
}
```

Same shape: *"Allow TCP on the PostgreSQL port (5432), only from anything in
the app SG."* The DB is now **unreachable** from the internet, **unreachable**
from the ALB directly, and **unreachable** from any other resource not in the
app SG. That's the security chain in full force.

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
  ingress {
    # Return traffic for connections these subnets OPEN outbound through the NAT
    # instance added in Doc 13 (ECR pulls, dnf, Secrets Manager). NACLs are
    # stateless, so these replies arrive from public IPs on ephemeral ports and
    # must be allowed explicitly — otherwise every outbound connection stalls at
    # SYN_RECV once egress exists.
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
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

### Walk-through — the Public NACL

#### The NACL header

```hcl
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id
  ...
}
```

| Line | Meaning |
|---|---|
| `resource "aws_network_acl" "public"` | Create a NACL; nickname `public`. |
| `vpc_id = aws_vpc.main.id` | Which VPC it belongs to. |
| `subnet_ids = aws_subnet.public[*].id` | **Which subnets it attaches to** — the splat (`[*]`) expression returns `[public-a-id, public-b-id]`. **A subnet has exactly one NACL.** Listing it here detaches it from the default NACL automatically. |

#### Anatomy of one NACL ingress rule

```hcl
ingress {
  rule_no    = 100
  action     = "allow"
  protocol   = "tcp"
  from_port  = 80
  to_port    = 80
  cidr_block = "0.0.0.0/0"
}
```

NACL rules have **two extra fields** vs SG rules:

| Field | Meaning |
|---|---|
| `rule_no = 100` | **Evaluation order.** NACL checks rules low→high and **stops at the first match.** People leave gaps of 10 so future rules can be inserted. |
| `action = "allow"` | The verdict. NACLs uniquely support `"deny"` too (e.g. block a specific bad IP). |
| `protocol = "tcp"` | Same meaning as in SGs. |
| `from_port` / `to_port` | Port range (same meaning as SGs — **range**, not directions). |
| `cidr_block = "0.0.0.0/0"` | **Singular** here (note no `s`). NACL rules take **one** CIDR per rule. SGs took a list (`cidr_blocks`). Just a naming quirk. |

#### The three inbound rules in plain English

- **Rule 100** — *"Allow inbound TCP 80 (HTTP) from any IP."*
- **Rule 110** — *"Allow inbound TCP 443 (HTTPS) from any IP."*
- **Rule 120** — *"Allow inbound TCP **on ephemeral ports 1024–65535** from any IP."* This is the **return-traffic rule**.

#### Why rule 120 exists — the stateless ephemeral-port story

Every TCP conversation has **two ports** in play:
- The **destination port** = the server's well-known port (80, 443).
- The **source port** = the client's random ephemeral port (somewhere in 1024–65535).

When the ALB **acts as a client** to talk to your app instances on port 8000,
the ALB picks an ephemeral source port like `51000`. The app's **reply** comes
back addressed to `ALB:51000`. A stateful SG would auto-allow this; a stateless
NACL would **not** — so we add rule 120 to allow inbound on those ephemeral ports.

```
                public subnet
                                ALB initiates →   ALB:51000 → app:8000   (egress rule 100, "all out")
                                  reply ←        app:8000 → ALB:51000   (← needs INGRESS rule 120!)
```

Without rule 120, the request goes out fine but the reply gets dropped at the
NACL — the connection hangs at `SYN_RECV`. The classic stateless-NACL bug.

> Plain-English summary of the public NACL: *"Allow HTTP, HTTPS, and replies on
> high ports inbound; allow all outbound. Coarse but covers the two real things
> the public subnets do."*

#### The single outbound rule

```hcl
egress {
  rule_no    = 100
  action     = "allow"
  protocol   = "-1"
  from_port  = 0
  to_port    = 0
  cidr_block = "0.0.0.0/0"
}
```

*"Allow everything outbound."* Coarse on purpose.

### Walk-through — the Private NACL

#### The header

```hcl
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = concat(aws_subnet.app[*].id, aws_subnet.db[*].id)
  ...
}
```

`concat(LIST1, LIST2)` is a built-in Terraform function that joins two lists
into one. So `subnet_ids` ends up as **all four** private subnets
(`app-a, app-b, db-a, db-b`). One NACL guards all four.

#### Rule 100 — "from inside the VPC only"

```hcl
ingress {
  rule_no    = 100
  action     = "allow"
  protocol   = "-1"
  from_port  = 0
  to_port    = 0
  cidr_block = var.vpc_cidr   # 10.0.0.0/16
}
```

Plain English: *"Allow **all** traffic inbound, as long as the source IP is
inside `10.0.0.0/16` (i.e. inside our VPC)."*

This is a coarse "nothing from the open internet" rule. The precise
tier-to-tier rules are enforced by the security groups; this NACL is just a
backstop.

#### Rule 110 — the ephemeral return rule (for outbound replies)

```hcl
ingress {
  rule_no    = 110
  action     = "allow"
  protocol   = "tcp"
  from_port  = 1024
  to_port    = 65535
  cidr_block = "0.0.0.0/0"
}
```

This is the **partner of "stateless"** — without it, every outbound connection
from the app subnets to anywhere external (the NAT instance from Doc 13, then
the internet) would have its reply dropped at the subnet edge.

If you've completed Doc 13 already, this rule is **non-optional**. If you're
following docs in order, you can add it from the start anyway — it doesn't hurt
anything (rule 100 already covers intra-VPC traffic with `protocol="-1"`, this
just adds external-replies on top).

#### Egress

Same as before — *"allow all out."*

> 🧠 **Walk through the public NACL as a story.** A browser hits the ALB on `443`
> → matched by inbound rule `110`. The ALB's reply leaves on an ephemeral port →
> allowed by outbound rule `100` (all). The ALB then opens a connection *out* to
> an app instance on `8000` → outbound `100`; the app's response comes *back in*
> on an ephemeral port → inbound rule `120`. Every direction is covered. Remove
> rule `120` and responses silently vanish — that's the stateless trap.

> 🧠 **Why the private NACL allows `var.vpc_cidr` inbound (rule 100).** The app and
> db subnets' core traffic is intra-VPC: ALB→app and app→db. Allowing only
> `10.0.0.0/16` inbound is a clean, coarse "nothing from outside the VPC" backstop.
> **Rule 110 (ephemeral return) is the partner that's easy to forget.** While the
> subnets had no internet route (through Doc 12) it didn't matter. But Doc 13 adds
> a **NAT instance** so these subnets can egress to the internet — and because
> NACLs are stateless, the *replies* (from public IPs, on ephemeral ports) need
> rule 110 or every `dnf`/`docker pull` hangs at `SYN_RECV`. If you build straight
> through to Doc 13, include rule 110 here from the start.

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

### What this enables (preview of the next phase)

In the compute folder's `launch-template.tf` (Doc 09), you'll see:

```hcl
vpc_security_group_ids = [
  data.terraform_remote_state.network.outputs.app_security_group_id
]
```

That line reads **this output** from S3 state and attaches the **app SG** to
every new EC2 the ASG launches. Without exporting it as an output, the compute
stack would have no way to reference it.

---

## 6. Apply & verify

Still inside `terraform/network/` (the same folder from Doc 07):

### Step 1 — Set credentials (skip if your shell still has them set from Doc 07)

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1
```

`export NAME=value` sets a shell environment variable that all child processes
(including `terraform` and `aws`) see. They only last for the current terminal
window.

### Step 2 — Lint and validate

```bash
terraform fmt
terraform validate
```

- `terraform fmt` rewrites `.tf` files with canonical indentation and `=`
  alignment. Safe and reversible — paths of any changed files are printed.
- `terraform validate` checks **local syntax + reference integrity** (every
  `aws_subnet.public` actually exists, every `var.xxx` is declared). Does **not**
  touch AWS.

### Step 3 — Dry-run with `plan`

```bash
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

### Step 4 — Apply

```bash
terraform apply   # type "yes"
```

What happens behind the scenes:

1. Terraform acquires the DynamoDB lock so no other apply can run.
2. Creates the 3 SGs first (in parallel — they're independent of each other,
   except the App SG's rule references the ALB SG, which Terraform detects via
   the `aws_security_group.alb.id` reference and orders accordingly).
3. Creates the 2 NACLs and detaches the corresponding subnets from the default
   NACL (a NACL-association implicit step).
4. Updates the state object in S3.
5. Releases the DynamoDB lock.
6. Prints the 3 new outputs.

### Step 5 — Verify the chain with the CLI

#### Show all security groups in this VPC with their inbound rules

```bash
aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'SecurityGroups[].{Name:GroupName,Ingress:IpPermissions[].{Port:FromPort}}' \
  --output table
```

**Decoded:**

- `aws ec2 describe-security-groups` — AWS CLI command for SGs.
- `--filters Name=vpc-id,Values=$(terraform output -raw vpc_id)` — only SGs in
  this VPC. The `$( ... )` is shell substitution — runs the inner command and
  pastes its output in place. `terraform output -raw vpc_id` prints just the VPC
  ID without quotes (perfect for piping).
- `--query 'SecurityGroups[].{Name:GroupName,Ingress:IpPermissions[].{Port:FromPort}}'` —
  JMESPath. For each SG, pull its `GroupName` and a sub-list of `IpPermissions`
  showing only `FromPort`. Renamed in the output as `Name` and `Ingress`.
- `--output table` — pretty-print.

#### Confirm the App SG's port-8000 rule references the ALB SG (not a CIDR)

```bash
aws ec2 describe-security-groups \
  --group-ids $(terraform output -raw app_security_group_id) \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`8000`].UserIdGroupPairs[].GroupId' \
  --output text
# → should print the ALB security group's ID
```

**Decoded:**

- `--group-ids $(terraform output -raw app_security_group_id)` — look at exactly
  the App SG.
- `'SecurityGroups[0].IpPermissions[?FromPort==`8000`].UserIdGroupPairs[].GroupId'`
  — JMESPath: from the App SG's permissions, pick the one with `FromPort==8000`,
  then from its `UserIdGroupPairs` (the SGs allowed), pick the `GroupId`.
- Expected: prints exactly the ALB SG's ID, proving the chain is by SG, not CIDR.

#### Confirm both custom NACLs are attached to the right subnets

```bash
aws ec2 describe-network-acls \
  --filters Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'NetworkAcls[?!IsDefault].{Name:Tags[?Key==`Name`]|[0].Value,Subnets:Associations[].SubnetId}' \
  --output table
```

**Decoded:**

- `--filters Name=vpc-id,...` — only NACLs in this VPC.
- `'NetworkAcls[?!IsDefault]...'` — `[?!IsDefault]` filters out the auto-created
  default NACL; we only want our two custom ones (`public-nacl` and
  `private-nacl`).
- The query picks `Name` (from the `Name` tag) and the list of associated
  subnet IDs.

Expected: two rows, public-nacl attached to 2 subnets, private-nacl attached to
4 subnets.

> ✅ **The thing to be able to explain on a whiteboard:** point at App-SG and say
> "inbound 8000 *from ALB-SG*", point at DB-SG and say "inbound 5432 *from
> App-SG*". If you can trace why a packet from the internet **cannot** reach the
> database directly, you understand the most important security idea in the
> project.

### Step 6 — A concrete packet trace (helpful for understanding)

A browser hits `https://cloudcare.com/api/patients`. The packet's journey:

```
1. browser:54321 → ALB:443
   - Public NACL ingress rule 110 (443 from anywhere)  → ALLOW
   - ALB-SG ingress (443 from 0.0.0.0/0)                → ALLOW
2. ALB processes the request, then opens a NEW connection:
   ALB:50000 → app-EC2:8000
   - Public NACL egress (all)                           → ALLOW (leaving ALB subnet)
   - Private NACL ingress rule 100 (from VPC CIDR)      → ALLOW (entering app subnet)
   - App-SG ingress (8000 from ALB-SG)                  → ALLOW
3. App responds:
   app-EC2:8000 → ALB:50000
   - App-SG is stateful → return auto-allowed
   - Private NACL egress (all)                          → ALLOW
   - Public NACL ingress rule 120 (ephemeral 1024-65535) → ALLOW
4. ALB sends final reply:
   ALB:443 → browser:54321
   - ALB-SG stateful → return auto-allowed
   - Public NACL egress (all)                           → ALLOW
```

Every hop has both an SG check (per resource) and a NACL check (per subnet).
That's defense in depth in action.

---

## 7. 💰 Cost & teardown

Security groups and NACLs are **free**. As in Doc 07, **leave the network stack
running** — Phases 2 and 3 attach to these groups. Nothing here drains your
credit.

If you practiced `terraform destroy` at the end of Doc 07, just re-run
`terraform apply` in `terraform/network/` (with both docs' files present) before
starting Phase 2 — you'll get all 21 resources back in one shot.

---

## 8. Plain-English summary (what you just built)

If asked to explain Phase 1's security model:

1. **Three security groups** form a chain:
   - **ALB-SG** lets the **internet** reach the ALB on 80/443.
   - **App-SG** lets the **ALB-SG** reach the app on 8000.
   - **DB-SG** lets the **App-SG** reach Postgres on 5432.
2. The chain uses **`security_groups`** (group membership), not IPs — so the rule
   stays correct as instances scale up/down.
3. **Egress is open** on all three. Inbound is what's locked down — which is
   where the chain lives.
4. **Two NACLs** are subnet-level backstops:
   - **public-nacl** on the 2 public subnets: HTTP, HTTPS, and ephemeral-return.
   - **private-nacl** on the 4 private subnets: anything from inside the VPC,
     plus ephemeral-return for outbound replies (used after Doc 13's NAT).
5. **NACLs are stateless**, which is why every public-facing rule has a partner
   for return traffic on ports 1024–65535.
6. **Three outputs** are added so the compute and database stacks can attach
   their resources to the right SGs via `terraform_remote_state`.

---

## 9. Interview soundbites

- **Stateful vs Stateless** —
  *"Security groups are stateful — outgoing connections automatically allow
  return traffic. NACLs are stateless — every direction needs its own rule, and
  return traffic uses ephemeral ports 1024–65535 you must allow explicitly."*

- **The chain pattern** —
  *"Tier-to-tier security uses `security_groups`, not `cidr_blocks`. The App SG
  allows port 8000 from the ALB SG, not from any IP. Same for DB ← App. That
  way, scaling the ALB or app fleet never requires updating IP allow-lists."*

- **Defense in depth** —
  *"NACLs guard subnet boundaries; security groups guard individual resources.
  We keep NACLs coarse (intra-VPC and ephemeral return) and security groups
  precise (port + source group). A single misconfigured SG can't bypass the
  NACL, and vice versa."*

- **Why the database is safe** —
  *"The DB is in a private subnet with no internet route, behind a security
  group that only trusts the app tier's SG, with `publicly_accessible=false` on
  the RDS instance. Three independent walls between the internet and the data."*

- **The classic NACL bug** —
  *"Stateless NACLs need explicit rules for return traffic on ephemeral ports
  1024–65535. Forgetting that rule makes outbound connections hang at
  `SYN_RECV` — the request leaves, the reply gets dropped. Always add it
  alongside any inbound or outbound rule that initiates conversations."*

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
- The two-zeros trick: `0.0.0.0/0` (any IP) ≠ `0/0/-1` (all ports/protocols).
- Why ephemeral-return rules exist on the NACL.

> This is the phase interviewers probe hardest. Practice drawing the whole VPC —
> boxes, AZs, the IGW, the three SGs and their arrows — until it's automatic.

**Tell me when you've reached this checkpoint** (or hit any snag), and I'll write
**Phase 2 — Compute**: a Launch Template, an Auto Scaling Group of `t2.micro`
FastAPI instances across both app subnets, and an Application Load Balancer in the
public subnets — wired to this network via `terraform_remote_state`.

Next: **Phase 2 — Compute** (docs 09–10, written when you reach this checkpoint).
