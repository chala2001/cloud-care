# 15 — Content Delivery: S3 Static Hosting & CloudFront

> **Goal of this doc:** put the React build from [Doc 14](14-application-react-frontend.md)
> into a private **S3 bucket** and serve everything — frontend *and* API — through
> a single **CloudFront** distribution over HTTPS. The default behavior serves the
> static React app from S3; the `/api/*` behavior forwards to the Phase 2 ALB. By
> the end, CloudCare is reachable at one global URL with caching at the edge. This
> is **Phase 5 — Content Delivery**, a single doc.

⏱️ Time: ~75 minutes (CloudFront itself takes ~5–10 min to deploy).
💰 Cost: ~$0 — CloudFront and S3 are both well within free tier for this
project. See §11.

---

## 1. What we're building

```
   Users (browsers, anywhere on Earth)
        │  https://<id>.cloudfront.net
        ▼
   ┌──────────── Amazon CloudFront (global CDN, HTTPS) ──────────────┐
   │                                                                  │
   │   default behavior  ──►  S3 bucket  (React static files, OAC)    │
   │                                                                  │
   │   /api/* behavior   ──►  ALB (compute stack)  ──►  EC2  ──►  RDS │
   │                                                                  │
   └──────────────────────────────────────────────────────────────────┘
```

One URL for the whole app, served over **free HTTPS** (CloudFront's
`*.cloudfront.net` cert), with the static SPA cached at hundreds of edge
locations and the dynamic API uncached. Because the frontend and API share the
same origin, **no CORS** is needed in production — the browser sees one site.

> 🧠 **Why CloudFront, beyond "it's a CDN":**
> 1. **Latency**: HTML/JS/CSS served from an edge close to the user, not from
>    Mumbai.
> 2. **HTTPS for free**: CloudFront issues a TLS cert for `*.cloudfront.net`
>    automatically — no ACM, no custom domain needed for the lab.
> 3. **One origin to the browser**: frontend at `/`, API at `/api/*` — same host,
>    no CORS, no preflight overhead, simpler cookies later.
> 4. **Cheap egress**: CloudFront data-out has a generous always-free tier and is
>    cheaper than serving from EC2/ALB.

---

## 2. The Terraform folder

A new stack with its own state key:

```
terraform/
├── bootstrap/   ← Phase 0 (leave it)
├── network/     ← Phase 1 (leave it)
├── compute/     ← Phase 2 + Doc 13 (destroy after labs)
├── database/    ← Phase 3 (destroy after labs)
└── cdn/         ← Phase 5 — THIS doc
```

Files:

```
providers.tf       # backend{} key=cdn/, default tags Component=cdn
variables.tf       # region, project
data.tf            # remote state (compute → alb_dns_name), caller identity
s3.tf              # private frontend bucket + versioning + public-access block
cloudfront.tf      # OAC + the distribution
bucket-policy.tf   # allow CloudFront (via OAC) to read the bucket
outputs.tf         # cloudfront domain + bucket name (for the upload step)
```

---

## 3. `providers.tf` and `variables.tf`

```hcl
# terraform/cdn/providers.tf
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "cdn/terraform.tfstate"
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
      Component = "cdn"
    }
  }
}
```

```hcl
# terraform/cdn/variables.tf
variable "aws_region" {
  description = "AWS region (CloudFront is global, but the provider needs one)"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix"
  type        = string
  default     = "cloudcare"
}
```

> 🧠 **CloudFront is global**, not regional — but the AWS provider still needs a
> region for the *control plane* calls. Using `ap-south-1` is fine. The only place
> region matters for CloudFront is **ACM certificates for custom domains, which
> must live in `us-east-1`** — we're not using a custom domain in this doc, so
> there's nothing to set up there.

---

## 4. `data.tf` — read the compute stack

```hcl
# terraform/cdn/data.tf

data "aws_caller_identity" "current" {}

# Read the COMPUTE stack so we can use the ALB DNS as an origin.
data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "compute/terraform.tfstate"
    region = "ap-south-1"
  }
}
```

> 💡 The compute stack must be **applied** when you build the distribution, so
> Terraform can read `alb_dns_name` from its state. If you torn compute down to
> save costs, bring it back first (`terraform apply` in `terraform/compute/`).

---

## 5. `s3.tf` — the private frontend bucket

```hcl
# terraform/cdn/s3.tf

# Bucket names are globally unique — suffix with the account id.
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project}-frontend-${data.aws_caller_identity.current.account_id}"

  # Learning: allow `terraform destroy` even when objects exist.
  force_destroy = true

  tags = { Name = "${var.project}-frontend" }
}

# Versioning lets us roll a bad build back by republishing the previous object.
resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt objects at rest (no-cost, just good hygiene).
resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block ALL public access. CloudFront will reach the bucket PRIVATELY via OAC.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

> 🧠 **Private bucket + CloudFront = the modern serve-static-from-S3 pattern.**
> The older approach enabled S3 "static website hosting" and made the bucket
> public. Today the bucket stays private and CloudFront accesses it privately via
> **Origin Access Control (OAC)** — better security, HTTPS, and no public S3
> URL to leak.

---

## 6. `cloudfront.tf` — OAC + the distribution

```hcl
# terraform/cdn/cloudfront.tf

# OAC is the modern replacement for the legacy Origin Access Identity (OAI).
# It signs CloudFront's requests to S3 with SigV4, scoped to this distribution.
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project}-frontend-oac"
  description                       = "OAC for the CloudCare frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudCare CDN"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # cheapest: US/CA/EU edges only (plenty for learning)

  # --- ORIGIN 1: the private S3 bucket (static React build) ---
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # --- ORIGIN 2: the ALB from the compute stack (API) ---
  origin {
    domain_name = data.terraform_remote_state.compute.outputs.alb_dns_name
    origin_id   = "alb-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB has no TLS cert yet
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # --- DEFAULT BEHAVIOR: cache the React app aggressively from S3 ---
  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https" # any http request → https
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS-managed policy: CachingOptimized (long TTLs, gzip, brotli).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # --- /api/* BEHAVIOR: forward dynamically to the ALB, never cache ---
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-api"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS-managed policies:
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer (forward headers/qs/cookies)
  }

  # SPA fallback: an unknown URL (e.g. /patients/42) hits S3, gets 403/404
  # because the file doesn't exist. Serve index.html instead so React Router
  # (or any client-side routing you add) can handle the path.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  # Free *.cloudfront.net certificate. To attach a custom domain later, replace
  # this with an `acm_certificate_arn` (the cert MUST be in us-east-1).
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project}-cdn" }
}
```

> 🧠 **The AWS-managed policy IDs (`658327ea-...`, etc.) are global constants** —
> the same in every AWS account. Using them avoids declaring your own cache and
> origin-request policies for the common cases.

> 🧠 **`PriceClass_100`** is the cheapest tier (North America + Europe edges).
> Users in Asia still get served — just from a slightly farther edge. For
> production you'd pick `PriceClass_All`; for learning, 100 is fine and free.

---

## 7. `bucket-policy.tf` — let CloudFront read the bucket

```hcl
# terraform/cdn/bucket-policy.tf

# Policy: "the cloudfront service may read objects from this bucket, but ONLY
# when the request comes from OUR distribution (aws:SourceArn condition)."
data "aws_iam_policy_document" "frontend_oac_read" {
  statement {
    sid       = "AllowCloudFrontReadViaOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_oac_read.json
}
```

> 🧠 **The `aws:SourceArn` condition is the security tightener.** Without it, any
> CloudFront distribution in any account could (in theory) be configured to read
> your bucket. With it, only *your* distribution can. Tiny line, real defense.

> 💡 **Order of creation:** Terraform sees `bucket_policy` depends on
> `distribution.arn`, so it creates the distribution first, then attaches the
> policy. During the few seconds in between, CloudFront would return 403s — fine
> for a fresh `apply`.

---

## 8. `outputs.tf`

```hcl
# terraform/cdn/outputs.tf

output "cloudfront_domain_name" {
  description = "Public domain — open this in a browser"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "Distribution id (used to invalidate the cache after a deploy)"
  value       = aws_cloudfront_distribution.main.id
}

output "frontend_bucket" {
  description = "S3 bucket name — upload the React `dist/` here"
  value       = aws_s3_bucket.frontend.id
}
```

---

## 9. Two small retroactive edits (so `/api/*` works cleanly)

Up to now the backend served `/patients`, not `/api/patients`. To keep CloudFront
simple (no path rewriting) and produce a clean, professional URL scheme, we mount
the API routes under `/api`. Two small edits — one to the backend, one to the
frontend.

### 9a. Backend — `app/backend/app/main.py`

Wrap the data endpoints in an `APIRouter` with `prefix="/api"`. Keep `/health` at
the root so the **ALB target-group health check (Doc 13)** doesn't need changing.

```python
# replace the @app.get/post for patients & appointments with this router

from fastapi import APIRouter

router = APIRouter(prefix="/api")

@router.get("/patients", response_model=list[schemas.PatientOut])
def list_patients(db: Session = Depends(get_db)):
    return db.scalars(select(models.Patient)).all()

@router.post("/patients", response_model=schemas.PatientOut, status_code=201)
def create_patient(payload: schemas.PatientCreate, db: Session = Depends(get_db)):
    patient = models.Patient(**payload.model_dump())
    db.add(patient); db.commit(); db.refresh(patient)
    return patient

@router.get("/appointments", response_model=list[schemas.AppointmentOut])
def list_appointments(db: Session = Depends(get_db)):
    return db.scalars(select(models.Appointment)).all()

@router.post("/appointments", response_model=schemas.AppointmentOut, status_code=201)
def create_appointment(payload: schemas.AppointmentCreate, db: Session = Depends(get_db)):
    if not db.get(models.Patient, payload.patient_id):
        raise HTTPException(status_code=404, detail="patient not found")
    appt = models.Appointment(**payload.model_dump())
    db.add(appt); db.commit(); db.refresh(appt)
    return appt

app.include_router(router)
# /health stays a top-level @app.get("/health")
```

Rebuild and re-push the image (same flow as Doc 13 §4), then start an instance
refresh:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name $(cd terraform/compute && terraform output -raw asg_name)
```

### 9b. Frontend — `app/frontend/src/api.js`

In production the frontend lives on the **same CloudFront origin** as the API, so
the API base is empty (same-origin) and every call is `/api/...`:

```js
// app/frontend/src/api.js  (replace the existing BASE/req)
const BASE = import.meta.env.VITE_API_URL ?? ""; // "" = same origin (production)

async function req(path, options) {
  const res = await fetch(`${BASE}/api${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}
// (api.listPatients = () => req("/patients") etc. stay the same)
```

For local dev, set `VITE_API_URL=http://localhost:8000` so calls go to
`http://localhost:8000/api/patients`. In the production build (next section),
leave `VITE_API_URL` unset and the browser will call `/api/patients` on the same
CloudFront host.

> 🧠 **Why split the paths this way (interview):** "Mounting the API under `/api`
> and serving the SPA from the same origin removes CORS, simplifies cookies, and
> lets CloudFront route the two with a single behavior split. The ALB health
> check stays on a root path so it isn't coupled to the public API prefix."

---

## 10. Apply, build, upload, invalidate

### 10a. Apply the CDN stack

From inside `terraform/cdn/`:

```bash
export AWS_PROFILE=cloudcare
export AWS_REGION=ap-south-1

terraform init
terraform fmt
terraform validate
terraform plan
```

Expect about **`Plan: 6 to add, 0 to change, 0 to destroy.`** (bucket + versioning
+ encryption + public-access block + OAC + distribution + bucket policy — counts
vary slightly with what AWS reports).

```bash
terraform apply   # CloudFront creation takes ~5-10 min — be patient
```

### 10b. Build and upload the React app

```bash
# Build with VITE_API_URL unset → same-origin /api/* calls
cd app/frontend
npm install
npm run build        # produces app/frontend/dist/

# Get the bucket and distribution id Terraform created:
BUCKET=$(cd ../../terraform/cdn && terraform output -raw frontend_bucket)
DIST=$(cd ../../terraform/cdn && terraform output -raw cloudfront_distribution_id)

# Sync the build to S3 (delete removes stale files from previous builds):
aws s3 sync dist/ "s3://$BUCKET/" --delete
```

### 10c. Invalidate the CloudFront cache

CloudFront caches everything aggressively. After every upload, **invalidate** so
viewers see the new files instead of stale cached ones:

```bash
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*"
```

> 💰 **Invalidations:** the first 1,000 paths per month are free; after that
> ~$0.005/path. A single `"/*"` counts as one path, so cheap.

---

## 11. Verify end-to-end

```bash
CF=$(cd terraform/cdn && terraform output -raw cloudfront_domain_name)
echo "Open https://$CF/ in your browser"

# Confirm both behaviors work:
curl -sI "https://$CF/"                 # should be 200 with content-type text/html (S3)
curl -s  "https://$CF/api/patients"     # should be JSON from the ALB
```

Open the CloudFront URL in a browser — the React UI loads from S3, and the
patient/appointment forms call `/api/...` which CloudFront forwards to the ALB,
which hits an EC2 instance, which reads/writes RDS. **One HTTPS URL, the whole
stack.**

> 🧠 **What's actually free here.** The CloudFront response was served from the
> nearest edge, encrypted with a cert AWS issued you for free, on a domain AWS
> gave you for free. The S3 GET was a private SigV4 request from CloudFront, never
> exposed publicly. None of this would have been remotely easy to build yourself.

---

## 12. 💰 Cost & teardown

| Resource | Free-tier status |
|----------|------------------|
| S3 (frontend bucket, a few MB) | ✅ within 5 GB free tier |
| CloudFront data out | ✅ **1 TB/month always free** + 10M HTTPS requests free |
| CloudFront invalidations | ✅ first 1,000 paths/month free |
| Default `*.cloudfront.net` TLS cert | ✅ free, managed by AWS |

**You can leave the CDN stack up** — it's effectively free and there's nothing
behind it that drains money on its own. Teardown is only needed if you want a
clean slate or are rotating the bucket name:

```bash
terraform destroy   # in terraform/cdn/
```

> ⚠️ **The CDN depends on the compute stack** (via remote state for the ALB DNS).
> If you destroy compute, the CDN's `/api/*` behavior will 502 until compute is
> re-applied — but the static frontend will still serve. If you change ALB DNS
> (which happens whenever you recreate compute), re-apply the CDN so the
> distribution's origin updates.

---

## ✅ Checkpoint — end of Phase 5 🎉

You've gone global. You should now have, in `terraform/cdn/` (state key
`cdn/...`):

- [ ] A private S3 bucket with the React `dist/` uploaded.
- [ ] A CloudFront distribution with two origins: S3 (default) and the ALB
      (`/api/*`), served over free HTTPS.
- [ ] An OAC + bucket policy that lets only your distribution read the bucket.
- [ ] The backend mounted under `/api`, the frontend calling `/api/*`, both
      working through the CloudFront URL.

And you can explain, from memory:

- Why CloudFront + private S3 (OAC) is preferred over public S3 website hosting.
- How **one origin** for frontend+API eliminates CORS in production.
- Why we cache the SPA aggressively but disable caching on `/api/*`.
- What invalidation is and when to run it.

**Tell me when you've reached this checkpoint**, and I'll write **Phase 6 —
Serverless**: an API Gateway + Lambda + DynamoDB feature for appointment
notifications / an audit log (traced with X-Ray), and a Lambda + SES contact form
— the two serverless slices from the original architecture diagrams.

Next: **Phase 6 — Serverless** (docs 16–17, written when you reach this
checkpoint).
