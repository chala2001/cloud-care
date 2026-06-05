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

## 0. Beginner read-me first — vocabulary in one place

This doc introduces CloudWatch's domain language plus SNS and the cost tools.

| Word | Plain-English meaning |
|---|---|
| **Observability** | The ability to ask questions about a running system that you didn't pre-define. The three pillars are metrics, logs, traces. |
| **Metric** | A numeric value sampled over time (e.g. "ALB requests per minute"). |
| **Namespace** | The product family a metric belongs to: `AWS/ApplicationELB`, `AWS/RDS`, `AWS/Lambda`, `AWS/DynamoDB`, etc. |
| **Dimension** | A label that identifies *which* resource the metric is for. ALB uses `LoadBalancer`; RDS uses `DBInstanceIdentifier`; Lambda uses `FunctionName`. **Wrong dimension value = no data.** |
| **Statistic** | How you aggregate the raw datapoints — `Sum`, `Average`, `Minimum`, `Maximum`, `SampleCount`, `pXX` percentiles. |
| **Period** | The seconds covered by each aggregated datapoint (`60` = per-minute, `300` = per-5-minute). |
| **Evaluation periods** | How many consecutive periods must breach before the alarm fires. `2` reduces flapping. |
| **Datapoints to alarm** | Used with `evaluation_periods` to say "fire if M of the last N periods breach." |
| **`treat_missing_data`** | What to do when CloudWatch has no datapoint: `notBreaching`, `breaching`, `ignore`, `missing`. |
| **`comparison_operator`** | `>`, `>=`, `<`, `<=` — the condition that defines breach. |
| **Alarm** | A rule on a metric that flips between `OK`/`ALARM`/`INSUFFICIENT_DATA` and fires `alarm_actions`/`ok_actions` on state changes. |
| **Composite alarm** | An alarm whose state is a boolean of *other* alarms (`A AND (B OR C)`). Reduces noise. |
| **SNS** (Simple Notification Service) | AWS's pub/sub. You publish to a **topic**; SNS fans out to all **subscriptions**. |
| **Subscription** | An endpoint that receives topic messages — `email`, `sms`, `https`, `lambda`, `sqs`, etc. |
| **Subscription confirmation** | For `email` subscriptions, AWS sends a "Confirm subscription" link the user must click before delivery starts. |
| **Fan-out** | One publish → many subscribers. The reason we route all alarms through one topic. |
| **CloudWatch Dashboard** | A user-defined collection of widgets (graphs, numbers, text) you save for one view. JSON under the hood. |
| **Logs Insights** | A SQL-ish query language to search/aggregate CloudWatch Logs across log groups. |
| **Budget (AWS Budgets)** | A configurable spending target that sends notifications when actual or forecast exceeds it. |
| **Cost Explorer** | A visual tool for breaking down spend by service, tag, or account. Needs to be enabled (free, ~24h delay). |
| **Compute Optimizer** | ML-driven rightsizing recommendations across EC2, EBS, Lambda. Free; needs ~14 days of metrics. |
| **Cost-allocation tag** | A tag enabled in the billing console so Cost Explorer can filter by it (e.g. `Project=cloudcare`). |

Now the why.

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

### The four "golden signals" SRE alarms target

This is the Google SRE Book's classic framework. Every alarm in this doc
maps to one:

| Signal | Question | Example here |
|---|---|---|
| **Latency** | "How long does a request take?" | `TargetResponseTime` on the ALB |
| **Traffic** | "How much work am I doing?" | `RequestCount`, `Invocations` |
| **Errors** | "How often does work fail?" | `HTTPCode_ELB_5XX_Count`, Lambda `Errors` |
| **Saturation** | "How full are the moving parts?" | RDS `CPUUtilization`, `DatabaseConnections`, `FreeStorageSpace`, DynamoDB `ThrottledRequests` |

Skip one and your blind spots become outages.

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

### File-purpose table

| File | One-line purpose |
|---|---|
| `providers.tf` | AWS provider + S3 backend at `observability/`. |
| `variables.tf` | Inputs: region, project, **and `alert_email` (no default — required)**. |
| `data.tf` | Read 4 other stacks' outputs (compute, database, audit, contact). |
| `sns.tf` | One topic + one email subscription. |
| `alarms.tf` | 8 alarms covering ALB, RDS, both Lambdas, DynamoDB. |
| `dashboard.tf` | One 4-widget overview dashboard. |
| `outputs.tf` | Publish the topic ARN + dashboard name. |

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

### Walk-through — what's new

| Line | Meaning |
|---|---|
| `key = "observability/terraform.tfstate"` | New isolated state path. |
| `variable "alert_email" { ... }` no default | Forces you to set it — otherwise Terraform prompts (or fails in CI). Prevents accidentally emailing a stale address. |

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

### Walk-through

This is the **most cross-stack-reads of any folder in the project** — observability sits at the center, watching everyone else. Each `data` block follows the same pattern: read the other stack's `terraform.tfstate` from the same S3 bucket.

| Reads | Used for |
|---|---|
| `compute` | ALB ARN suffix, ASG name, target group ARN |
| `database` | RDS instance identifier |
| `audit` | Lambda function name + DynamoDB table name |
| `contact` | Lambda function name |

> 💡 If a stack isn't applied right now (e.g., you torn `compute` down to save
> money), the alarms that reference it won't have anything to watch, and apply
> here will fail to read its outputs. Either keep those stacks up while running
> observability, or comment out the corresponding alarms.

> ⚠️ **The big cross-stack pitfall.** Observability needs outputs that aren't
> in the upstream stacks by default — `alb_arn_suffix` (compute) and
> `db_identifier` (database). You'll get `Unsupported attribute` errors on
> `plan` until you **add those outputs upstream, then re-apply** those stacks.
> The pattern: ① add the output → ② apply the upstream (publishes the value
> into its state) → ③ now you can `terraform apply` here. The §6 ⚠️ box has
> the exact snippets.

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

### Walk-through

#### Block 1 — the topic
| Line | Meaning |
|---|---|
| `resource "aws_sns_topic" "ops"` | Create the topic. A topic is a pub/sub channel — alarms publish to it, subscriptions receive. |
| `name = "${var.project}-ops-alerts"` | AWS-visible name → `cloudcare-ops-alerts`. |

#### Block 2 — the email subscription
| Line | Meaning |
|---|---|
| `topic_arn = aws_sns_topic.ops.arn` | Subscribe to the topic above. |
| `protocol = "email"` | Delivery mechanism. Other values: `sms`, `https`, `lambda`, `sqs`, `application` (mobile push). |
| `endpoint = var.alert_email` | The actual email address. |

#### The confirmation step (manual)

When Terraform creates the email subscription, **AWS sends a "Confirm
subscription" email to the address.** Until you click the link, the
subscription stays in `PendingConfirmation` and **alarms are silently
dropped** for that endpoint. Standard anti-abuse — prevents one account from
spamming arbitrary inboxes.

> 🧠 **Why an SNS topic between alarm and email?** Two reasons: (1) one topic,
> many channels — add a Slack webhook subscription later without touching every
> alarm; (2) one topic, many alarms — every alarm we add is one line of `alarm
> → topic` config, not a fresh email pipeline. Classic fan-out pattern.

### Adding a Slack/Lambda subscription later

```hcl
resource "aws_sns_topic_subscription" "ops_slack" {
  topic_arn = aws_sns_topic.ops.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier.arn  # a Lambda that posts to Slack
}
```

Add the subscription; every existing alarm now delivers to Slack too. **You
never touched a single alarm definition.** That's the value of the fan-out.

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

### Walk-through — the anatomy of one alarm

Every alarm follows the same shape:

```
WHICH metric:    namespace + metric_name + dimensions
HOW to summarize: statistic over a period
WHEN to fire:    threshold + comparison_operator + evaluation_periods
WHAT to do:      alarm_actions (and optionally ok_actions)
```

Let's read the **`alb_5xx`** alarm field by field, then repeat the pattern for the others.

#### The `locals` block at the top

```hcl
locals {
  alb_arn_suffix     = data.terraform_remote_state.compute.outputs.alb_arn_suffix
  asg_name           = data.terraform_remote_state.compute.outputs.asg_name
  ...
}
```

`locals` define reusable named values. Without them every alarm would repeat
the long `data.terraform_remote_state.compute.outputs.alb_arn_suffix` chain.
With them, alarms read like `dimensions = { LoadBalancer = local.alb_arn_suffix }` — cleaner.

#### Alarm 1 — ALB 5xx errors

```hcl
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
```

| Field | Meaning |
|---|---|
| `alarm_name` | Console-visible name → `cloudcare-alb-5xx`. |
| `alarm_description` | Shows on the alarm page and in alert emails. **Put the *threshold rationale* here** so future on-call can decide if it still makes sense. |
| `namespace = "AWS/ApplicationELB"` | Which AWS service publishes this metric. |
| `metric_name = "HTTPCode_ELB_5XX_Count"` | The specific metric. **5xx from the ALB itself** (e.g. it gave up routing) — separate from `HTTPCode_Target_5XX_Count` (5xx from the backend). |
| `dimensions = { LoadBalancer = local.alb_arn_suffix }` | **Which ALB to watch.** Dimension name `LoadBalancer`, value = the ALB's ARN suffix (the bit after `loadbalancer/`). Wrong value here = no data = silent alarm. |
| `statistic = "Sum"` | Aggregate datapoints in the period by **summing**. Sum is right for a counter; for a gauge (CPU %) you'd use `Average`. |
| `period = 300` | Five-minute buckets. |
| `evaluation_periods = 1` | Fire after **1** consecutive breach. |
| `threshold = 5` | Breach: ≥ 5 fives in 5 minutes. |
| `comparison_operator = "GreaterThanOrEqualToThreshold"` | The `≥` operator. Other values: `>`, `<`, `<=`. |
| `treat_missing_data = "notBreaching"` | If there's no data (no traffic at all), do **not** fire. Other values: `breaching`, `ignore`, `missing`. |
| `alarm_actions = [aws_sns_topic.ops.arn]` | When state flips to ALARM, publish to our SNS topic. |
| `ok_actions = [aws_sns_topic.ops.arn]` | When state flips **back** to OK, also publish. **Recovery emails matter** — without them, on-call doesn't know when the issue cleared. |

#### Alarm 2 — Zero healthy targets

```hcl
dimensions = {
  LoadBalancer = local.alb_arn_suffix
  TargetGroup  = replace(local.target_group_arn, "/^.*targetgroup\\//", "targetgroup/")
}
```

The `HealthyHostCount` metric requires **both** `LoadBalancer` and
`TargetGroup` dimensions. The target-group dimension wants the format
`targetgroup/<name>/<id>` — extracted from the full ARN via a regex `replace`.

| Function | Meaning |
|---|---|
| `replace(STRING, REGEX, REPLACEMENT)` | Terraform's regex replace. |
| Regex `"/^.*targetgroup\\//"` | Match everything up to (and including) `targetgroup/`. Note the **doubled backslash** because both Terraform's HCL string parser and the regex engine want to consume a backslash. |
| Replacement `"targetgroup/"` | Replace that part with just `targetgroup/` — effectively strips the `arn:aws:elasticloadbalancing:...:targetgroup/` prefix. |

The result is what CloudWatch's `TargetGroup` dimension expects:
`targetgroup/cloudcare-app-tg/82e463d1b2482a0e`.

Other interesting fields:
- `period = 60` — check **every minute** for this one. Downtime should page faster.
- `evaluation_periods = 2` — **2 minutes of zero healthy hosts** before firing. Reduces flapping during a routine rolling restart.
- `treat_missing_data = "breaching"` — if there's literally no data, **fire** (something is very wrong if CloudWatch isn't even getting metrics).
- `comparison_operator = "LessThanThreshold"`, `threshold = 1` — "fewer than 1 healthy host" = "zero."

#### Alarms 3-5 — RDS saturation

The three RDS alarms cover three different saturation modes:

| Alarm | What it catches |
|---|---|
| `rds_cpu` | CPU above 80% for 10 minutes — possibly slow queries / runaway loops |
| `rds_storage` | Free storage below 2 GB — disk will fill and writes will start failing |
| `rds_connections` | More than 80 connections — `db.t3.micro` caps near 100; pool leak |

The pattern is the same as ALB but with `AWS/RDS` namespace and
`DBInstanceIdentifier` dimension. `threshold = 2 * 1024 * 1024 * 1024` is 2 GB
in bytes — the metric is reported in bytes, so we have to convert.

#### Alarms 6-7 — Lambda errors

```hcl
namespace   = "AWS/Lambda"
metric_name = "Errors"
dimensions  = { FunctionName = local.audit_function }
```

The Lambda namespace publishes `Errors` (count of failed invocations),
`Invocations`, `Duration`, `Throttles`, etc. **`Errors >= 1 in 5 minutes`**
is the catch-all "the function broke" alarm. Tune higher for chatty functions.

#### Alarm 8 — DynamoDB throttling

```hcl
namespace   = "AWS/DynamoDB"
metric_name = "ThrottledRequests"
dimensions  = { TableName = local.audit_table }
```

DynamoDB throttles when sustained traffic exceeds provisioned capacity. With
`PAY_PER_REQUEST` billing this is rare (auto-scales), but spike-of-spikes can
still trigger it. **Any throttle = wake me up** so we can investigate.

> 🧠 **Pick thresholds you'd actually want to know about.** "ALB returned any
> 5xx ever" pages you constantly. "ALB returned ≥ 5 in five minutes" filters
> noise. The "actionable, not noisy" line is what separates real alarms from
> alarm fatigue. Document the *why* of each threshold in the description — your
> future on-call self will thank you.

### The upstream outputs you must add first

> ⚠️ **You'll need these outputs from the other stacks** to make the alarms
> resolve cleanly: from `compute/`, `alb_arn_suffix` and from `database/`,
> `db_identifier` won't exist by default — add them. Pattern:
> ```hcl
> # in terraform/compute/outputs.tf
> output "alb_arn_suffix" { value = aws_lb.app.arn_suffix }
> # in terraform/database/outputs.tf
> output "db_identifier" { value = aws_db_instance.main.id }
> ```
> Re-apply those stacks (no resources change — just new outputs published),
> then come back here.

This is the **classic cross-stack outputs cascade** — adding a reference here
requires publishing the value upstream first. Standard `terraform_remote_state`
pattern: state changes upstream don't propagate downstream until you re-apply
both.

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

### Walk-through — the dashboard JSON

CloudWatch dashboards are **JSON documents** describing widgets. Terraform's
`jsonencode()` turns the HCL map into the JSON the API wants.

#### The grid layout

```hcl
x = 0,  y = 0,  width = 12, height = 6
x = 12, y = 0,  width = 12, height = 6
x = 0,  y = 6,  width = 12, height = 6
x = 12, y = 6,  width = 12, height = 6
```

The grid is **24 units wide**; rows are stacked by `y`. Each widget is 12 wide
× 6 tall → a 2×2 grid of half-width widgets.

#### The compressed metric format

CloudWatch widgets use a **compressed array form** for metrics:

```
["namespace", "metric_name", "dimension_name", "dimension_value", { stat = "Sum" }]
```

When two metrics share the namespace or dimension, you can use **`"."`** as a
shorthand meaning "same as the row above":

```
["AWS/ApplicationELB", "RequestCount",           "LoadBalancer", local.alb_arn_suffix, { stat = "Sum" }],
[".",                  "HTTPCode_ELB_5XX_Count", ".",            ".",                  { stat = "Sum", yAxis = "right" }],
```

Reads as: same namespace, different metric, same dimension key, same dimension
value. Saves a lot of repetition.

#### `yAxis = "right"`

Each widget has two y-axes (left + right). Putting metrics on different axes
keeps a wildly different scale (request count: thousands; latency: 0.1 seconds)
from squishing each other to invisibility.

#### Where to find it after apply

**CloudWatch → Dashboards → `cloudcare-overview`** — one screen showing
traffic + errors + latency on the ALB, healthy/unhealthy host count, RDS
saturation, Lambda invocations/errors. The "is everything OK?" view.

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

| Output | Used for |
|---|---|
| `ops_topic_arn` | If you later want to add a Slack or Lambda subscription from another stack, you'd reference this ARN. |
| `dashboard_name` | Mostly informational. Useful in scripts. |

---

## 9. Apply, confirm the email, and verify

### Step 1 — Add the missing upstream outputs first (if you haven't)

If you haven't already added `alb_arn_suffix` to `terraform/compute/outputs.tf`
and `db_identifier` to `terraform/database/outputs.tf`, do that now and
**re-apply** both stacks. Without these, observability's `plan` fails with
`Unsupported attribute`. See the ⚠️ box in §6.

### Step 2 — Apply observability

```bash
cd terraform/observability
terraform init
terraform fmt
terraform validate
terraform plan          # ~12-14 to add
terraform apply
```

What happens during apply:
1. Read all 4 remote states.
2. Create the SNS topic.
3. Create the email subscription → **AWS sends a confirmation email**.
4. Create 8 alarms.
5. Create the dashboard.
6. Outputs printed.

### Step 3 — Click the SNS confirmation email

**Check your email** — AWS sent a "Confirm subscription" message from
`no-reply@sns.amazonaws.com`. Click the link or you'll get no alerts. Confirm
it's `Confirmed`:

```bash
aws sns list-subscriptions-by-topic --topic-arn $(terraform output -raw ops_topic_arn) \
  --query 'Subscriptions[].{Email:Endpoint,Status:SubscriptionArn}' --output table
```

A pending sub shows `Status: PendingConfirmation`. A confirmed one shows the
full subscription ARN.

### Step 4 — Test the alarm-to-email pipe end-to-end

Trigger one alarm manually (set its state to ALARM):

```bash
aws cloudwatch set-alarm-state \
  --alarm-name cloudcare-audit-lambda-errors \
  --state-value ALARM --state-reason "manual test"
```

**Decoded:**
- `set-alarm-state` — manually override an alarm's state for testing. Useful exactly for verifying the alert pipe.
- `--state-value ALARM` — flip to ALARM. Other values: `OK`, `INSUFFICIENT_DATA`.
- `--state-reason "manual test"` — required string explaining why you set it.

Within ~30 seconds you should receive an email subject "ALARM:
cloudcare-audit-lambda-errors". Set it back so you know recovery emails work
too:

```bash
aws cloudwatch set-alarm-state \
  --alarm-name cloudcare-audit-lambda-errors \
  --state-value OK --state-reason "manual test recovery"
```

You should receive a second email subject "OK: cloudcare-audit-lambda-errors".
Both directions working = pipe is healthy.

### Step 5 — Open the dashboard

In the AWS Console: **CloudWatch → Dashboards → `cloudcare-overview`**. Watch
it tick by. Trigger a few `curl`s against the ALB and the audit API — the
request counts should rise on the dashboard within ~1 minute.

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

### Logs Insights query language in plain English

| Clause | Meaning |
|---|---|
| `fields @timestamp, @duration, @message` | Which columns to display. `@xxx` are special pre-populated fields. |
| `filter @message like /REPORT/` | Only rows whose message matches the regex `REPORT`. Lambda emits a `REPORT` line per invocation with duration + memory used. |
| `sort @duration desc` | Slowest invocations first. |
| `limit 20` | Top 20 results. |

> 🧠 Lambda's `REPORT` line per invocation contains `Duration`, `Billed
> Duration`, and `Memory Used` — this query pulls the 20 slowest recent
> invocations. Same pattern works on the FastAPI/EC2 logs once you push them to
> CloudWatch.

### Other handy queries

Find errors in any Lambda log group:
```
fields @timestamp, @message
| filter @message like /ERROR/ or @message like /Traceback/
| sort @timestamp desc
| limit 50
```

Count requests per IP (run on ALB access logs):
```
stats count(*) by client_ip
| sort count desc
```

---

## 11. The three cost tools (you've already started)

You set up **Budgets** in Doc 03 — that's the alerting tool. The other two:

| Tool | What it does | How to turn on |
|------|--------------|----------------|
| **Cost Explorer** | Visual breakdowns of spend by service, tag, account — *the* tool for "where is the money going?" | Console → Cost Management → Cost Explorer → **Enable Cost Explorer** (free; takes ~24 h to populate the first time) |
| **Compute Optimizer** | ML-based "your instance is 4× too big" recommendations across EC2, EBS, Lambda | Console → Compute Optimizer → **Opt in** (free; needs ~14 days of metrics to produce recommendations) |

### The cost feedback loop

```
Budgets  ──►  emails you when spend exceeds a target
                                          │
                                          ▼
Cost Explorer  ◄────  "where exactly is the money going?"
                                          │
                                          ▼
Compute Optimizer  ◄──  "this EC2 is 4× too big"
                                          │
                                          ▼
You shrink/right-size the resources → bill drops
```

> 💰 **The cost feedback loop** is: Budgets warns you fast, Cost Explorer shows
> you what's costing money, Compute Optimizer suggests how to shrink it. Knowing
> all three by name and what each does is a small thing that makes you sound
> *operational*.

### Tag-driven cost attribution

Every stack's `default_tags` sets `Project = "cloudcare"`. Enable that as a
**cost-allocation tag** in **Billing → Cost Allocation Tags** → activate
`Project`. Cost Explorer will then let you filter "show me only CloudCare
spend." Trivially valuable in multi-project accounts. Takes ~24h to populate
after activation.

> 💡 In a real org you'd add more attribution tags: `Environment=prod|staging`,
> `Owner=team-name`, `CostCenter=...`. Compute Optimizer + tag-filtered Cost
> Explorer = the foundation of any "show me our cloud spend" engineering review.

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

## 13. Plain-English summary (what you just built)

If asked to explain Phase 7:

1. **One SNS topic** (`cloudcare-ops-alerts`) with one email subscription.
   Pattern: many alarms publish to one topic; topic fans out to many channels.
2. **8 CloudWatch alarms** covering the four golden signals across the stack:
   ALB 5xx + no-healthy-hosts (errors/saturation), RDS CPU/storage/connections
   (saturation), both Lambdas' Errors (errors), DynamoDB ThrottledRequests
   (saturation).
3. **One CloudWatch dashboard** (`cloudcare-overview`) with four widgets:
   ALB traffic+5xx+latency, ALB healthy hosts, RDS saturation, Lambda
   invocations+errors. The "is everything OK?" view.
4. **Two new outputs upstream** — `alb_arn_suffix` (compute) and
   `db_identifier` (database) — needed so CloudWatch metric dimensions resolve.
5. **One Logs Insights query** saved as a starting point for "find slow
   Lambda invocations."
6. **The three cost tools enabled**: Budgets (Doc 03), Cost Explorer, Compute
   Optimizer, with `Project=cloudcare` activated as a cost-allocation tag.

---

## 14. Interview soundbites

- **Three pillars** — *"Logs tell you what one request did. Metrics tell you
  what all requests are doing. Traces stitch a single request across
  services. You need all three. This project has CloudWatch Logs for Lambdas
  and Logs Insights to search them, CloudWatch Metrics fed by ALB/RDS/Lambda/
  DynamoDB automatically, and X-Ray Active tracing on Lambdas for cross-service
  spans."*

- **Four golden signals** — *"Every alarm here maps to latency, traffic,
  errors, or saturation. Skip one and that becomes your blind spot. So we
  alarm `TargetResponseTime` for latency, `RequestCount` for traffic,
  `5XX_Count` + Lambda `Errors` for errors, RDS CPU/storage/connections +
  DDB throttles for saturation."*

- **SNS fan-out pattern** — *"All alarms publish to one SNS topic, then the
  topic fans out to subscribers. Adding Slack/PagerDuty/SMS later is one
  subscription resource, not a config touch on every alarm. The decoupling is
  the value."*

- **Actionable, not noisy** — *"`>= 5 5xxs in 5 min` filters routine errors;
  `any 5xx ever` would page you constantly. The threshold should mean 'a
  human should look now,' not 'something happened.' I document the threshold
  rationale in the alarm description so future on-call can re-evaluate."*

- **Recovery emails matter** — *"Both `alarm_actions` and `ok_actions` point
  at the topic. Without OK actions, on-call doesn't know when the issue
  cleared and the system might silently flap. The dashboard plus the OK email
  together close that loop."*

- **`treat_missing_data` choice** — *"For `5xx_count` we use `notBreaching` —
  no traffic means no errors, don't fire. For `HealthyHostCount` we use
  `breaching` — no data means CloudWatch isn't getting metrics at all, which
  is itself an emergency. Pick per-alarm based on what 'no data' means in
  context."*

- **Cross-stack outputs cascade** — *"Observability sits at the center and
  reads outputs from compute, database, audit, contact. Adding a new dimension
  (like `alb_arn_suffix`) requires publishing the output upstream first, then
  re-applying — a `terraform_remote_state` pitfall worth knowing."*

- **The cost feedback loop** — *"Budgets warns when spend exceeds a target.
  Cost Explorer breaks down where it went — filtered by tags for per-project
  spend. Compute Optimizer recommends rightsizing for EC2/EBS/Lambda. All
  free, all need ~24h to ~14d to populate. Together they're how you stay
  cost-aware in production."*

---

## ✅ Checkpoint — end of Phase 7 🎉

You're ready for Phase 8 when:

- [ ] `terraform/observability/` is applied and the SNS email is **confirmed**.
- [ ] You triggered an alarm via `set-alarm-state` and got the email.
- [ ] The dashboard loads in the console with live metrics.
- [ ] Cost Explorer is enabled and Compute Optimizer is opted in.
- [ ] You can read every alarm in `alarms.tf` and explain its 4 W's (which
      metric, how to summarize, when to fire, what to do).

And you can explain, from memory:

- The metrics / logs / traces trio and where each lives in this stack.
- Why one SNS topic fans alarms out to many channels.
- A specific alarm threshold and *why* you picked it.
- What "actionable, not noisy" means for an alert.
- The cross-stack outputs cascade pitfall (and the `alb_arn_suffix` /
  `db_identifier` story specifically).

Next: **[19 — CI/CD with GitHub Actions](19-cicd-github-actions.md)** — wire
this whole project to GitHub: OIDC federation (no stored AWS keys), Terraform
plan-on-PR / apply-on-main, automatic backend image builds, frontend deploys to
S3 + CloudFront invalidation. The grown-up way to ship changes.
