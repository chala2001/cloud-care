# 16 — Serverless: API Gateway + Lambda + DynamoDB + X-Ray

> **Goal of this doc:** build the first **serverless slice** from the original
> architecture — an **audit log** feature where requests hit an **HTTP API
> Gateway**, invoke a **Lambda** function, and read/write **DynamoDB**, with every
> request traced by **AWS X-Ray**. No servers to manage; no idle cost. This is the
> first half of **Phase 6 — Serverless**.

⏱️ Time: ~75 minutes. 💰 Cost: **~$0** — everything here has a generous
**always-free** tier (Lambda 1M reqs/mo, DynamoDB 25 GB, X-Ray 100k traces/mo,
API Gateway HTTP API tiny per request).

---

## 0. Beginner read-me first — vocabulary in one place

This doc introduces a totally different model from Phases 2–4. New vocabulary:

| Word | Plain-English meaning |
|---|---|
| **Serverless** | A model where you provide just the function code; the cloud runs it on demand and you pay only for the milliseconds it runs. **No idle servers.** |
| **FaaS** (Function-as-a-Service) | The category of services like Lambda. You ship a function; AWS does everything else. |
| **Lambda** | AWS's FaaS. Triggered by events (HTTP requests, S3 uploads, queue messages, schedules, …). |
| **Cold start** | The first invocation of a Lambda after idle — AWS provisions a container, loads runtime + code (~100–500 ms). |
| **Warm start** | Subsequent invocations reuse the container (~few ms). |
| **Runtime** | Which language environment the function runs in (`python3.12`, `nodejs20.x`, `java21`, etc.). |
| **Handler** | The specific function in your code that Lambda calls (`lambda_function.lambda_handler`). |
| **`event` / `context`** | The two args every Lambda handler receives. `event` = the trigger's payload; `context` = runtime info (request id, time remaining). |
| **Payload format 2.0** | The modern, slimmer event shape API Gateway HTTP API sends to Lambda. Different from REST API's v1.0. |
| **API Gateway** | AWS service that exposes Lambdas (and other backends) as HTTP endpoints with routing, auth, throttling. |
| **HTTP API vs REST API** | Two flavors of API Gateway. HTTP API is newer/cheaper/simpler; REST API is older/feature-heavier. We use HTTP API. |
| **Integration** | The wiring between API Gateway and the backend (Lambda, ALB, HTTP URL). `AWS_PROXY` = pass the raw HTTP request to the Lambda. |
| **Route** | A "VERB /path" combination (e.g. `POST /events`) → an integration. |
| **Stage** | A named version of the API exposed at a URL. `$default` is the special "no path prefix" stage. |
| **`auto_deploy = true`** | The stage automatically picks up route/integration changes — no manual deployment step. |
| **`source_code_hash`** | A hash of the deployed Lambda zip. Terraform compares it to detect code changes and force a redeploy. |
| **DynamoDB** | AWS's managed NoSQL key/value + document database. Single-digit-millisecond reads/writes. |
| **Partition key (hash key)** | The required primary-key column DynamoDB uses to shard data across servers. |
| **Sort key (range key)** | An optional second key column letting you query items within one partition by range/order. |
| **Composite primary key** | A `(partition key, sort key)` pair — uniquely identifies an item. |
| **GSI** (Global Secondary Index) | A separate index on different keys for different access patterns. |
| **`Scan` vs `Query`** | `Scan` reads the whole table (slow + expensive at scale). `Query` reads one partition (fast + cheap). |
| **PAY_PER_REQUEST vs PROVISIONED** | On-demand pricing (per-request) vs reserved capacity. On-demand for spiky/low; provisioned for steady/high. |
| **PITR** (Point-In-Time Recovery) | DynamoDB's continuous backup — restore to any second in the last 35 days. Free for first 35 days. |
| **X-Ray** | AWS's distributed-tracing service. Each request becomes a trace; each component a subsegment. |
| **Active tracing** (`tracing_config { mode = "Active" }`) | Lambda + X-Ray integration that auto-instruments AWS SDK calls. Free up to 100k traces/mo. |
| **Subsegment** | One step inside a trace (e.g. "DynamoDB PutItem took 12 ms"). |
| **`archive` provider** | Terraform helper that zips local files. We use it to build the Lambda deployment package. |
| **CloudWatch Log Group** | The container for a service's logs. Each Lambda writes to `/aws/lambda/<function-name>`. |
| **Retention** | How long CloudWatch keeps logs. Default = forever (cost trap). We set 7 days. |
| **Lambda permission** | A resource-based policy on the Lambda that says "this principal may invoke me." Required for API Gateway to invoke a Lambda. |

Now the architecture.

---

## 1. What we're building (and why a separate "serverless" path)

```
                          Internet
                              │  HTTPS
                              ▼
                ┌────── Amazon API Gateway (HTTP API) ───────┐
                │   POST /events   ──► Lambda  ──► DynamoDB  │
                │   GET  /events   ──► Lambda  ──► DynamoDB  │
                │                       (traced by X-Ray)    │
                └─────────────────────────────────────────────┘
```

This sits **outside** the VPC. There's no EC2, no ALB, no patching, no scaling
config — Lambda runs your function on demand and AWS handles everything else.
You pay per request + per ms of execution. At our usage this is functionally
free.

### Two architectures, side by side

| | 3-tier (Phases 1–4) | Serverless (this Phase 6) |
|---|---|---|
| Compute | EC2 in ASG, always-on | Lambda, on-demand |
| Storage | RDS Postgres | DynamoDB |
| Edge | ALB + CloudFront | API Gateway |
| You pay when idle? | ✅ Yes (EC2/RDS/ALB hours) | ❌ No |
| Best for | steady, stateful, complex workloads | spiky, event-driven, simple workloads |

> 🧠 **Why two architectures in one project (interview)?** "Steady, stateful,
> long-running work (the FastAPI app reading patient data) lives on EC2 +
> RDS — the *3-tier* path. Spiky, event-driven, simple work (writing audit events)
> lives on Lambda + DynamoDB — the *serverless* path. Each model suits different
> workloads; using both deliberately is a sign you understand the trade-offs."

What the audit log does: records small events (e.g., "patient #42 created at
12:30 by user X") in DynamoDB and lets you query them back. In a real CloudCare
the FastAPI app would POST to it whenever something happens; for now we exercise
it directly with `curl`.

---

## 2. The Terraform folder

A new stack with its own state key:

```
terraform/
├── …existing stacks…
└── serverless-audit/         ← Phase 6, Doc 16 — THIS doc
    ├── providers.tf
    ├── variables.tf
    ├── iam.tf
    ├── dynamodb.tf
    ├── lambda.tf             # zips + deploys the function
    ├── apigw.tf              # HTTP API + routes + integration
    ├── outputs.tf
    └── src/
        └── lambda_function.py
```

### What each file's job is

| File | One-line purpose |
|---|---|
| `providers.tf` | Connect to AWS; add the `archive` provider; store state under `serverless/audit/`. |
| `variables.tf` | Inputs: region, project name. |
| `dynamodb.tf` | The audit table, on-demand billing, PITR enabled. |
| `iam.tf` | Lambda role with 3 scoped grants: logs, X-Ray, DDB-on-this-table-only. |
| `src/lambda_function.py` | The actual function code — POST writes, GET scans, else 405. |
| `lambda.tf` | Zip `src/`, pre-create the log group, deploy the function. |
| `apigw.tf` | The HTTP API + integration + 2 routes + stage + invoke permission. |
| `outputs.tf` | Publish API URL, table name, function name. |

---

## 3. `providers.tf` and `variables.tf`

```hcl
# terraform/serverless-audit/providers.tf
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "serverless/audit/terraform.tfstate"
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
      Component = "serverless-audit"
    }
  }
}
```

```hcl
# terraform/serverless-audit/variables.tf
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix"
  type        = string
  default     = "cloudcare"
}
```

### Walk-through — what's new vs other stacks' providers files

| Line | Meaning |
|---|---|
| `required_providers.archive` | **NEW** — HashiCorp's `archive` provider. Builds zip files locally at apply time. We use it in `lambda.tf` to package `src/` into a Lambda deployment zip. |
| `key = "serverless/audit/terraform.tfstate"` | New state isolation path. Sits at `serverless/audit/` (not just `audit/`) so a sibling `serverless/contact/` (Doc 17) sits next to it cleanly. |
| `Component = "serverless-audit"` | Default tag — distinct from the contact stack's tag, so CloudWatch/Cost-Explorer queries can split them. |

> 🧠 **The `archive` provider** is HashiCorp's helper for zipping local files —
> we'll use it to build the Lambda deployment package straight from `src/`. No
> external build step or CI required.

---

## 4. `dynamodb.tf` — the audit table

```hcl
# terraform/serverless-audit/dynamodb.tf

resource "aws_dynamodb_table" "audit" {
  name         = "${var.project}-audit"
  billing_mode = "PAY_PER_REQUEST" # on-demand → pay per request, ~free at our scale
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  # Point-in-time recovery is free for the first 35 days of restore window and
  # is a one-line safety net you should default to.
  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "${var.project}-audit" }
}
```

### Walk-through — line by line

| Line | Meaning |
|---|---|
| `resource "aws_dynamodb_table" "audit"` | Create a DynamoDB table; nickname `audit`. |
| `name = "${var.project}-audit"` | AWS-visible name → `cloudcare-audit`. |
| `billing_mode = "PAY_PER_REQUEST"` | **On-demand pricing.** Pay per request, no capacity reservation. Cheap at low/spiky volumes (~free at lab scale). The alternative `PROVISIONED` reserves read/write capacity 24/7 — cheaper at steady high throughput. |
| `hash_key = "event_id"` | The **partition key** — the column DynamoDB uses to shard items across servers. Required. |
| `attribute { name = "event_id", type = "S" }` | Declare the key column. `S` = String (other options: `N` = Number, `B` = Binary). **Only key columns need to be declared up front** — DynamoDB is schemaless for the rest, so the item we'll write later can have `ts`, `action`, `actor` without declaring them. |
| `point_in_time_recovery { enabled = true }` | Turn on continuous backups (free for the first 35 days of restore window). One-line safety net. |
| `tags = { Name = "${var.project}-audit" }` | Console label. |

### How DynamoDB key design differs from SQL

| Concept | SQL/RDS | DynamoDB |
|---|---|---|
| Primary key | `id INT PRIMARY KEY` | `partition_key` + optional `sort_key` |
| Schema | Defined up front | Only keys are declared; other attributes per item |
| Default read | `SELECT * FROM ...` (any column) | `Query` by key (fast) or `Scan` (slow + scans everything) |
| Cross-attribute queries | indexes you add to columns | Global Secondary Index (GSI) — a parallel index on different keys |

> 🧠 **`PAY_PER_REQUEST` vs `PROVISIONED`.** Provisioned = you reserve read/write
> capacity 24/7 (cheaper at high steady load). On-demand = pay per request
> (cheaper for spiky/low workloads). For a learning app you'll never reach the
> 25 GB + tiny request always-free tier — on-demand is the right pick.

> 💡 **The schema is intentionally minimal** (`event_id` as the only key). To list
> recent events we'll **`Scan`** the table — fine at our size, *bad* in production.
> Real apps use a partition key like `pk = "AUDIT"` plus a sort key on timestamp,
> or a **Global Secondary Index** on `ts`, to query time-sorted events without
> scanning. Mention this in interviews as the "access-pattern-driven schema" idea.

---

## 5. `iam.tf` — least-privilege Lambda role

```hcl
# terraform/serverless-audit/iam.tf

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "audit" {
  name               = "${var.project}-audit-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# CloudWatch Logs (every Lambda needs this) — basic execution.
resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.audit.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# X-Ray daemon write — lets the Lambda emit trace segments.
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.audit.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# Scoped DynamoDB access — only the audit table, only the actions we use.
data "aws_iam_policy_document" "audit_table" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:Scan", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
}

resource "aws_iam_role_policy" "audit_table" {
  name   = "${var.project}-audit-table-rw"
  role   = aws_iam_role.audit.id
  policy = data.aws_iam_policy_document.audit_table.json
}
```

### Walk-through — same role shape as EC2, different trust principal

#### Block 1 — trust policy (the "who can wear me" rule)

```hcl
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]   # ← Lambda, not EC2
    }
  }
}
```

Same shape as the EC2 role's trust document, but the principal is **`lambda.amazonaws.com`** instead of `ec2.amazonaws.com`. *"Only the Lambda service may assume this role."*

#### Block 2 — the role itself
```hcl
resource "aws_iam_role" "audit" {
  name               = "${var.project}-audit-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
```
Creates the role with the trust document. No permissions yet.

#### Block 3 — basic execution (CloudWatch Logs)
```hcl
resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.audit.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
```

`AWSLambdaBasicExecutionRole` is an **AWS-managed** policy granting:
- `logs:CreateLogGroup`
- `logs:CreateLogStream`
- `logs:PutLogEvents`

**Every Lambda needs this.** Without it, the function runs but `print()` /
`logger.info()` output goes nowhere — invisible debugging.

#### Block 4 — X-Ray write
```hcl
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.audit.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}
```

`AWSXRayDaemonWriteAccess` grants `xray:PutTraceSegments` and friends. Required
when `tracing_config.mode = "Active"` is set on the Lambda (next file) — the
runtime auto-emits trace segments using this permission.

#### Blocks 5 & 6 — scoped DynamoDB access

```hcl
data "aws_iam_policy_document" "audit_table" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:Scan", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
}

resource "aws_iam_role_policy" "audit_table" {
  name   = "${var.project}-audit-table-rw"
  role   = aws_iam_role.audit.id
  policy = data.aws_iam_policy_document.audit_table.json
}
```

**This is your own custom policy, not an AWS-managed one.** Note:
- **Only 3 actions** — `PutItem` (write), `Scan` (list all), `GetItem` (read one). Not `dynamodb:*`.
- **Only 1 resource** — exactly this table's ARN. Not `*`.

Note also: it's `aws_iam_role_policy` (without `_attachment`), which means an
**inline** policy directly attached to the role — appropriate for a per-role,
per-resource custom rule.

> 🧠 **Three policies, three scopes.** `BasicExecutionRole` is the standard
> log-to-CloudWatch grant. `AWSXRayDaemonWriteAccess` is the standard "emit
> traces" grant. The DynamoDB policy is *our own inline* one, restricted to the
> exact actions on the exact table ARN — least privilege by hand. Granting
> `dynamodb:*` on `*` is the lazy mistake; don't do it.

### Summary of what the role can do

| Power | Granted by |
|---|---|
| Write its own logs to CloudWatch | `AWSLambdaBasicExecutionRole` |
| Send trace segments to X-Ray | `AWSXRayDaemonWriteAccess` |
| `PutItem`/`Scan`/`GetItem` on **the audit table only** | inline `audit_table` policy |

Nothing else. If this Lambda is ever compromised, the blast radius is reading
or writing one DynamoDB table — not the whole account.

---

## 6. `src/lambda_function.py` — the function code

Create the folder `terraform/serverless-audit/src/` and inside it
`lambda_function.py`:

```python
# terraform/serverless-audit/src/lambda_function.py
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def _resp(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method")

    if method == "POST":
        body = json.loads(event.get("body") or "{}")
        item = {
            "event_id":    str(uuid.uuid4()),
            "ts":          datetime.now(timezone.utc).isoformat(),
            "entity_type": body.get("entity_type", "unknown"),
            "entity_id":   str(body.get("entity_id", "")),
            "action":      body.get("action", "unknown"),
            "actor":       body.get("actor", "system"),
        }
        TABLE.put_item(Item=item)
        return _resp(201, item)

    if method == "GET":
        # Simple Scan with a hard limit — fine at our size; see §4 for the
        # production pattern (GSI on a timestamp sort key).
        resp = TABLE.scan(Limit=50)
        return _resp(200, {"items": resp.get("Items", [])})

    return _resp(405, {"error": "method not allowed"})
```

### Walk-through

#### Module-level setup (runs **once per cold start**, reused for warm)

```python
TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
```

| Piece | Meaning |
|---|---|
| `boto3.resource("dynamodb")` | The high-level boto3 DynamoDB client. |
| `.Table(os.environ["TABLE_NAME"])` | Open a handle on the table named in the `TABLE_NAME` env var (which we set in `lambda.tf`). |
| `TABLE = ...` | **Module-level assignment.** This runs **at cold start** and is **cached** across subsequent invocations on the same container. So warm starts skip this — much faster. This is the "init outside the handler" optimization every Lambda guide repeats. |

#### The response helper

```python
def _resp(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=str),
    }
```

| Line | Meaning |
|---|---|
| Return shape with `statusCode`, `headers`, `body` | **What API Gateway expects** for payload format 2.0. API Gateway converts this dict into the actual HTTP response. |
| `json.dumps(body, default=str)` | Serialize the dict. `default=str` handles types JSON doesn't know natively (e.g. `datetime` → its ISO string). |

#### The handler

```python
def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method")
```

| Piece | Meaning |
|---|---|
| `lambda_handler(event, context)` | The **Lambda contract** — every handler takes these two. `event` = the trigger's payload (here, the HTTP request from API Gateway); `context` = runtime info (request id, time remaining, log group). |
| `event.get("requestContext", {}).get("http", {}).get("method")` | For payload format 2.0, the HTTP verb lives at this nested path. `.get(..., {})` defensively handles missing keys (returns empty dict, no crash). |

#### The POST branch
```python
if method == "POST":
    body = json.loads(event.get("body") or "{}")
    item = {
        "event_id":    str(uuid.uuid4()),
        "ts":          datetime.now(timezone.utc).isoformat(),
        "entity_type": body.get("entity_type", "unknown"),
        ...
    }
    TABLE.put_item(Item=item)
    return _resp(201, item)
```

| Line | Meaning |
|---|---|
| `json.loads(event.get("body") or "{}")` | Parse the request body as JSON. `or "{}"` defaults to empty object if body is None. |
| `str(uuid.uuid4())` | Generate a random UUID (e.g. `b3f3b374-567d-4c89-97d5-20f83d811df8`) as the primary key. |
| `datetime.now(timezone.utc).isoformat()` | UTC ISO-8601 timestamp (e.g. `"2026-06-04T09:15:30.123456+00:00"`). |
| `body.get("entity_type", "unknown")` | Field with default — accepts missing fields gracefully. |
| `TABLE.put_item(Item=item)` | DynamoDB write. Single call; auto-traced by X-Ray. |
| `return _resp(201, item)` | Echo the written item back with HTTP 201 Created. |

#### The GET branch
```python
if method == "GET":
    resp = TABLE.scan(Limit=50)
    return _resp(200, {"items": resp.get("Items", [])})
```

| Line | Meaning |
|---|---|
| `TABLE.scan(Limit=50)` | **`Scan`** = read up to 50 items from anywhere in the table. **Cheap at our size; expensive at scale.** Production would use `Query` against a `(partition_key, sort_key)` design, or a GSI on the timestamp. |
| `resp.get("Items", [])` | The list of items (boto3 returns native Python dicts, not raw DynamoDB JSON). |

#### Fallback

```python
return _resp(405, {"error": "method not allowed"})
```

Any verb other than GET/POST → 405. The API Gateway routes are also locked to
`POST /events` and `GET /events`, so this is defensive — shouldn't happen.

> 🧠 **The handler signature `(event, context)`** is the Lambda contract — AWS
> passes the request as `event` and runtime info as `context`. For API Gateway
> HTTP API (payload format 2.0), `event["requestContext"]["http"]["method"]` is
> where the verb lives. The return shape (`statusCode`, `headers`, `body`) is
> what API Gateway turns into the HTTP response.

> 🧠 **No `Tracer.capture()` calls needed for X-Ray** — when we set
> `tracing_config { mode = "Active" }` on the function (next file), the Lambda
> runtime instruments calls to AWS SDKs automatically. Each DynamoDB call shows
> up as a subsegment. You only need to add manual annotations for custom spans.

---

## 7. `lambda.tf` — zip the code and create the function

```hcl
# terraform/serverless-audit/lambda.tf

# Build the deployment zip from src/. Re-runs when the .py file changes.
data "archive_file" "audit" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/audit.zip"
}

# Pre-create the log group so we control retention (else AWS auto-creates one
# with "never expire" — silently piling up data forever).
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/lambda/${var.project}-audit"
  retention_in_days = 7
}

resource "aws_lambda_function" "audit" {
  function_name = "${var.project}-audit"
  role          = aws_iam_role.audit.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"

  filename         = data.archive_file.audit.output_path
  source_code_hash = data.archive_file.audit.output_base64sha256

  timeout     = 10
  memory_size = 256

  tracing_config {
    mode = "Active" # X-Ray on
  }

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.audit.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.audit]
}
```

### Walk-through — three blocks

#### Block 1 — zip the code (the archive provider's job)

```hcl
data "archive_file" "audit" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/audit.zip"
}
```

| Line | Meaning |
|---|---|
| `data "archive_file" "audit"` | A data source from the `archive` provider. **Builds a zip locally at plan/apply time.** Not a resource — Terraform doesn't track it on AWS. |
| `type = "zip"` | Output format. |
| `source_dir = "${path.module}/src"` | Folder to zip. `path.module` = the directory this `.tf` file lives in. |
| `output_path = "${path.module}/build/audit.zip"` | Where to write the zip. Creates `build/` if needed. |

After this runs, `build/audit.zip` contains your `lambda_function.py` ready to
deploy.

#### Block 2 — pre-create the log group (retention control)

```hcl
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/lambda/${var.project}-audit"
  retention_in_days = 7
}
```

| Line | Meaning |
|---|---|
| `name = "/aws/lambda/${var.project}-audit"` | By convention, Lambda writes to `/aws/lambda/<function-name>`. We pre-create the log group with this exact name. |
| `retention_in_days = 7` | Keep logs 7 days, then auto-delete. |

> 🧠 **The "auto-created log group never expires" trap.** If you don't pre-create
> the log group, AWS will create it for you on the first invocation — with
> retention set to **"Never expire."** Logs pile up forever, slowly costing
> money. Pre-creating it with explicit retention is the standard professional
> hygiene step.

#### Block 3 — the Lambda function itself

```hcl
resource "aws_lambda_function" "audit" {
  function_name = "${var.project}-audit"
  role          = aws_iam_role.audit.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"
  ...
}
```

| Line | Meaning |
|---|---|
| `function_name = "${var.project}-audit"` | AWS-visible name → `cloudcare-audit`. |
| `role = aws_iam_role.audit.arn` | Wear the IAM role from `iam.tf`. The function runs **as** this role — all AWS API calls it makes use the role's permissions. |
| `runtime = "python3.12"` | Language environment. Other values: `nodejs20.x`, `java21`, `dotnet8`, `go1.x`, etc. |
| `handler = "lambda_function.lambda_handler"` | The entry point: **in the zip, find `lambda_function.py`, call the function named `lambda_handler`.** Mismatched filename here = the "ImportModuleError" you've seen. |

#### Code hash + deploy detection

```hcl
filename         = data.archive_file.audit.output_path
source_code_hash = data.archive_file.audit.output_base64sha256
```

| Line | Meaning |
|---|---|
| `filename = data.archive_file.audit.output_path` | Path to the zip. |
| `source_code_hash = data.archive_file.audit.output_base64sha256` | **Hash of the zip's contents.** Terraform compares it to the previously deployed hash. Different hash → trigger a redeploy. |

> 🧠 **`source_code_hash`** is what makes Terraform redeploy the function when
> `lambda_function.py` changes. Without it, Terraform compares only resource
> arguments — not the zip contents — and a code change would be invisible.

#### Sizing + tracing + env

```hcl
timeout     = 10
memory_size = 256

tracing_config {
  mode = "Active"
}

environment {
  variables = {
    TABLE_NAME = aws_dynamodb_table.audit.name
  }
}

depends_on = [aws_cloudwatch_log_group.audit]
```

| Line | Meaning |
|---|---|
| `timeout = 10` | Kill the function after 10 seconds. Default is 3s. |
| `memory_size = 256` | 256 MB RAM. **CPU scales with memory** in Lambda, so this is also a speed knob. Default is 128 MB. |
| `tracing_config { mode = "Active" }` | Turn X-Ray on. Lambda runtime auto-instruments **boto3 calls** — DynamoDB PutItem/Scan show up as subsegments in the trace, no code changes. |
| `environment { variables = { TABLE_NAME = ... } }` | Pass env vars into the container. The Python code reads `os.environ["TABLE_NAME"]`. |
| `depends_on = [aws_cloudwatch_log_group.audit]` | **Force ordering**: create the log group **before** the Lambda, so AWS doesn't auto-create the group with "never expire" retention. The reference *itself* doesn't create an ordering (no value is consumed), so we declare it explicitly. |

> 💡 **`memory_size = 256`** is overkill for this tiny function, but Lambda's CPU
> scales with memory. 128 MB works; 256 MB is a comfortable default for snappier
> cold starts. Always-free tier counts 400 GB-seconds/mo — at 256 MB that's
> 1.6M seconds (~444 hours) of execution. We're not going to run out.

---

## 8. `apigw.tf` — the HTTP API in front of it

```hcl
# terraform/serverless-audit/apigw.tf

# HTTP API is the newer, cheaper, simpler API Gateway flavor. Use it unless you
# need a feature only REST API has (e.g. resource policies, usage plans, WAF).
resource "aws_apigatewayv2_api" "audit" {
  name          = "${var.project}-audit-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"] # tighten to your CloudFront origin in production
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

# Tell API Gateway how to invoke the Lambda. AWS_PROXY = pass the raw HTTP
# request to Lambda; payload format 2.0 = the modern, slimmer event shape.
resource "aws_apigatewayv2_integration" "audit" {
  api_id                 = aws_apigatewayv2_api.audit.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.audit.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_events" {
  api_id    = aws_apigatewayv2_api.audit.id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.audit.id}"
}

resource "aws_apigatewayv2_route" "get_events" {
  api_id    = aws_apigatewayv2_api.audit.id
  route_key = "GET /events"
  target    = "integrations/${aws_apigatewayv2_integration.audit.id}"
}

# A stage publishes the API at a URL. "$default" + auto_deploy = changes go live
# on every apply, no manual deployment step needed.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.audit.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 50
    throttling_rate_limit    = 100
  }
}

# Permission: explicitly let THIS API invoke THIS Lambda (Lambda is locked down
# by default, so without this you'd get 500s with "not authorized to invoke").
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGwInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.audit.execution_arn}/*/*"
}
```

An API Gateway HTTP API is **5 resources** working together. Each does one job.

### Block 1 — the API

```hcl
resource "aws_apigatewayv2_api" "audit" {
  name          = "${var.project}-audit-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}
```

| Line | Meaning |
|---|---|
| `resource "aws_apigatewayv2_api"` | Create an API Gateway v2 API. v1 (`aws_api_gateway_*`) = REST API; v2 = HTTP/WebSocket. |
| `protocol_type = "HTTP"` | HTTP API (not WebSocket). |
| `cors_configuration { ... }` | **Built-in CORS** — no Lambda code needed. API Gateway returns the right headers automatically. |
| `allow_origins = ["*"]` | Any origin may call this. Tighten to your CloudFront URL in production. |
| `allow_methods = ["GET", "POST", "OPTIONS"]` | Verbs allowed by CORS. `OPTIONS` for preflight. |
| `allow_headers = ["content-type"]` | Custom headers callers may send. |

### Block 2 — the integration (how API GW invokes the Lambda)

```hcl
resource "aws_apigatewayv2_integration" "audit" {
  api_id                 = aws_apigatewayv2_api.audit.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.audit.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}
```

| Line | Meaning |
|---|---|
| `api_id = aws_apigatewayv2_api.audit.id` | Attach to our API. |
| `integration_type = "AWS_PROXY"` | The **proxy pattern**: just pass the raw HTTP request to the Lambda as `event`, no transformation. Other types: `HTTP_PROXY` (to a URL), `AWS` (templated), `MOCK`. |
| `integration_uri = aws_lambda_function.audit.invoke_arn` | Which Lambda to call. Note: `invoke_arn` (different from `arn`) is the special ARN API Gateway uses for invocation. |
| `integration_method = "POST"` | API Gateway calls Lambda over HTTP POST internally. (This is how Lambda is invoked under the hood; not related to the user's verb.) |
| `payload_format_version = "2.0"` | The slimmer, modern event shape we parse in `lambda_function.py`. v1.0 has a different structure. |

### Blocks 3 & 4 — the routes (URL → integration)

```hcl
resource "aws_apigatewayv2_route" "post_events" {
  api_id    = aws_apigatewayv2_api.audit.id
  route_key = "POST /events"
  target    = "integrations/${aws_apigatewayv2_integration.audit.id}"
}

resource "aws_apigatewayv2_route" "get_events" {
  api_id    = aws_apigatewayv2_api.audit.id
  route_key = "GET /events"
  target    = "integrations/${aws_apigatewayv2_integration.audit.id}"
}
```

| Line | Meaning |
|---|---|
| `route_key = "POST /events"` | The `VERB /path` combination this route matches. Special form: `$default` (catch-all). |
| `target = "integrations/${...integration.id}"` | Forward matched requests to our integration (and from there to Lambda). |

Two routes for two verbs, both pointing at the same integration → the same
Lambda. The handler branches on `method`.

### Block 5 — the stage (publishes the API at a URL)

```hcl
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.audit.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 50
    throttling_rate_limit    = 100
  }
}
```

| Line | Meaning |
|---|---|
| `name = "$default"` | The special "root" stage that doesn't add a path prefix. (Named stages like `v1` would produce URLs like `https://.../v1/events`.) |
| `auto_deploy = true` | Changes to routes/integrations go live automatically on apply — no separate deployment step. |
| `detailed_metrics_enabled = true` | Push per-route CloudWatch metrics (count, latency, 4xx/5xx). Free. |
| `throttling_burst_limit = 50` | Allow short bursts up to 50 req/s. |
| `throttling_rate_limit = 100` | Average rate limit, 100 req/s. **Caps your bill** if a runaway client appears. |

### Block 6 — the Lambda invoke permission (the easy-to-forget one)

```hcl
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGwInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.audit.execution_arn}/*/*"
}
```

| Line | Meaning |
|---|---|
| `statement_id = "AllowAPIGwInvoke"` | A unique ID for this permission statement. Lambda permissions are resource-based policies; each statement needs an ID. |
| `action = "lambda:InvokeFunction"` | The action being permitted. |
| `function_name = aws_lambda_function.audit.function_name` | Which Lambda this permission applies to. |
| `principal = "apigateway.amazonaws.com"` | Who is being permitted — the API Gateway service. |
| `source_arn = "${aws_apigatewayv2_api.audit.execution_arn}/*/*"` | **Scope the permission to this specific API.** `/*/*` allows any stage + any route within this one API. Without this, *any* API Gateway in your account could invoke this Lambda — security hole. |

**Lambda functions are locked down by default.** A Lambda can be invoked only
by principals explicitly allowed via `aws_lambda_permission`. Forget this
block and API Gateway will return 500 with `"not authorized to invoke"`.

> 🧠 **HTTP API vs REST API:** HTTP API is ~70% cheaper, faster to set up,
> supports CORS natively, and uses payload format 2.0. REST API is the older,
> heavier sibling with features like usage plans, API keys, request validation,
> and AWS WAF integration. For 90% of new serverless work, HTTP API is correct.

> 🧠 **`source_arn = ".../*/*"`** scopes the permission to *this* API (any
> stage, any route). Forgetting it means "any API in your account can invoke
> this Lambda" — a real security hole.

---

## 9. `outputs.tf`

```hcl
# terraform/serverless-audit/outputs.tf

output "api_url" {
  description = "Public endpoint of the audit HTTP API"
  value       = aws_apigatewayv2_api.audit.api_endpoint
}

output "table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.audit.name
}

output "function_name" {
  description = "Lambda function name (for inspecting logs / X-Ray)"
  value       = aws_lambda_function.audit.function_name
}
```

| Output | What it is |
|---|---|
| `api_url` | The auto-generated `https://<id>.execute-api.<region>.amazonaws.com` URL. With the `$default` stage and our route `POST /events`, you `curl ${api_url}/events`. |
| `table_name` | Useful for `aws dynamodb scan --table-name $(...)`. |
| `function_name` | Used by `aws logs tail /aws/lambda/$(...)` and the X-Ray console search. |

---

## 10. Apply & verify

### Step 1 — Apply

From inside `terraform/serverless-audit/`:

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

terraform init        # downloads aws + archive providers
terraform fmt
terraform validate
terraform plan
```

Expect roughly **`Plan: 12 to add, 0 to change, 0 to destroy.`** (DynamoDB,
IAM role + 3 policy/attachment, log group, Lambda, HTTP API, integration, 2
routes, stage, Lambda permission). The `archive_file` is a *data source* and
doesn't count.

```bash
terraform apply       # type "yes"
```

What happens during apply:
1. The archive provider zips `src/lambda_function.py` → `build/audit.zip`.
2. DynamoDB table created (instant).
3. IAM role + 3 policy attachments (instant).
4. Log group created.
5. Lambda function created from the zip.
6. HTTP API created.
7. Integration + 2 routes + stage created.
8. Lambda permission attached (allows API GW to invoke).

### Step 2 — Hit the API

```bash
API=$(terraform output -raw api_url)

# Write an audit event:
curl -X POST "$API/events" -H "Content-Type: application/json" \
  -d '{"entity_type":"patient","entity_id":"42","action":"created","actor":"alice"}'

# Read the latest events back:
curl "$API/events"
```

The first call returns the new item (`event_id`, `ts`, …). The second returns
`{"items": [...]}` — proof the round-trip Lambda→DynamoDB→Lambda works.

### Step 3 — See the X-Ray trace

```bash
echo "Open the AWS Console → CloudWatch → X-Ray traces, or the Service map."
```

Pick any recent invocation: you'll see a timeline showing the **API Gateway →
Lambda init/handler → DynamoDB PutItem/Scan** subsegments. This is the
distributed-tracing view that makes "where is the latency?" answerable in one
glance.

#### What a trace tells you

| Subsegment | What it measures |
|---|---|
| API Gateway → Lambda | request routing time + Lambda init (cold start) or warm-start dispatch |
| Lambda handler total | total time your code ran |
| `DynamoDB PutItem` / `Scan` | per-call latency to DynamoDB |
| Custom annotations | (only if you call `Tracer.put_annotation(...)` manually) |

For a 100ms total request, a typical breakdown might be: 50ms cold-start init,
30ms handler logic, 15ms DynamoDB call, 5ms response serialization. Anywhere
slow shows up immediately.

> 🧠 **Why this is the X-Ray demo phase:** the 3-tier path is mostly *one*
> process (FastAPI) doing one DB call — easy to reason about with logs. The
> serverless path is a *graph* of services (Gateway → Lambda → DynamoDB → maybe
> more Lambdas) — tracing is the only sane way to see end-to-end latency.

### Step 4 — Inspect logs

```bash
aws logs tail "/aws/lambda/$(terraform output -raw function_name)" --since 5m
```

**Decoded:**

- `aws logs tail` — stream a CloudWatch log group's recent entries.
- `"/aws/lambda/$(terraform output -raw function_name)"` — the log group's name. The `$( ... )` substitution prints `cloudcare-audit`, producing `/aws/lambda/cloudcare-audit`.
- `--since 5m` — only show logs from the last 5 minutes. Other formats: `1h`, `2d`, ISO timestamps.

You'll see one log entry per invocation, with the `print()` output from the
handler (if any), plus AWS-managed framing lines (`START RequestId: ...`,
`END RequestId: ...`, `REPORT` with duration + billed duration + memory used).

---

## 11. 💰 Cost & teardown

| Resource | Free-tier status |
|----------|------------------|
| Lambda | ✅ **1M requests + 400k GB-s/month always free** |
| DynamoDB (PAY_PER_REQUEST) | ✅ 25 GB + tiny request always free |
| API Gateway HTTP API | ~$1/M requests (well under $1/mo at lab scale) |
| X-Ray | ✅ 100k traces/month always free |
| CloudWatch Logs | ✅ 5 GB ingest/month free |

> 💰 **You can leave this stack up** — at our usage the bill is effectively zero.
> If you prefer the destroy-after-labs habit:
> ```bash
> terraform destroy   # in terraform/serverless-audit/
> ```
> Nothing else depends on it, so destroying is safe and instant.

---

## 12. Plain-English summary (what you just built)

If asked to explain Phase 6 part 1:

1. **One DynamoDB table** (`cloudcare-audit`) with `event_id` as the partition
   key, on-demand billing, PITR enabled.
2. **One Lambda function** (`cloudcare-audit`) written in Python 3.12, 256 MB,
   10s timeout, X-Ray Active tracing. Reads `TABLE_NAME` from env; POST writes,
   GET scans, else 405.
3. **One IAM role** with three scoped grants — logs, X-Ray write, and
   `PutItem/Scan/GetItem` on **just** the audit table ARN.
4. **One HTTP API Gateway** with two routes (`POST /events`, `GET /events`),
   AWS_PROXY integration, payload format 2.0, CORS, throttling, `$default`
   stage auto-deployed.
5. **One Lambda permission** allowing the API to invoke the function, scoped
   via `source_arn`.
6. **One pre-created log group** with 7-day retention.
7. End-to-end verified: `curl POST` then `curl GET` round-trip through
   Lambda + DynamoDB; trace visible in X-Ray.

---

## 13. Interview soundbites

- **Two architectures, deliberate choice** — *"The 3-tier path is right for
  steady, stateful work (FastAPI + RDS). The serverless slice — API Gateway +
  Lambda + DynamoDB — is right for event-driven, spiky writes like audit
  events. No idle cost, no scaling config, no patching."*

- **Lambda contract** — *"`lambda_handler(event, context)` is the contract.
  For API Gateway HTTP API with payload format 2.0, the HTTP verb lives at
  `event.requestContext.http.method`. The return shape with `statusCode`,
  `headers`, `body` becomes the actual HTTP response."*

- **`source_code_hash` triggers redeploys** — *"Terraform compares the hash of
  the deployed zip to detect code changes. Without `source_code_hash`, a
  Python edit wouldn't change any resource argument, and Terraform would think
  nothing's changed."*

- **HTTP API vs REST API** — *"HTTP API is ~70% cheaper, faster to set up,
  has built-in CORS, and uses payload format 2.0. REST API has features like
  usage plans, API keys, WAF integration, request validation. For 90% of new
  serverless work, HTTP API is the right pick."*

- **Lambda permissions** — *"Lambda is invoke-locked by default. Every
  invoker — API Gateway, EventBridge, S3 — needs an `aws_lambda_permission`
  with `source_arn` scoped to the specific invoker. Without it, the API
  returns 500 'not authorized to invoke'."*

- **Active tracing** — *"`tracing_config.mode = Active` plus the
  `AWSXRayDaemonWriteAccess` policy gives you per-request distributed traces
  with auto-instrumented AWS SDK subsegments. No code changes — boto3 calls
  appear as subsegments automatically."*

- **DynamoDB key design** — *"My schema is intentionally tiny — `event_id`
  hash-only with `Scan`. Production would use `(pk=AUDIT, sk=ts)` or a GSI on
  timestamp so I can `Query` for recent events without scanning. Access-pattern-
  driven schema is the DynamoDB design principle."*

- **The "auto log group" trap** — *"Lambda will auto-create its log group on
  first invocation **with retention=never**. I pre-create the log group in
  Terraform with `retention_in_days = 7` so logs don't pile up forever silently
  — small detail, real cost over time."*

---

## ✅ Checkpoint

You're ready for Doc 17 when:

- [ ] `terraform/serverless-audit/` is applied (~12 resources).
- [ ] `curl POST /events` then `GET /events` round-trip through Lambda+DynamoDB.
- [ ] You can find the request in the **X-Ray service map** and inspect a trace.
- [ ] You can explain: when to choose Lambda over EC2, why we used HTTP API not
      REST, and what `Active` tracing actually gives you.
- [ ] You can read every line of `lambda_function.py`, `lambda.tf`, and
      `apigw.tf` and explain it in plain English.

Next: **[17 — Serverless Contact Form: Lambda + SES](17-serverless-contact-form-lambda-ses.md)**
— a second serverless slice where a contact form on the React frontend POSTs to
API Gateway → Lambda → **SES**, emailing the hospital admin without any server
involved.
