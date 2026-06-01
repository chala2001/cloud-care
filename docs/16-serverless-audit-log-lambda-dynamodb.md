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

> 🧠 **Three policies, three scopes.** `BasicExecutionRole` is the standard
> log-to-CloudWatch grant. `AWSXRayDaemonWriteAccess` is the standard "emit
> traces" grant. The DynamoDB policy is *our own inline* one, restricted to the
> exact actions on the exact table ARN — least privilege by hand. Granting
> `dynamodb:*` on `*` is the lazy mistake; don't do it.

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

> 🧠 **`source_code_hash`** is what makes Terraform redeploy the function when
> `lambda_function.py` changes. Without it, Terraform compares only resource
> arguments — not the zip contents — and a code change would be invisible.

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

---

## 10. Apply & verify

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

### Hit the API

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

### See the X-Ray trace

```bash
echo "Open the AWS Console → CloudWatch → X-Ray traces, or the Service map."
```

Pick any recent invocation: you'll see a timeline showing the **API Gateway →
Lambda init/handler → DynamoDB PutItem/Scan** subsegments. This is the
distributed-tracing view that makes "where is the latency?" answerable in one
glance.

> 🧠 **Why this is the X-Ray demo phase:** the 3-tier path is mostly *one*
> process (FastAPI) doing one DB call — easy to reason about with logs. The
> serverless path is a *graph* of services (Gateway → Lambda → DynamoDB → maybe
> more Lambdas) — tracing is the only sane way to see end-to-end latency.

### Inspect logs

```bash
aws logs tail "/aws/lambda/$(terraform output -raw function_name)" --since 5m
```

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

## ✅ Checkpoint

You're ready for Doc 17 when:

- [ ] `terraform/serverless-audit/` is applied (~12 resources).
- [ ] `curl POST /events` then `GET /events` round-trip through Lambda+DynamoDB.
- [ ] You can find the request in the **X-Ray service map** and inspect a trace.
- [ ] You can explain: when to choose Lambda over EC2, why we used HTTP API not
      REST, and what `Active` tracing actually gives you.

Next: **[17 — Serverless Contact Form: Lambda + SES](17-serverless-contact-form-lambda-ses.md)**
— a second serverless slice where a contact form on the React frontend POSTs to
API Gateway → Lambda → **SES**, emailing the hospital admin without any server
involved.
