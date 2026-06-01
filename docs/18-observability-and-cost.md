# 18 — Observability & Cost

> **Goal of this doc:** make CloudCare *operable*. You'll build one **CloudWatch
> dashboard** that summarizes the whole stack at a glance, a handful of
> **alarms** that page you when something is actually wrong (via an **SNS** topic
> → email), pull logs together with **Logs Insights**, and turn on the three
> AWS **cost tools** (Budgets, Cost Explorer, Compute Optimizer). This is the
> single most interview-important phase after networking — it's where you prove
> you can *run* a system, not just stand one up.

⏱️ Time: ~75 minutes. 💰 Cost: ~$0 — CloudWatch and Cost Explorer have generous
free tiers; alarms are 10/month free, dashboards 3/month free.

---

## 1. Why observability is the SRE skill

"Observability" is being able to answer **questions you didn't pre-define**
about your running system. Three pillars:

| Pillar | What it answers | Where it lives in our stack |
|--------|-----------------|------------------------------|
| **Metrics** | "How is the system behaving over time?" — counters and gauges sampled regularly | CloudWatch Metrics (ALB, EC2, RDS, Lambda, DynamoDB — all publish automatically) |
| **Logs** | "What exactly happened in this one request?" — text records of events | CloudWatch Logs (Lambda log groups, app logs via the CloudWatch agent later) |
| **Traces** | "Where did the time go in this distributed request?" — timelines across services | AWS X-Ray (we turned this on for Lambdas in Doc 16) |

> 🧠 **Interview phrasing:** "Logs tell you what one request did. Metrics tell
> you what *all* requests are doing. Traces stitch a single request across
> services. You need all three." Then point at how this project gives you each.

---

## 2. The Terraform folder

A new stack — `terraform/observability/` — that reads several other stacks via
remote state and creates dashboards + alarms targeting their resources.

```
terraform/
├── …existing stacks…
└── observability/
    ├── providers.tf
    ├── variables.tf
    ├── data.tf           # remote state: network, compute, database, both serverless
    ├── sns.tf            # the "ops alerts" topic + your email subscription
    ├── alarms.tf         # the actual CloudWatch alarms
    ├── dashboard.tf      # one summary dashboard
    └── outputs.tf
```

---

## 3. `providers.tf`, `variables.tf`

```hcl
# terraform/observability/providers.tf
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "observability/terraform.tfstate"
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
      Component = "observability"
    }
  }
}
```

```hcl
# terraform/observability/variables.tf
variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "cloudcare"
}

# Where SNS sends "something is broken" emails.
variable "alert_email" {
  description = "Email that receives ops alerts (you'll need to confirm a subscription email)"
  type        = string
}
```

`terraform.tfvars`:
```hcl
alert_email = "chalaka@wso2.com"
```

---

## 4. `data.tf` — read what the alarms watch

```hcl
# terraform/observability/data.tf

data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "compute/terraform.tfstate"
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "database/terraform.tfstate"
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "audit" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "serverless/audit/terraform.tfstate"
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "contact" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "serverless/contact/terraform.tfstate"
    region = "ap-south-1"
  }
}
```

> 💡 If a stack isn't applied right now (e.g., you torn `compute` down to save
> money), the alarms that reference it won't have anything to watch, and apply
> here will fail to read its outputs. Either keep those stacks up while running
> observability, or comment out the corresponding alarms.

---

## 5. `sns.tf` — one topic, many alarms

```hcl
# terraform/observability/sns.tf

# A single SNS topic that every alarm publishes to. SNS fans it out to all
# subscriptions (email here; could add Slack/PagerDuty/SMS later).
resource "aws_sns_topic" "ops" {
  name = "${var.project}-ops-alerts"
}

# Email subscription. AWS sends a confirmation email — you MUST click the link
# in it before alarms start arriving (Terraform shows the subscription as
# "pending confirmation" until you do).
resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

> 🧠 **Why an SNS topic between alarm and email?** Two reasons: (1) one topic,
> many channels — add a Slack webhook subscription later without touching every
> alarm; (2) one topic, many alarms — every alarm we add is one line of `alarm
> → topic` config, not a fresh email pipeline. Classic fan-out pattern.

---

## 6. `alarms.tf` — the things worth waking you up

These are the **classic SRE alarm targets**: traffic errors, saturation,
latency, and downstream health. Each one names the resource it watches and the
threshold that says "something's actually wrong."

```hcl
# terraform/observability/alarms.tf

locals {
  alb_arn_suffix     = data.terraform_remote_state.compute.outputs.alb_arn_suffix
  asg_name           = data.terraform_remote_state.compute.outputs.asg_name
  target_group_arn   = data.terraform_remote_state.compute.outputs.target_group_arn
  db_identifier      = data.terraform_remote_state.database.outputs.db_identifier
  audit_function     = data.terraform_remote_state.audit.outputs.function_name
  contact_function   = data.terraform_remote_state.contact.outputs.function_name
  audit_table        = data.terraform_remote_state.audit.outputs.table_name
}

# --- ALB --------------------------------------------------------------------

# 5xx coming OUT of the ALB itself (target group can't serve OR ALB is misbehaving).
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx"
  alarm_description   = "ALB returned >= 5 HTTP 5xx in the last 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = local.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
  ok_actions    = [aws_sns_topic.ops.arn]
}

# ZERO healthy targets means the app is down.
resource "aws_cloudwatch_metric_alarm" "alb_no_healthy" {
  alarm_name          = "${var.project}-alb-no-healthy-hosts"
  alarm_description   = "Target group has 0 healthy hosts"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions = {
    LoadBalancer = local.alb_arn_suffix
    TargetGroup  = replace(local.target_group_arn, "/^.*targetgroup\\//", "targetgroup/")
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}

# --- RDS --------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-rds-cpu-high"
  alarm_description   = "RDS CPU > 80% for 10 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = local.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project}-rds-storage-low"
  alarm_description   = "RDS free storage < 2 GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = local.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024 # 2 GB in bytes
  comparison_operator = "LessThanThreshold"

  alarm_actions = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.project}-rds-connections-high"
  alarm_description   = "RDS connections > 80 (db.t3.micro caps around ~100)"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = local.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.ops.arn]
}

# --- Lambda -----------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "audit_errors" {
  alarm_name          = "${var.project}-audit-lambda-errors"
  alarm_description   = "Audit Lambda errored at least once in 5 minutes"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.audit_function }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}

resource "aws_cloudwatch_metric_alarm" "contact_errors" {
  alarm_name          = "${var.project}-contact-lambda-errors"
  alarm_description   = "Contact Lambda errored at least once in 5 minutes"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.contact_function }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}

# --- DynamoDB ---------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ddb_throttles" {
  alarm_name          = "${var.project}-ddb-throttled"
  alarm_description   = "Audit table threw any throttled request in 5 min"
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  dimensions          = { TableName = local.audit_table }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
}
```

> 🧠 **Pick thresholds you'd actually want to know about.** "ALB returned any
> 5xx ever" pages you constantly. "ALB returned ≥ 5 in five minutes" filters
> noise. The "actionable, not noisy" line is what separates real alarms from
> alarm fatigue. Document the *why* of each threshold in the description — your
> future on-call self will thank you.

> ⚠️ **You'll need these outputs from the other stacks** to make the alarms
> resolve cleanly: from `compute/`, `alb_arn_suffix` and `db_identifier` won't
> exist by default — add them. Pattern:
> ```hcl
> # in terraform/compute/outputs.tf
> output "alb_arn_suffix" { value = aws_lb.app.arn_suffix }
> # in terraform/database/outputs.tf
> output "db_identifier" { value = aws_db_instance.main.id }
> ```
> Re-apply those stacks (no resources change — just new outputs published),
> then come back here.

---

## 7. `dashboard.tf` — one screen, the whole system

```hcl
# terraform/observability/dashboard.tf

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title = "ALB — Requests & 5xx",
          region = var.aws_region,
          view   = "timeSeries", stacked = false, period = 60,
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",           "LoadBalancer", local.alb_arn_suffix, { stat = "Sum" }],
            [".",                  "HTTPCode_ELB_5XX_Count", ".",            ".",                  { stat = "Sum", yAxis = "right" }],
            [".",                  "TargetResponseTime",     ".",            ".",                  { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title = "ALB — Healthy hosts",
          region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount",   "LoadBalancer", local.alb_arn_suffix, { stat = "Average" }],
            [".",                  "UnHealthyHostCount", ".",            ".",                  { stat = "Average" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title = "RDS — CPU, connections, free storage",
          region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [
            ["AWS/RDS", "CPUUtilization",        "DBInstanceIdentifier", local.db_identifier, { stat = "Average" }],
            [".",       "DatabaseConnections",   ".",                    ".",                 { stat = "Average", yAxis = "right" }],
            [".",       "FreeStorageSpace",      ".",                    ".",                 { stat = "Minimum",  yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title = "Lambdas — invocations & errors",
          region = var.aws_region, view = "timeSeries", period = 60,
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.audit_function,   { stat = "Sum" }],
            [".",          "Errors",      ".",            ".",                    { stat = "Sum" }],
            [".",          "Invocations", ".",            local.contact_function, { stat = "Sum" }],
            [".",          "Errors",      ".",            ".",                    { stat = "Sum" }],
          ]
        }
      },
    ]
  })
}
```

After apply, find it at **CloudWatch → Dashboards → cloudcare-overview**. It
gives you one screen with traffic, errors, latency, healthy hosts, RDS, and
Lambda health — the SRE "is everything ok?" view.

---

## 8. `outputs.tf`

```hcl
# terraform/observability/outputs.tf

output "ops_topic_arn" {
  value       = aws_sns_topic.ops.arn
  description = "Add more subscriptions (Slack, PagerDuty) to this ARN"
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}
```

---

## 9. Apply, confirm the email, and verify

```bash
cd terraform/observability
terraform init
terraform fmt
terraform validate
terraform plan          # ~12-14 to add
terraform apply
```

**Check your email** — AWS sent a "Confirm subscription" message. Click the
link or you'll get no alerts. Confirm it's `Confirmed`:

```bash
aws sns list-subscriptions-by-topic --topic-arn $(terraform output -raw ops_topic_arn) \
  --query 'Subscriptions[].{Email:Endpoint,Status:SubscriptionArn}' --output table
```

Trigger one alarm to prove the pipe works (set it to ALARM manually):

```bash
aws cloudwatch set-alarm-state \
  --alarm-name cloudcare-audit-lambda-errors \
  --state-value ALARM --state-reason "manual test"
```

Within ~30 seconds you should receive an email subject "ALARM:
cloudcare-audit-lambda-errors". Set it back so you know recovery emails work
too:

```bash
aws cloudwatch set-alarm-state \
  --alarm-name cloudcare-audit-lambda-errors \
  --state-value OK --state-reason "manual test recovery"
```

Then open the dashboard in the console and watch it for a few minutes — you
should see live metrics tick by.

---

## 10. Bonus: a useful Logs Insights query

CloudWatch **Logs Insights** lets you SQL-ish over log groups. Save this query
for your audit Lambda — it's the query you'd reach for when "the audit feature
feels slow":

```
fields @timestamp, @duration, @message
| filter @message like /REPORT/
| sort @duration desc
| limit 20
```

> 🧠 Lambda's `REPORT` line per invocation contains `Duration`, `Billed
> Duration`, and `Memory Used` — this query pulls the 20 slowest recent
> invocations. Same pattern works on the FastAPI/EC2 logs once you push them to
> CloudWatch.

---

## 11. The three cost tools (you've already started)

You set up **Budgets** in Doc 03 — that's the alerting tool. The other two:

| Tool | What it does | How to turn on |
|------|--------------|----------------|
| **Cost Explorer** | Visual breakdowns of spend by service, tag, account — *the* tool for "where is the money going?" | Console → Cost Management → Cost Explorer → **Enable Cost Explorer** (free; takes ~24 h to populate the first time) |
| **Compute Optimizer** | ML-based "your instance is 4× too big" recommendations across EC2, EBS, Lambda | Console → Compute Optimizer → **Opt in** (free; needs ~14 days of metrics to produce recommendations) |

> 💰 **The cost feedback loop** is: Budgets warns you fast, Cost Explorer shows
> you what's costing money, Compute Optimizer suggests how to shrink it. Knowing
> all three by name and what each does is a small thing that makes you sound
> *operational*.

> 💡 **Tag-driven cost attribution.** Every stack's `default_tags` sets
> `Project = "cloudcare"`. Enable that as a **cost-allocation tag** in
> Billing → Cost Allocation Tags and Cost Explorer will let you filter "show me
> only CloudCare spend." Trivially valuable in multi-project accounts.

---

## 12. 💰 Cost & teardown

| Resource | Cost |
|----------|------|
| CloudWatch alarms | first 10/month free, then $0.10/alarm/month |
| CloudWatch dashboards | first 3/month free, then $3/dashboard/month |
| SNS email notifications | first 1,000/month free |
| Cost Explorer / Compute Optimizer | free |

> 💰 **Leave this stack up** — it's effectively free at our usage and the dashboard
> + alarms are what *make* the rest of the stack operable. To remove:
> ```bash
> terraform destroy   # in terraform/observability/
> ```

---

## ✅ Checkpoint — end of Phase 7 🎉

You're ready for Phase 8 when:

- [ ] `terraform/observability/` is applied and the SNS email is **confirmed**.
- [ ] You triggered an alarm via `set-alarm-state` and got the email.
- [ ] The dashboard loads in the console with live metrics.
- [ ] Cost Explorer is enabled and Compute Optimizer is opted in.

And you can explain, from memory:

- The metrics / logs / traces trio and where each lives in this stack.
- Why one SNS topic fans alarms out to many channels.
- A specific alarm threshold and *why* you picked it.
- What "actionable, not noisy" means for an alert.

Next: **[19 — CI/CD with GitHub Actions](19-cicd-github-actions.md)** — wire
this whole project to GitHub: OIDC federation (no stored AWS keys), Terraform
plan-on-PR / apply-on-main, automatic backend image builds, frontend deploys to
S3 + CloudFront invalidation. The grown-up way to ship changes.
