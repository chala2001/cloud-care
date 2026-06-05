# 17 — Serverless: Contact Form (API Gateway + Lambda + SES)

> **Goal of this doc:** build the second serverless slice — a hospital **contact
> form** where a visitor submits `{name, email, message}` to an HTTP API, a
> Lambda formats it and sends an email via **Amazon SES** to the hospital admin
> inbox. Zero servers, zero idle cost. This completes **Phase 6 — Serverless**.

⏱️ Time: ~60 minutes (plus ~5 min to click two email verification links).
💰 Cost: **~$0** — SES is $0.10 per 1,000 emails, Lambda + API Gateway tiny.

---

## 0. Beginner read-me first — vocabulary in one place

SES (Simple Email Service) brings new vocabulary on top of the Lambda/API
Gateway terms from Doc 16. Re-read this whenever a term feels foreign.

| Word | Plain-English meaning |
|---|---|
| **SES** (Simple Email Service) | AWS's managed email-sending service. Like Gmail-as-an-API: your code calls `ses.send_email(...)` and AWS delivers it. |
| **Sandbox mode** | The restricted "training-wheels" state every new AWS account starts in for SES. Sender + recipient must be verified; tight daily caps. |
| **Production access** | The mode after AWS verifies your account. Only sender needs verification; you can email any recipient; bigger sending caps. Requested via a short form. |
| **Identity** | A verified email address or domain. SES will only send to/from things it has identities for (in sandbox). |
| **Verified / Unverified** | Whether you clicked AWS's "confirm" link for that identity. Required for sandbox sends. |
| **`aws_sesv2_email_identity`** | Terraform resource that registers an address/domain with SES. **Creating the resource sends the verification email; clicking is up to a human.** |
| **`ses:SendEmail`** | The IAM action permitting the function to call SES's SendEmail API. |
| **`ses:FromAddress` condition** | An IAM condition that pins the role to a specific From address — even if the code changes, IAM refuses a different sender. |
| **`MessageRejected`** | SES's error when sending is blocked — usually because an identity isn't verified yet. |
| **`FromEmailAddress`** | The From address SES uses on the sent email. Must match a verified identity (in sandbox). |
| **`ReplyToAddresses`** | Address(es) the recipient's "Reply" button targets. Different from the From — lets the admin reply to the visitor, not to your no-reply sender. |
| **DKIM/SPF/DMARC** | Email-authenticity standards. AWS handles them for `*.amazonses.com` domains; you'd configure them on your own domain for production. |
| **Gmail `+` aliasing** | A trick where `user+tag@gmail.com` and `user@gmail.com` both deliver to the same inbox, but SES treats them as **different identities**. Useful when you want sender ≠ recipient but only have one inbox. |
| **AWS-managed `cors_configuration`** | API Gateway HTTP API handles CORS preflight/headers automatically — no Lambda code needed for `OPTIONS`. |
| **Throttling burst vs rate** | API Gateway throttling has two knobs: `burst` = max instantaneous; `rate` = sustained req/s. |
| **`MessageRejected: Email address is not verified`** | The classic sandbox error — recheck your identities. |

Now the architecture.

---

## 1. What we're building

```
   Visitor (React frontend)
        │  POST /contact  {name,email,message}
        ▼
   API Gateway (HTTP API)
        │
        ▼
       Lambda  ──── ses:SendEmail ───►  Amazon SES  ───►  📧 admin@example
```

No EC2, no queue, no servers. The form button POSTs JSON; an email lands in the
hospital admin's inbox a moment later.

> 🧠 **Why Lambda + SES instead of letting FastAPI send the mail?** Two reasons:
> (1) it's the right scaling shape — the form fires rarely, so paying for idle
> servers makes no sense; (2) it's **isolation** — a bug in this code path can't
> bring down the patients API. Separate concerns → separate runtimes.

### How the three actors interact (and don't)

```
Terraform (at apply time)
   ├─► creates SES identities      → AWS auto-sends verification emails
   ├─► creates Lambda + IAM role
   ├─► creates API Gateway → Lambda integration
   └─► returns api_url

You (one-time, manual)
   └─► click the verification links in both inboxes

Runtime (each form submission)
   browser  ─► API Gateway (HTTP)   ─► Lambda   ─► SES SendEmail   ─► inbox
              (CORS, throttling)       (validates)  (IAM-gated)        (delivery)
```

The crucial bit: **Terraform can create the identities, but only a human clicking
the link "verifies" them.** Until that's done, `ses.send_email(...)` returns
`MessageRejected` and no mail arrives.

---

## 2. ⚠️ The SES sandbox (read first)

By default every AWS account starts SES in **sandbox mode**:

- You can only **send to** addresses you've **verified**.
- You can only **send from** addresses (or domains) you've **verified**.
- Daily caps are low (200/day sent, 1 msg/sec).

That's why this doc uses **two verified email identities** — a sender and a
recipient — and you'll receive two verification emails on apply that you **must
click** before sending works.

For a real launch you'd request **production access** in the SES console (a
short form; AWS reviews and lifts the sandbox). Mention this in interviews — "we
verified identities for the lab; production would request sandbox removal" — it
shows you know the operational gotcha.

### What changes between sandbox and production

| Restriction | Sandbox | Production |
|---|---|---|
| Recipient must be verified | ✅ yes | ❌ no — email anyone |
| Sender must be verified | ✅ yes | ✅ yes (or its domain via DKIM) |
| Daily cap | 200/day | starts at 50k/day, grows with reputation |
| Per-second rate | 1 msg/sec | starts at 14/sec, grows |
| Bounce/complaint tracking required | optional | yes (SES enforces handling) |

> 💡 **Same email for both is fine for the lab.** If you want to test entirely
> with your own inbox, use Gmail's `+` aliasing:
> - sender = `chalakasamith+sender@gmail.com`
> - recipient = `chalakasamith@gmail.com`
>
> Both deliver to the same Gmail inbox, but SES treats them as two distinct
> identities (no duplicate-identity error). You'll click two verification links
> in the same inbox.

---

## 3. The Terraform folder

A second serverless stack, separate key:

```
terraform/
├── …existing stacks…
├── serverless-audit/         ← Doc 16
└── serverless-contact/       ← THIS doc
    ├── providers.tf
    ├── variables.tf
    ├── terraform.tfvars.example
    ├── ses.tf                # the two verified identities
    ├── iam.tf
    ├── lambda.tf
    ├── apigw.tf
    ├── outputs.tf
    └── src/
        └── lambda_function.py
```

### File-purpose table

| File | One-line purpose |
|---|---|
| `providers.tf` | AWS + archive providers; state under `serverless/contact/`. |
| `variables.tf` | Inputs: region, project, **and the two email addresses (no defaults — required)**. |
| `terraform.tfvars.example` | Template of the variables you must supply (committed). Real `terraform.tfvars` (gitignored) holds your actual addresses. |
| `ses.tf` | Two `aws_sesv2_email_identity` resources — sender + recipient. |
| `iam.tf` | Lambda role with `AWSLambdaBasicExecutionRole` (logs) + a scoped `ses:SendEmail` policy. |
| `src/lambda_function.py` | The handler: validate body, call `ses.send_email`, return JSON. |
| `lambda.tf` | Zip `src/`, pre-create the log group, deploy the function. |
| `apigw.tf` | HTTP API + one route (`POST /contact`) + stage + invoke permission. |
| `outputs.tf` | Publish the full `/contact` URL + function name. |

---

## 4. `providers.tf` and `variables.tf`

```hcl
# terraform/serverless-contact/providers.tf
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws     = { source = "hashicorp/aws",     version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }

  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "serverless/contact/terraform.tfstate"
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
      Component = "serverless-contact"
    }
  }
}
```

```hcl
# terraform/serverless-contact/variables.tf
variable "aws_region" {
  description = "AWS region (use one where SES is available)"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix"
  type        = string
  default     = "cloudcare"
}

# Required — no defaults, so you can't accidentally email someone else's address.
variable "sender_email" {
  description = "Verified SES sender (the From: address shown to the recipient)"
  type        = string
}

variable "recipient_email" {
  description = "Verified SES recipient — the hospital admin inbox"
  type        = string
}
```

### Walk-through — the new bits

| Line | Meaning |
|---|---|
| `key = "serverless/contact/terraform.tfstate"` | New state path — sits next to `serverless/audit/`. |
| `Component = "serverless-contact"` | Distinct from the audit stack's tag → separate cost-explorer rows. |
| `variable "sender_email" / "recipient_email"` | **No `default`** — Terraform refuses to apply without values, forcing you to confirm both addresses. |

### Create a `terraform.tfvars` to supply the addresses

Create a `terraform.tfvars` next to it (gitignored — it has personal email
addresses, not secrets but still good to keep out of git):

```hcl
# terraform/serverless-contact/terraform.tfvars   (commit terraform.tfvars.example instead)
sender_email    = "chalaka@wso2.com"
recipient_email = "chalaka@wso2.com"
```

Or pass them on the command line:

```bash
terraform apply \
  -var='sender_email=chalakasamith+sender@gmail.com' \
  -var='recipient_email=chalakasamith@gmail.com'
```

> ⚠️ **If sender == recipient as the exact same string**, you'll get a
> "ResourceAlreadyExists" error when applying — the two `aws_sesv2_email_identity`
> resources collide on the same email. Either use **Gmail's `+` aliasing** to
> create two distinct strings that both deliver to one inbox, or pick two real
> addresses you control.

---

## 5. `ses.tf` — the verified identities

```hcl
# terraform/serverless-contact/ses.tf

# Each email identity must be confirmed by clicking a link AWS sends — Terraform
# can create the identity, but only you can verify it.
resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.sender_email
}

resource "aws_sesv2_email_identity" "recipient" {
  # If sender == recipient, this still creates a second identity entry pointing
  # at the same address (idempotent). It's harmless and keeps the dependency
  # graph clean.
  email_identity = var.recipient_email
}
```

### Walk-through

Two resources, identical shape, different inputs.

| Line | Meaning |
|---|---|
| `resource "aws_sesv2_email_identity" "sender"` | Register an SES identity. The `v2` suffix is the modern API; `v1` (`aws_ses_email_identity`) still works but is older. |
| `email_identity = var.sender_email` | The address to register. AWS auto-sends a verification email **to that address** when the resource is created. |

What happens during apply:

1. Terraform calls `CreateEmailIdentity` for the sender.
2. AWS sends `no-reply-aws@amazon.com` an email to that address with the verification link.
3. Same for the recipient.
4. **Terraform finishes** — the resources exist but with `VerificationStatus = PENDING`.
5. You (human) open the inbox, click the link.
6. SES flips the status to `SUCCESS`.

Until step 5, every `ses.send_email` call from the Lambda fails with
`MessageRejected: Email address is not verified`.

> 🧠 **Why both?** In sandbox mode SES rejects sends where *either* the From or
> any To/Cc/Bcc is unverified. Verifying the recipient too lets the lab actually
> deliver the email. In production with sandbox lifted, only the *sender* (or
> sender's domain) needs verification.

---

## 6. `iam.tf` — least-privilege send

```hcl
# terraform/serverless-contact/iam.tf

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "contact" {
  name               = "${var.project}-contact-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.contact.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ses:SendEmail, scoped to the SENDER identity ARN, AND a condition restricting
# the FromAddress to our exact sender — belt and braces.
data "aws_iam_policy_document" "send_email" {
  statement {
    actions   = ["ses:SendEmail"]
    resources = [aws_sesv2_email_identity.sender.arn]

    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.sender_email]
    }
  }
}

resource "aws_iam_role_policy" "send_email" {
  name   = "${var.project}-send-email"
  role   = aws_iam_role.contact.id
  policy = data.aws_iam_policy_document.send_email.json
}
```

### Walk-through

#### Blocks 1 & 2 — trust + the role (familiar pattern)

Same trust-policy + role pattern as Doc 16: principal is
`lambda.amazonaws.com`. The role exists; no permissions yet.

#### Block 3 — basic execution (CloudWatch Logs)

`AWSLambdaBasicExecutionRole` again — every Lambda needs this to write logs.

#### Block 4 — the scoped `ses:SendEmail` policy

```hcl
data "aws_iam_policy_document" "send_email" {
  statement {
    actions   = ["ses:SendEmail"]
    resources = [aws_sesv2_email_identity.sender.arn]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.sender_email]
    }
  }
}
```

| Line | Meaning |
|---|---|
| `actions = ["ses:SendEmail"]` | Just the one send action. No `ses:*`. |
| `resources = [aws_sesv2_email_identity.sender.arn]` | Just the **sender identity's** ARN — the role can't send via any other identity. |
| `condition { variable = "ses:FromAddress", values = [var.sender_email] }` | **Extra belt-and-braces**: only allow the call if the actual `From` address in the request equals our configured sender. If the code is modified to spoof another From, IAM refuses. |

> 🧠 **The `ses:FromAddress` condition** stops the function from being abused as
> a generic mailer for *any* sender on the account. Even if the Lambda code
> changed to pass a different `FromEmailAddress`, IAM would reject the call.
> Conditions like this are what make "least privilege" actually mean something.

#### Block 5 — attach the policy

```hcl
resource "aws_iam_role_policy" "send_email" {
  name   = "${var.project}-send-email"
  role   = aws_iam_role.contact.id
  policy = data.aws_iam_policy_document.send_email.json
}
```

`aws_iam_role_policy` (inline) — appropriate for a per-role custom rule.

### ⚠️ A subtle SES behavior worth knowing

When the **recipient address is also a verified identity** in your account
(common in sandbox where you verified both ends), SES checks
`ses:SendEmail` against **both** the sender identity ARN **and** the recipient
identity ARN. The policy above only allows the sender — so a send between two
of your own verified identities is **denied** with:

```
AccessDeniedException: User <role> is not authorized to perform
ses:SendEmail on resource <recipient identity ARN>
```

**The fix is to list both ARNs in the `resources` list:**

```hcl
resources = [
  aws_sesv2_email_identity.sender.arn,
  aws_sesv2_email_identity.recipient.arn,
]
```

The `FromAddress` condition still restricts the role to sending **as** the
sender only.

> 🧠 In real production, the recipient is some external `customer@example.com`
> (not verified in your account), so SES doesn't ask IAM about it — the original
> "just the sender ARN" policy works. The double-ARN trick is sandbox-specific.

---

## 7. `src/lambda_function.py` — the handler

Create `terraform/serverless-contact/src/lambda_function.py`:

> ⚠️ **Watch the filename.** Lambda's handler is `lambda_function.lambda_handler`,
> which means Lambda imports `lambda_function.py`. Typos like
> `lambda_funtion.py` (missing the `c`) produce
> `Runtime.ImportModuleError: Unable to import module 'lambda_function'` at
> invocation time — a brutal mismatch to debug without this hint.

```python
# terraform/serverless-contact/src/lambda_function.py
import json
import os

import boto3

ses = boto3.client("sesv2")
SENDER    = os.environ["SENDER_EMAIL"]
RECIPIENT = os.environ["RECIPIENT_EMAIL"]


def _resp(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method")
    if method != "POST":
        return _resp(405, {"error": "method not allowed"})

    try:
        body = json.loads(event.get("body") or "{}")
        name    = body["name"].strip()
        email   = body["email"].strip()
        message = body["message"].strip()
    except (KeyError, AttributeError, ValueError):
        return _resp(400, {"error": "name, email, and message are required"})

    if not (name and email and message):
        return _resp(400, {"error": "all fields must be non-empty"})

    ses.send_email(
        FromEmailAddress=SENDER,
        Destination={"ToAddresses": [RECIPIENT]},
        ReplyToAddresses=[email],   # reply goes to the submitter, not to ourselves
        Content={
            "Simple": {
                "Subject": {"Data": f"CloudCare contact from {name}"},
                "Body": {
                    "Text": {"Data": f"From: {name} <{email}>\n\n{message}"}
                },
            }
        },
    )

    return _resp(200, {"status": "sent"})
```

### Walk-through

#### Module-level setup (runs once per cold start)

```python
ses = boto3.client("sesv2")
SENDER    = os.environ["SENDER_EMAIL"]
RECIPIENT = os.environ["RECIPIENT_EMAIL"]
```

| Line | Meaning |
|---|---|
| `boto3.client("sesv2")` | The **low-level SESv2** client. `sesv2` is the modern API; `ses` (v1) still works but uses different param names. |
| `SENDER / RECIPIENT = os.environ[...]` | Read env vars set by `lambda.tf`. Module-level → cached across warm invocations. |

#### Method gate

```python
method = event.get("requestContext", {}).get("http", {}).get("method")
if method != "POST":
    return _resp(405, {"error": "method not allowed"})
```

Only POST is valid. Anything else (GET, PUT, etc.) → 405. Defense in depth —
the API Gateway route is also locked to `POST /contact`, but rejecting in code
is cheap.

#### Input validation

```python
try:
    body = json.loads(event.get("body") or "{}")
    name    = body["name"].strip()
    email   = body["email"].strip()
    message = body["message"].strip()
except (KeyError, AttributeError, ValueError):
    return _resp(400, {"error": "name, email, and message are required"})

if not (name and email and message):
    return _resp(400, {"error": "all fields must be non-empty"})
```

| Piece | Meaning |
|---|---|
| `json.loads(event.get("body") or "{}")` | Parse the request body as JSON. `or "{}"` defaults to empty if missing. |
| `body["name"].strip()` | Pull the field; `.strip()` removes leading/trailing whitespace. **Raises KeyError if the field is missing** — caught below. |
| `except (KeyError, AttributeError, ValueError)` | Catches: missing key, `.strip()` called on non-string, bad JSON. All become a clean 400. |
| `if not (name and email and message)` | Catch the "field present but empty string" case — also 400. |

> ⚠️ **The handler validates inputs by hand** — keep it strict at the edge. A
> public unauthenticated endpoint will get garbage payloads almost immediately;
> never trust the shape.

#### The send call

```python
ses.send_email(
    FromEmailAddress=SENDER,
    Destination={"ToAddresses": [RECIPIENT]},
    ReplyToAddresses=[email],
    Content={
        "Simple": {
            "Subject": {"Data": f"CloudCare contact from {name}"},
            "Body": {
                "Text": {"Data": f"From: {name} <{email}>\n\n{message}"}
            },
        }
    },
)
```

| Param | Meaning |
|---|---|
| `FromEmailAddress=SENDER` | The From address. **Must match a verified identity** (sandbox) and the `ses:FromAddress` IAM condition. |
| `Destination={"ToAddresses": [RECIPIENT]}` | Where to send. `ToAddresses` is a list; could be many. |
| `ReplyToAddresses=[email]` | **The submitter's email.** When the admin hits "Reply", it goes to the visitor — not back to our verified sender. |
| `Content.Simple.Subject.Data` | The subject line. |
| `Content.Simple.Body.Text.Data` | The plain-text body. There's also `Body.Html.Data` for an HTML version. |

The nested-dict shape is the SESv2 API's `EmailContent` schema — `Simple`
means "I'm providing subject + body inline" (vs `Raw` for full MIME or
`Template` for a saved SES template).

> 🧠 **`ReplyToAddresses=[email]`** is the small detail that makes the admin's
> "Reply" button do the right thing: their reply goes to the visitor, not back to
> the SES-verified sender (which is often a noreply alias). One line, big UX win.

---

## 8. `lambda.tf` — package & deploy

```hcl
# terraform/serverless-contact/lambda.tf

data "archive_file" "contact" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/contact.zip"
}

resource "aws_cloudwatch_log_group" "contact" {
  name              = "/aws/lambda/${var.project}-contact"
  retention_in_days = 7
}

resource "aws_lambda_function" "contact" {
  function_name = "${var.project}-contact"
  role          = aws_iam_role.contact.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"

  filename         = data.archive_file.contact.output_path
  source_code_hash = data.archive_file.contact.output_base64sha256

  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      SENDER_EMAIL    = var.sender_email
      RECIPIENT_EMAIL = var.recipient_email
    }
  }

  depends_on = [aws_cloudwatch_log_group.contact]
}
```

### Walk-through

Identical structure to Doc 16's `lambda.tf`. Differences worth noting:

| Difference | Meaning |
|---|---|
| `function_name = "${var.project}-contact"` | A different name → a different log group (`/aws/lambda/cloudcare-contact`). |
| `environment.variables.SENDER_EMAIL / RECIPIENT_EMAIL` | The Python code reads these via `os.environ`. They're set from the Terraform variables. |
| **No `tracing_config`** | X-Ray could be turned on here too, but it's not pedagogically needed — the audit stack already demonstrated it. Add `tracing_config { mode = "Active" }` + an attached `AWSXRayDaemonWriteAccess` policy if you want traces here. |

Everything else (archive zipping, pre-created log group, `source_code_hash`,
`depends_on`) works the same way as in Doc 16 §7.

---

## 9. `apigw.tf` — the public endpoint

```hcl
# terraform/serverless-contact/apigw.tf

resource "aws_apigatewayv2_api" "contact" {
  name          = "${var.project}-contact-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"] # tighten to your CloudFront origin in production
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_integration" "contact" {
  api_id                 = aws_apigatewayv2_api.contact.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.contact.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_contact" {
  api_id    = aws_apigatewayv2_api.contact.id
  route_key = "POST /contact"
  target    = "integrations/${aws_apigatewayv2_integration.contact.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.contact.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 10
    throttling_rate_limit    = 5   # contact form should never burst — anti-abuse
  }
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGwInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.contact.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.contact.execution_arn}/*/*"
}
```

This is structurally identical to Doc 16's `apigw.tf` with three deliberate
differences worth highlighting:

| Diff | Why |
|---|---|
| Only one route (`POST /contact`) instead of two | Contact form is single-purpose. |
| `allow_methods = ["POST", "OPTIONS"]` | Just what's needed. `OPTIONS` is the browser's CORS preflight verb. |
| `throttling_rate_limit = 5` (vs 100 for audit) | **Anti-abuse.** A real contact form should never get more than a handful of submissions per second. A bot hitting it would inflate your SES bill and blow the sandbox/production rate caps. |

> 🧠 **Tight throttling on a public form is a tiny abuse-prevention measure.** A
> bot hitting the form a thousand times a minute would (a) inflate your SES bill
> and (b) blow the SES sandbox/production rate limits. 5 req/s with a burst of 10
> is more than enough for a real hospital and saves you from common abuse.

---

## 10. `outputs.tf`

```hcl
# terraform/serverless-contact/outputs.tf

output "contact_api_url" {
  description = "Public POST /contact endpoint"
  value       = "${aws_apigatewayv2_api.contact.api_endpoint}/contact"
}

output "function_name" {
  description = "Contact Lambda name (for logs)"
  value       = aws_lambda_function.contact.function_name
}
```

| Output | What it is |
|---|---|
| `contact_api_url` | **The full URL including `/contact`** — Terraform concatenates `api_endpoint` with the route path so you can `curl $contact_api_url` directly. (Beware: don't append `/contact` again — the user-debug story of this project includes that exact 404 mistake.) |
| `function_name` | The Lambda's name → used with `aws logs tail /aws/lambda/...`. |

---

## 11. Apply, verify the emails, send a message

### Step 1 — Apply

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1
cd terraform/serverless-contact

terraform init
terraform fmt
terraform validate
terraform plan      # ~12 to add
terraform apply
```

What happens during apply:
1. AWS creates the two SES email identities.
2. **AWS sends two verification emails** — one to `var.sender_email`, one to `var.recipient_email`.
3. IAM role + policies created.
4. Lambda zipped, log group pre-created, function deployed.
5. HTTP API + integration + route + stage + invoke permission created.
6. Outputs printed including `contact_api_url`.

### Step 2 — Click both verification links

Open the inbox(es) for the sender and recipient addresses. You'll see two
emails from `no-reply-aws@amazon.com` with subjects like *"Amazon Web Services
– Email Address Verification Request in region ap-south-1."* **Click the
"Confirm" link in each.**

### Step 3 — Confirm both are verified

```bash
aws sesv2 list-email-identities \
  --query 'EmailIdentities[].{Email:IdentityName,VerificationStatus:VerificationStatus,Sending:SendingEnabled}' \
  --output table
```

Look for:
```
Email                              VerificationStatus    Sending
chalakasamith+sender@gmail.com     SUCCESS               True
chalakasamith@gmail.com            SUCCESS               True
```

| Status value | Meaning |
|---|---|
| `NOT_STARTED` / null | Just created, verification email not clicked yet |
| `PENDING` | Sent, waiting for click |
| `SUCCESS` | ✅ Verified, usable for sending |
| `FAILED` | Verification expired (>24h) or rejected — re-verify via the console |

> ⚠️ **Earlier in the project we ran the query with `VerifiedForSendingStatus`**
> (which doesn't exist on the `list-email-identities` response) and saw `None`
> everywhere — looked like nothing was verified. The correct field on the **list**
> API is **`VerificationStatus`**. The field name `VerifiedForSendingStatus` exists
> only on the `get-email-identity` (single-identity) response.

### Step 4 — Send a test message

```bash
URL=$(terraform output -raw contact_api_url)

curl -X POST "$URL" -H "Content-Type: application/json" \
  -d '{"name":"Asha Perera","email":"asha@example.com","message":"What are the visiting hours?"}'
# → {"status": "sent"}
```

> ⚠️ **POST to `$URL`, not `$URL/contact`.** The `contact_api_url` output already
> ends with `/contact`. Appending another `/contact` gives `/contact/contact` →
> API Gateway 404. (Yes, this is exactly the mistake we debugged live.)

Check the inbox of `recipient_email` — the email arrives within seconds, with
"Reply" pointing back to `asha@example.com`.

### Step 5 — Inspect logs if anything misbehaves

```bash
aws logs tail "/aws/lambda/$(terraform output -raw function_name)" --since 5m
```

### Common failures and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `Runtime.ImportModuleError: No module named 'lambda_function'` | Filename typo (`lambda_funtion.py` etc.) | Rename to exactly `lambda_function.py`, re-apply (force redeploys via `source_code_hash`) |
| `HTTP 200` but no email arrives | Identity not verified yet | Click the verification email; recheck status |
| `MessageRejected: Email address is not verified` (in logs) | Sandbox + one identity unverified | Click the verification link for the unverified one |
| `AccessDeniedException ... ses:SendEmail on resource <recipient ARN>` | IAM policy only lists sender ARN; sandbox checks both | Add recipient ARN to the policy's `resources` list (§6) |
| `HTTP 404 "Not Found"` from API GW | URL was `$URL/contact` (doubled) | POST to `$URL` directly — output already includes `/contact` |
| `ResourceAlreadyExists` on `terraform apply` | Sender and recipient are the exact same string | Use Gmail `+` aliasing (or two real addresses) |

> ⚠️ **`MessageRejected: Email address is not verified`** = you didn't click both
> verification links yet. Re-check the inbox (including spam) and verify, then
> retry.

---

## 12. (Optional) Wire it into the React frontend

Add a small `ContactForm` component to `app/frontend/src/App.jsx` that posts to
the contact API URL. Easiest: bake the URL in at build time via another env var
(`VITE_CONTACT_URL`).

```jsx
// snippet — add to your App.jsx (after the Appointments section)
function ContactForm() {
  const [form, setForm] = useState({ name: "", email: "", message: "" });
  const [status, setStatus] = useState("");
  const URL = import.meta.env.VITE_CONTACT_URL; // set at build time

  async function submit(e) {
    e.preventDefault();
    setStatus("sending…");
    try {
      const res = await fetch(URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) throw new Error(await res.text());
      setStatus("sent ✓");
      setForm({ name: "", email: "", message: "" });
    } catch (e) { setStatus(String(e)); }
  }

  return (
    <section>
      <h2>Contact us</h2>
      <form onSubmit={submit} style={{ display: "grid", gap: 8, maxWidth: 400 }}>
        <input required placeholder="Your name" value={form.name}
          onChange={(e) => setForm({ ...form, name: e.target.value })} />
        <input required type="email" placeholder="Your email" value={form.email}
          onChange={(e) => setForm({ ...form, email: e.target.value })} />
        <textarea required rows={4} placeholder="Message" value={form.message}
          onChange={(e) => setForm({ ...form, message: e.target.value })} />
        <button type="submit">Send</button>
        {status && <p>{status}</p>}
      </form>
    </section>
  );
}
```

Build it:

```bash
VITE_API_URL="" \
VITE_CONTACT_URL="$(cd ../../terraform/serverless-contact && terraform output -raw contact_api_url)" \
  npm run build
```

Then re-upload `dist/` to S3 and invalidate CloudFront (Doc 15 §10).

> 💡 **Cross-origin caveat:** the contact API is on a different domain
> (`*.execute-api...amazonaws.com`) from CloudFront, so the browser sends a
> preflight `OPTIONS`. The HTTP API's `cors_configuration` above handles it. To
> keep everything same-origin in production, add an `ordered_cache_behavior` for
> `/contact` in the CDN stack pointing at the contact API — same trick we used for
> `/api/*`.

---

## 13. 💰 Cost & teardown

| Resource | Cost |
|----------|------|
| Lambda + API Gateway HTTP API | effectively free at lab scale |
| SES | $0.10 per 1,000 emails sent (and the first 62,000/mo from EC2 are free — N/A here, but generous) |
| Verified identities | free |
| CloudWatch Logs (7-day retention) | within 5 GB free |

```bash
terraform destroy   # in terraform/serverless-contact/  — instant, safe
```

This stack is independent of everything else, so destroy/recreate freely.

---

## 14. Plain-English summary (what you just built)

If asked to explain Phase 6 part 2:

1. **Two SES email identities** — sender (`+sender@…`) and recipient — both
   verified via clicking links AWS sent at apply time. **Required by SES
   sandbox** (sandbox refuses sends where either end is unverified).
2. **One Lambda function** (`cloudcare-contact`) — POST-only, validates name +
   email + message, calls `sesv2.send_email` with the visitor's email as
   `ReplyToAddresses` so the admin's "Reply" lands in the right inbox.
3. **One IAM role** scoped to **just `ses:SendEmail`** on the sender's identity
   ARN (and recipient's, because both are in our account during sandbox), with
   a **`ses:FromAddress` condition** locking the role to sending **as** the
   exact sender.
4. **One HTTP API** with one route (`POST /contact`), built-in CORS,
   throttled to 5 req/s with burst 10 (anti-abuse), AWS_PROXY integration to
   the Lambda, and the standard `aws_lambda_permission` allowing API GW to
   invoke.
5. End-to-end: `curl POST` to the URL → JSON-validated payload → SES email
   delivered with admin "Reply" set to the visitor's address.

---

## 15. Interview soundbites

- **Why Lambda + SES** — *"The contact form fires rarely and is independent of
  the main app. Running it on serverless means no idle cost and the patients
  API can't be brought down by a bug in the form's code path. Right scaling
  shape, right blast radius."*

- **SES sandbox** — *"AWS keeps every account in SES sandbox until you request
  production access. In sandbox both sender and recipient must be verified;
  caps are 200/day, 1/sec. Production access removes the recipient-side
  restriction. For the lab we verify both identities; for production we'd file
  the sandbox-removal form once."*

- **The `ses:FromAddress` condition** — *"The IAM policy not only scopes
  `ses:SendEmail` to the sender's ARN, it adds a condition pinning the actual
  From address to our exact sender. Even a bad code change can't make this role
  email *as* a different identity — IAM refuses at the API layer."*

- **`ReplyToAddresses`** — *"The From address is the verified SES sender — often
  a no-reply alias. `ReplyToAddresses` lets us set the visitor's email as the
  reply target, so the admin's 'Reply' goes to the right place. One line, big
  UX win."*

- **The "both verified identities" IAM subtlety** — *"In sandbox, when both
  ends are verified identities in my account, SES checks `ses:SendEmail`
  against both identity ARNs. The fix is listing both ARNs in the policy's
  resources, with the `FromAddress` condition still locking the sender. In
  production with sandbox lifted, the recipient isn't in my account and only
  the sender ARN matters."*

- **Throttling on public endpoints** — *"The HTTP API is rate-limited to 5
  req/s with burst 10. A contact form should never burst higher — a bot hitting
  the endpoint would inflate SES costs and trip sandbox/production caps. Tiny
  config, real abuse prevention."*

---

## ✅ Checkpoint — end of Phase 6 🎉

You've built both serverless slices of CloudCare. You should now have:

- [ ] `terraform/serverless-audit/` — the API Gateway → Lambda → DynamoDB +
      X-Ray feature (Doc 16).
- [ ] `terraform/serverless-contact/` — this stack, with a verified sender and
      recipient.
- [ ] A `curl POST /contact` that delivers a real email to the admin inbox.

And you can explain, from memory:

- When to choose Lambda over EC2 (event-driven, spiky, isolated features).
- The SES sandbox and how you'd remove it for production.
- Why we scoped the IAM `ses:SendEmail` with a `ses:FromAddress` condition.
- The role of HTTP API throttling on a public form.
- Why both identity ARNs must be in the IAM policy when both are verified in
  your account (sandbox-specific subtlety).

> 💰 **Both serverless stacks are essentially free** — you can leave them up.
> The expensive stuff (compute + database) is still where to apply destroy-after-
> labs discipline.

**Tell me when you've reached this checkpoint**, and I'll write **Phase 7 —
Observability & Cost** (doc 18): CloudWatch dashboards & alarms across the whole
stack (ALB latency, RDS CPU/connections, Lambda errors, ASG health), log
aggregation, and the Cost Explorer / Budgets / Compute Optimizer trio.

Next: **Phase 7 — Observability & Cost** (doc 18, written when you reach this
checkpoint).
