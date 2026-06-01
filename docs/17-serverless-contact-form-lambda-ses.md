# 17 — Serverless: Contact Form (API Gateway + Lambda + SES)

> **Goal of this doc:** build the second serverless slice — a hospital **contact
> form** where a visitor submits `{name, email, message}` to an HTTP API, a
> Lambda formats it and sends an email via **Amazon SES** to the hospital admin
> inbox. Zero servers, zero idle cost. This completes **Phase 6 — Serverless**.

⏱️ Time: ~60 minutes (plus ~5 min to click two email verification links).
💰 Cost: **~$0** — SES is $0.10 per 1,000 emails, Lambda + API Gateway tiny.

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

> 💡 **Same email for both is fine for the lab.** If you want to test entirely
> with your own inbox, set sender = recipient = `chalaka@wso2.com`. Two
> verifications, but you'll receive your own form submissions.

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

Create a `terraform.tfvars` next to it (gitignored — it has personal email
addresses, not secrets but still good to keep out of git):

```hcl
# terraform/serverless-contact/terraform.tfvars   (commit terraform.tfvars.example instead)
sender_email    = "chalaka@wso2.com"
recipient_email = "chalaka@wso2.com"
```

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

> 🧠 **The `ses:FromAddress` condition** stops the function from being abused as
> a generic mailer for *any* sender on the account. Even if the Lambda code
> changed to pass a different `FromEmailAddress`, IAM would reject the call.
> Conditions like this are what make "least privilege" actually mean something.

---

## 7. `src/lambda_function.py` — the handler

Create `terraform/serverless-contact/src/lambda_function.py`:

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

> 🧠 **`ReplyToAddresses=[email]`** is the small detail that makes the admin's
> "Reply" button do the right thing: their reply goes to the visitor, not back to
> the SES-verified sender (which is often a noreply alias). One line, big UX win.

> ⚠️ **The handler validates inputs by hand** — keep it strict at the edge. A
> public unauthenticated endpoint will get garbage payloads almost immediately;
> never trust the shape.

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

---

## 11. Apply, verify the emails, send a message

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

After apply, **check the inbox for `var.sender_email` and `var.recipient_email`
and click both verification links AWS sent.** Confirm they're verified:

```bash
aws sesv2 list-email-identities --query 'EmailIdentities[].{Email:IdentityName,Verified:VerifiedForSendingStatus}' --output table
```

Both should say `Verified: True`. Now send:

```bash
URL=$(terraform output -raw contact_api_url)

curl -X POST "$URL" -H "Content-Type: application/json" \
  -d '{"name":"Asha Perera","email":"asha@example.com","message":"What are the visiting hours?"}'
# → {"status": "sent"}
```

Check the inbox of `recipient_email` — the email arrives within seconds, with
"Reply" pointing back to `asha@example.com`.

If you get `{"error": "..."}` or a 5xx, check the logs:

```bash
aws logs tail "/aws/lambda/$(terraform output -raw function_name)" --since 5m
```

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

> 💰 **Both serverless stacks are essentially free** — you can leave them up.
> The expensive stuff (compute + database) is still where to apply destroy-after-
> labs discipline.

**Tell me when you've reached this checkpoint**, and I'll write **Phase 7 —
Observability & Cost** (doc 18): CloudWatch dashboards & alarms across the whole
stack (ALB latency, RDS CPU/connections, Lambda errors, ASG health), log
aggregation, and the Cost Explorer / Budgets / Compute Optimizer trio.

Next: **Phase 7 — Observability & Cost** (doc 18, written when you reach this
checkpoint).
