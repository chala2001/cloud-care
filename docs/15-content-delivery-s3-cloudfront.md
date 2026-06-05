# 15 — Content Delivery: S3 Static Hosting & CloudFront

> **Goal of this doc:** put the React build from [Doc 14](14-application-react-frontend.md)
> into a private **S3 bucket** and serve everything — frontend *and* API — through
> a single **CloudFront** distribution over HTTPS. The default behavior serves the
> static React app from S3; the `/api/*` behavior forwards to the Phase 2 ALB. By
> the end, CloudCare is reachable at one global URL with caching at the edge. This
> is **Phase 5 — Content Delivery**, a single doc.

⏱️ Time: ~75 minutes (CloudFront itself takes ~5–10 min to deploy).
💰 Cost: ~$0 — CloudFront and S3 are both well within free tier for this
project. See §12.

---

## 0. Beginner read-me first — vocabulary in one place

CloudFront has its own dictionary. Re-read this whenever a term feels foreign.

| Word | Plain-English meaning |
|---|---|
| **CDN** (Content Delivery Network) | A global network of caching servers ("edges") that sit close to users and serve content from the nearest one. CloudFront is AWS's CDN. |
| **Edge location / PoP** | One of AWS's ~600 caching servers around the world. The browser connects to the nearest one. |
| **CloudFront distribution** | One logical CDN config: a public URL, a set of origins, and behaviors. Created once, edited as needed. |
| **Origin** | A backend CloudFront fetches from when its cache misses. Can be S3, an ALB, or any HTTPS URL. One distribution can have many. |
| **Behavior** | A rule that picks an origin + cache settings based on the URL path. **Default behavior** = "catch-all"; **ordered behaviors** match before it. |
| **Path pattern** | The URL pattern an ordered behavior matches (`/api/*`, `/img/*.jpg`, …). |
| **Cache policy** | AWS-managed (or custom) rules for what to cache + how long. Two we use: `CachingOptimized` (long TTLs, gzip+brotli) and `CachingDisabled` (always pass through). |
| **Origin request policy** | What headers / cookies / query strings get **forwarded** to the origin. |
| **TTL** (Time To Live) | How long CloudFront keeps a cached object before re-checking the origin. |
| **Cache hit** | The edge already has the file → served instantly, no origin call. |
| **Cache miss** | The edge doesn't have it → fetch from origin, store, return. |
| **Invalidation** | Tell CloudFront to forget cached copies for given paths. First 1,000 paths/month free. |
| **Hash-busting** | Renaming files like `app.a3f1b.js` so a new build has a new filename → automatic cache bust on most assets. |
| **OAC** (Origin Access Control) | The **modern** mechanism that lets CloudFront fetch from a **private** S3 bucket. Signs requests with SigV4. |
| **OAI** (Origin Access Identity) | The **legacy** version of OAC. Still works; new projects use OAC. |
| **`aws:SourceArn` condition** | An IAM condition that says "only allow this action when the request comes from *this exact resource*." Locks the bucket to one specific distribution. |
| **`default_root_object`** | The file CloudFront returns when someone requests `/` (e.g. `index.html`). |
| **`viewer_protocol_policy`** | What CloudFront does about HTTP vs HTTPS — `redirect-to-https` is the standard hardening. |
| **SPA fallback** | A `custom_error_response` rule that turns S3's 403/404 into a 200 with `/index.html`, so client-side routing works. |
| **`PriceClass_100` / `_200` / `_All`** | Which edge regions to use. 100 = NA+EU only (cheapest); All = every edge worldwide. |
| **ACM** (AWS Certificate Manager) | Free TLS certificates. For CloudFront, **the cert must live in `us-east-1`** regardless of where your stack is. |
| **Same-origin** | When the page and its API share the same scheme+host+port. No CORS preflight needed. Why we route `/api/*` through CloudFront. |
| **`aws s3 sync`** | Copy a local folder to S3, only uploading changed files; with `--delete`, also removes S3 objects that aren't local. |
| **`create-invalidation`** | The API call that tells CloudFront to forget a path. `/*` invalidates everything. |

Now the architecture.

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

### The two-behavior split (the key idea of this doc)

```
  request URL                  matches behavior          goes to origin            cached?
  ───────────────────────────────────────────────────────────────────────────────────────
  https://<cf>/                default                   S3 (index.html)            ✅ long TTL
  https://<cf>/assets/x.js     default                   S3                         ✅ long TTL
  https://<cf>/api/patients    /api/*  (ordered behav)   ALB                        ❌ no cache
  https://<cf>/api/health      /api/*  (ordered behav)   ALB                        ❌ no cache
```

Same distribution, **two origins**, two cache rules. Static gets cached
aggressively; the API is always served fresh.

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

### File-purpose table

| File | One-line purpose |
|---|---|
| `providers.tf` | Connect to AWS; store state under `cdn/`. |
| `variables.tf` | Inputs: region, project name. |
| `data.tf` | Read the compute stack's outputs (ALB DNS) + look up our account id. |
| `s3.tf` | Create the private frontend bucket + versioning + encryption + public-access block. |
| `cloudfront.tf` | Create the OAC + the distribution with both origins + behaviors + SPA fallback. |
| `bucket-policy.tf` | Grant CloudFront-only read on the bucket via the OAC's `SourceArn`. |
| `outputs.tf` | Publish the CloudFront domain, the distribution id, and the bucket name. |

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

### Walk-through

This file's structurally identical to your previous `providers.tf` files. The
**only** new things are:

| Detail | Meaning |
|---|---|
| `key = "cdn/terraform.tfstate"` | Isolated state under `cdn/` in the bucket. |
| `Component = "cdn"` | Stamped on every resource for cost-attribution / console-search. |

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

| Block | Meaning |
|---|---|
| `data "aws_caller_identity" "current"` | Look up the current AWS identity. We use `.account_id` to suffix the bucket name (S3 names are globally unique). |
| `data "terraform_remote_state" "compute"` | Read the compute stack's state file. We need `outputs.alb_dns_name` to point CloudFront at the ALB. |

### The cross-stack pin: a real footgun

> ⚠️ **`terraform_remote_state` reads the upstream's outputs at plan time and
> bakes the value into this stack's state.** That means if you ever recreate the
> compute stack (e.g. `terraform destroy` then re-apply), the ALB will get a
> **new DNS name** — and CloudFront will still be pointing at the **old** one
> until you `terraform apply` here too. Symptom: frontend works, `/api/*`
> returns 502. Fix: re-apply this stack so it re-reads the current value.

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

### Walk-through — each resource, what it does

#### `aws_s3_bucket.frontend` — the bucket itself

| Line | Meaning |
|---|---|
| `bucket = "${var.project}-frontend-${...account_id}"` | Bucket names are globally unique **across all of AWS**. Suffixing with the account id (`cloudcare-frontend-670794226080`) guarantees no collision. |
| `force_destroy = true` | `terraform destroy` would normally refuse to delete a bucket with objects in it. `force_destroy = true` deletes everything. **Lab convenience only** — production should leave this `false`. |

#### `aws_s3_bucket_versioning.frontend`

Enables object versioning on the bucket. Every PUT keeps the old version (a
hidden previous version). To roll back a bad deploy, re-upload an older
version. Storage cost is tiny for static-site bytes.

#### `aws_s3_bucket_server_side_encryption_configuration.frontend`

Tells S3: "encrypt every object you store with AES-256, automatically." Free,
AWS-managed keys. **No-cost hygiene** — public S3 doesn't strictly need this
for HTML/CSS, but it's a one-liner that always belongs.

#### `aws_s3_bucket_public_access_block.frontend`

The hardening you can't skip. Four `true`s lock down every public-access
escape hatch:

| Setting | What it blocks |
|---|---|
| `block_public_acls = true` | Refuses anyone trying to set a public ACL on this bucket. |
| `block_public_policy = true` | Refuses bucket policies that grant public access. |
| `ignore_public_acls = true` | Ignores any public ACLs already on objects (defensive). |
| `restrict_public_buckets = true` | Even if a public-ish policy got through, this caps access to AWS principals. |

Together: even by accident, you can't make this bucket public. CloudFront will
reach it **privately** via OAC.

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

This file is the most concept-dense in the doc. Three resources... wait, two:
an OAC, and the distribution itself (which contains everything else as nested
blocks). Let's walk it.

### Block 1 — the Origin Access Control

```hcl
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project}-frontend-oac"
  description                       = "OAC for the CloudCare frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
```

| Line | Meaning |
|---|---|
| `name` / `description` | Identifiers. |
| `origin_access_control_origin_type = "s3"` | This OAC will be used to access **S3** (vs Lambda@Edge, MediaStore, etc.). |
| `signing_behavior = "always"` | Always sign requests to the origin. Other options are `never` (effectively no OAC) and `no-override` (sign only if the viewer didn't already send Authorization). |
| `signing_protocol = "sigv4"` | The standard AWS SigV4 signing algorithm. |

Result: CloudFront will sign every S3 request with **its own SigV4 signature**.
S3 sees a signed request that includes a header naming this distribution's
ARN, and trusts it because the bucket policy says to (next file).

### Block 2 — the distribution: top-level settings

```hcl
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudCare CDN"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  ...
}
```

| Line | Meaning |
|---|---|
| `enabled = true` | Turn the distribution on. `false` parks it without deleting. |
| `is_ipv6_enabled = true` | Accept IPv6 connections too. Free. |
| `comment = "CloudCare CDN"` | Human description in the console. |
| `default_root_object = "index.html"` | When a viewer requests `/` (no path), serve `index.html` from the default origin. Without this, `/` returns S3's directory listing 403. |
| `price_class = "PriceClass_100"` | Which edge regions to use. `100` = US/CA/EU only (cheapest). `200` adds South America/Asia. `All` = everywhere. Users outside the price class are still served — just from a slightly farther edge. |

### Block 2 (cont.) — the two `origin { ... }` blocks

You can have many `origin` blocks. Each defines a backend; behaviors point at
them by `origin_id`.

#### Origin 1 — the S3 bucket (private, OAC-signed)
```hcl
origin {
  domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
  origin_id                = "s3-frontend"
  origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
}
```

| Line | Meaning |
|---|---|
| `domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name` | Use the **regional** domain (e.g. `cloudcare-frontend-670794226080.s3.ap-south-1.amazonaws.com`), **not** the legacy `.s3-website-...` domain. The regional one supports OAC. |
| `origin_id = "s3-frontend"` | A nickname for this origin — referenced by behaviors below. |
| `origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id` | Wire in our OAC → CloudFront signs requests to this origin. |

#### Origin 2 — the ALB (HTTP, no signing)
```hcl
origin {
  domain_name = data.terraform_remote_state.compute.outputs.alb_dns_name
  origin_id   = "alb-api"

  custom_origin_config {
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols   = ["TLSv1.2"]
  }
}
```

| Line | Meaning |
|---|---|
| `domain_name = ...alb_dns_name` | Read from the compute stack's state. The full ALB DNS (e.g. `cloudcare-alb-12345.ap-south-1.elb.amazonaws.com`). |
| `origin_id = "alb-api"` | Nickname for behaviors. |
| `custom_origin_config { ... }` | Required when the origin isn't S3 — declares the network protocol. |
| `origin_protocol_policy = "http-only"` | CloudFront → ALB happens over **plain HTTP** (the ALB has no TLS cert). Viewer → CloudFront is still HTTPS — TLS terminates at the edge. |

> 🔒 **Is HTTP between CloudFront and ALB safe?** The traffic from the edge to
> the ALB still traverses the public internet. For real production, add an ACM
> cert to the ALB and set `origin_protocol_policy = "https-only"`. For a lab,
> http-only is acceptable — the user-facing leg is encrypted, which is the
> 99% benefit.

### Block 2 (cont.) — the `default_cache_behavior`

Every distribution has **one** default behavior. It matches anything not
matched by an ordered behavior.

```hcl
default_cache_behavior {
  target_origin_id       = "s3-frontend"
  viewer_protocol_policy = "redirect-to-https"
  allowed_methods        = ["GET", "HEAD"]
  cached_methods         = ["GET", "HEAD"]
  compress               = true
  cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
}
```

| Field | Meaning |
|---|---|
| `target_origin_id = "s3-frontend"` | Send matching requests to the S3 origin. |
| `viewer_protocol_policy = "redirect-to-https"` | Plain `http://...` requests get redirected to `https://...`. Other values: `allow-all`, `https-only`. |
| `allowed_methods = ["GET", "HEAD"]` | Only allow safe verbs. POST/PUT/DELETE to the frontend make no sense. |
| `cached_methods = ["GET", "HEAD"]` | Which of those can be cached. |
| `compress = true` | Enable gzip/brotli compression at the edge — smaller bundles, faster loads. |
| `cache_policy_id = "658327ea-f89d-..."` | The **AWS-managed `CachingOptimized`** policy. Long TTLs, smart compression. The hex IDs are global constants — same in every AWS account. |

### Block 2 (cont.) — the `ordered_cache_behavior` for `/api/*`

Ordered behaviors are evaluated in declaration order; the first matching one
wins. They're checked **before** the default behavior.

```hcl
ordered_cache_behavior {
  path_pattern           = "/api/*"
  target_origin_id       = "alb-api"
  viewer_protocol_policy = "redirect-to-https"
  allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
  cached_methods         = ["GET", "HEAD"]
  compress               = true
  cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
  origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
}
```

| Field | Meaning |
|---|---|
| `path_pattern = "/api/*"` | This behavior only matches URLs starting with `/api/`. |
| `target_origin_id = "alb-api"` | Send to the ALB origin. |
| `allowed_methods = [...]` | **All** HTTP verbs — APIs need to POST/PUT/DELETE. |
| `cache_policy_id = "4135ea2d-..."` | `CachingDisabled` managed policy — every request goes to the origin. Correct for an API where data changes. |
| `origin_request_policy_id = "216adef6-..."` | `AllViewer` managed policy — **forward all** viewer headers, query strings, and cookies to the ALB. The API needs them. |

> 🧠 **The AWS-managed policy IDs (`658327ea-...`, etc.) are global constants** —
> the same in every AWS account. Using them avoids declaring your own cache and
> origin-request policies for the common cases.

### Block 2 (cont.) — SPA fallback via `custom_error_response`

```hcl
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
```

**The problem:** an SPA uses client-side routing, so `https://<cf>/patients/42`
is *meant* to load `index.html` and let JS route to the patients page. But S3
returns 403 (or 404) for that file because no such object exists.

**The fix:** when CloudFront sees a 403 or 404 from S3, **rewrite the response
to 200 with `/index.html`**. The React app loads; client-side routing handles
the path. Standard SPA-on-CDN trick.

### Block 2 (cont.) — restrictions + cert + tags

```hcl
restrictions {
  geo_restriction { restriction_type = "none" }
}

viewer_certificate {
  cloudfront_default_certificate = true
}

tags = { Name = "${var.project}-cdn" }
```

| Block | Meaning |
|---|---|
| `restrictions { geo_restriction.restriction_type = "none" }` | Don't block any countries. (You could `"whitelist"` or `"blacklist"` country codes if needed.) |
| `viewer_certificate { cloudfront_default_certificate = true }` | Use AWS's free `*.cloudfront.net` cert. To use a custom domain, replace this with `acm_certificate_arn = "..."` — and the cert **MUST be in `us-east-1`**. |
| `tags` | Console label. |

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

### Walk-through

#### The policy document

```hcl
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
```

| Line | Meaning |
|---|---|
| `sid = "AllowCloudFrontReadViaOAC"` | A label for this statement. Optional but useful in console / debugging. |
| `actions = ["s3:GetObject"]` | **Just** the read action. No list, no put, no delete. |
| `resources = ["${aws_s3_bucket.frontend.arn}/*"]` | Object-level scope (`bucket-arn/*`), not bucket-level. |
| `principals.type = "Service"` | The **WHO** is an AWS service... |
| `principals.identifiers = ["cloudfront.amazonaws.com"]` | ...specifically CloudFront. |
| `condition { ... aws:SourceArn = distribution.arn }` | **Only allow when the request comes from this specific distribution.** |

#### Why the `aws:SourceArn` condition matters

Without it, the policy says *"any CloudFront distribution anywhere may read my
bucket."* A malicious account could theoretically configure their own
CloudFront with our bucket as an origin and start reading. The `aws:SourceArn`
condition checks the calling distribution's ARN against ours — only **our**
distribution can read. Single line of defense; huge security improvement.

#### The attachment

```hcl
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_oac_read.json
}
```

Just attaches the rendered JSON policy to the bucket.

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

| Output | What it's for |
|---|---|
| `cloudfront_domain_name` | The auto-generated `*.cloudfront.net` URL you open in a browser / curl. |
| `cloudfront_distribution_id` | Needed for `aws cloudfront create-invalidation --distribution-id ...` after a redeploy. |
| `frontend_bucket` | The S3 bucket name you `aws s3 sync` the React `dist/` into. |

---

## 9. Two small retroactive edits (so `/api/*` works cleanly)

Up to now the backend served `/patients`, not `/api/patients`. To keep CloudFront
simple (no path rewriting) and produce a clean, professional URL scheme, we mount
the API routes under `/api`. Two small edits — one to the backend, one to the
frontend.

### Why mount the API under `/api` now

Three reasons:

1. **CloudFront routing** — the cleanest behavior split is *"path starts with
   `/api/` → ALB; anything else → S3"*. If the backend's routes were at `/`,
   the path patterns would have to be far more complex.
2. **Same-origin removes CORS** — the frontend can call `/api/patients` and the
   browser sees it as same-origin (because both come from the same CloudFront
   host). No preflight, no `Access-Control-*` headers needed.
3. **Clean URL scheme** — `cloudcare.com/api/patients` is a professional
   convention; `cloudcare.com/patients` would conflict with frontend routes
   (`/patients/42` is a UI page, not an API call).

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

### What `APIRouter(prefix=...)` does

`APIRouter` is FastAPI's way to group related routes. With `prefix="/api"`,
every route declared on it is automatically prefixed:

| You write | Route URL |
|---|---|
| `@router.get("/patients")` | `GET /api/patients` |
| `@router.post("/patients")` | `POST /api/patients` |
| `@router.get("/appointments")` | `GET /api/appointments` |

`app.include_router(router)` mounts the whole group on the app.

**Why `/health` stays at `@app.get(...)` not `@router.get(...)`**: the ALB
target group health check (Doc 13) hits `/health`. Moving it to `/api/health`
would require also updating the target group's `path` — more moving parts.
Keeping the operational endpoint at the root is also a common production
pattern.

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

### How the BASE selection works in dev vs prod

| Environment | `VITE_API_URL` set? | `BASE` value | Final URL |
|---|---|---|---|
| Local dev | `http://localhost:8000` | `"http://localhost:8000"` | `http://localhost:8000/api/patients` |
| Production build | not set | `""` (empty string) | `/api/patients` (browser resolves to same origin) |

The `??` operator is the **nullish coalescing operator**: returns the
right-hand value only if the left side is `null` or `undefined`. (Vite leaves
unset env vars as `undefined`.) `||` would also fire on empty string, which
we'd want to *use* for same-origin.

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

> ⚠️ **AWS verification (first-time account):** On a brand-new account, AWS may
> refuse to create a CloudFront distribution until they verify your account —
> the apply errors with *"Your account must be verified before you can add new
> CloudFront resources."* If you hit this, open a support case (free tier
> allows it) describing your use case. Approval takes ~24–48 hours. The S3
> bucket and OAC will already be created; just re-apply after approval.

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

### Each command, decoded

| Command | Meaning |
|---|---|
| `npm install` | Pull React + Vite deps (cached after first run). |
| `npm run build` | Vite builds the production bundle into `dist/`. |
| `BUCKET=$(...)` / `DIST=$(...)` | Capture Terraform outputs into shell vars. |
| `aws s3 sync dist/ "s3://$BUCKET/"` | Upload every file in `dist/` to the bucket, mirroring the structure. |
| `--delete` | **Also remove** S3 objects that aren't in `dist/` (e.g. stale JS bundles from previous builds). Keeps the bucket clean. |

### 10c. Invalidate the CloudFront cache

CloudFront caches everything aggressively. After every upload, **invalidate** so
viewers see the new files instead of stale cached ones:

```bash
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*"
```

### What invalidation actually does

`/*` tells CloudFront: *"forget every cached object."* On the next request,
each edge has to fetch fresh from the origin. Without invalidation, viewers
keep seeing the **old** files until their TTL expires (could be hours/days).

> 💰 **Invalidations:** the first 1,000 paths per month are free; after that
> ~$0.005/path. A single `"/*"` counts as one path, so cheap.

### Why hash-busting avoids most invalidations in real deploys

Vite's hash-busting means filenames like `assets/index-a3f1b.js` change on
every build with a different content. The browser (and CloudFront) treat
`index-a3f1b.js` and `index-9d8e7.js` as **completely different objects** — no
invalidation needed. The only thing that doesn't change name is `index.html`
itself; that's the one file you actually need to invalidate after a deploy.

Modern deploys often invalidate `/index.html` (or `/`) instead of `/*` to save
even on the rare paths-per-month case.

---

## 11. Verify end-to-end

```bash
CF=$(cd terraform/cdn && terraform output -raw cloudfront_domain_name)
echo "Open https://$CF/ in your browser"

# Confirm both behaviors work:
curl -sI "https://$CF/"                 # should be 200 with content-type text/html (S3)
curl -s  "https://$CF/api/patients"     # should be JSON from the ALB
```

### What each response header tells you

When you `curl -i` the CloudFront URL, look for these headers in the response:

| Header | What it tells you |
|---|---|
| `server: AmazonS3` | The content came from S3 (default behavior). |
| `server: uvicorn` | The content came from FastAPI on EC2 (via the ALB). |
| `x-cache: Hit from cloudfront` | Served from the edge cache — fast. |
| `x-cache: Miss from cloudfront` | Cache miss; fetched from origin. **Normal for /api/* every time** (CachingDisabled). |
| `x-cache: Error from cloudfront` | CloudFront couldn't cache (e.g. 4xx/5xx response); not a real error. |
| `age: <seconds>` | How long the edge has been holding this cached copy. |
| `x-amz-cf-pop: MRS53-P4` | Which edge served the response (Marseille, in this case). |

So:
- Frontend works → `200 + server: AmazonS3 + x-cache: Hit` (after the first
  request).
- API works → `200 + server: uvicorn + x-cache: Miss` (every time, by design).

Open the CloudFront URL in a browser — the React UI loads from S3, and the
patient/appointment forms call `/api/...` which CloudFront forwards to the ALB,
which hits an EC2 instance, which reads/writes RDS. **One HTTPS URL, the whole
stack.**

### Common things that go wrong (and how to spot them)

| Symptom | Likely cause | Fix |
|---|---|---|
| `/api/*` → `502 Bad Gateway` | Stale ALB DNS in the distribution (compute was recreated) | Re-apply `terraform/cdn/` to re-read `alb_dns_name` |
| `/api/*` → `502` *and* you just rebuilt the image | App is crashing on boot (DB / secret) | SSM into instance; check `docker logs` |
| `/api/health` → `404` | Backend doesn't have `/health` (e.g. commented out) | Uncomment / restore the route, rebuild + push + refresh |
| `/api/patients` → `404` | Routes aren't under `/api` (still at `/patients`) | Apply the §9a `APIRouter(prefix="/api")` change |
| Static page → `403 Access Denied` | Bucket policy not applied yet or `aws:SourceArn` mismatched | `terraform apply` again; check the policy attaches |
| Browser shows old UI after deploy | Cached `index.html` | `aws cloudfront create-invalidation --paths /` or `/*` |

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

## 13. Plain-English summary (what you just built)

If asked to explain Phase 5:

1. **One private S3 bucket** (`cloudcare-frontend-<account-id>`) with versioning,
   AES-256 encryption, **all public access blocked**. The React `dist/` lives
   here.
2. **One CloudFront distribution** with:
   - **Two origins**: S3 (private, OAC-signed) and the ALB (HTTP-only).
   - **Default behavior** → S3, `CachingOptimized`, methods `GET/HEAD`,
     `redirect-to-https`.
   - **`/api/*` ordered behavior** → ALB, `CachingDisabled`, all methods,
     forward everything (`AllViewer`).
   - **SPA fallback**: 403/404 from S3 → rewritten to 200 + `/index.html`.
   - **Free `*.cloudfront.net` TLS cert.**
3. **One OAC** (modern OAI) that signs CloudFront's requests to S3.
4. **One bucket policy** granting `s3:GetObject` to CloudFront with an
   `aws:SourceArn` condition pinning to **this** distribution only.
5. **Backend mounted under `/api`**, frontend calling `/api/*` same-origin — no
   CORS in production.
6. End-to-end: one HTTPS URL serves the static SPA + dynamic API + cache split,
   over free HTTPS, with the bucket never publicly reachable.

---

## 14. Interview soundbites

- **Why CloudFront in front of S3** — *"Plain S3 static-website hosting is
  public, HTTP-only on the bucket endpoint, and single-region. CloudFront puts
  the bucket behind a private OAC, gives me free HTTPS, caches at hundreds of
  edges, and lets me route different paths to different origins. It's strictly
  better, basically free."*

- **OAC vs OAI** — *"OAC (Origin Access Control) is the modern replacement for
  OAI (Origin Access Identity). It uses SigV4 signing, supports more origin
  types, works with KMS-encrypted buckets, and scopes access via
  `aws:SourceArn`. New projects always use OAC."*

- **The two-behavior split** — *"One distribution, two cache policies: static
  assets use `CachingOptimized` (long TTLs, gzip+brotli, edge does most of the
  work); `/api/*` uses `CachingDisabled` (every request goes to the ALB for
  freshness). Combined with same-origin serving, this removes CORS and gives
  the user the lowest possible latency for both."*

- **`aws:SourceArn` on the bucket policy** — *"The bucket policy grants
  `s3:GetObject` to the CloudFront service principal, but with an
  `aws:SourceArn` condition that pins it to **my** specific distribution. Without
  that condition, any CloudFront in any account could fetch the bucket. With
  it, only mine can."*

- **SPA fallback** — *"`custom_error_response` turns S3's 403/404 into a 200
  with `/index.html`. That lets client-side routing handle deep URLs like
  `/patients/42` even though no such file exists in the bucket."*

- **Cache invalidation strategy** — *"For most builds I rely on Vite's
  hash-busted filenames — each new bundle is a new object so the cache misses
  naturally. Only `index.html` (which doesn't have a hash) needs explicit
  invalidation. The first 1,000 paths/month are free."*

- **The cross-stack ALB pin pitfall** — *"The CDN reads `alb_dns_name` from
  the compute stack's remote state at plan time. If compute is destroyed and
  recreated, the ALB gets a new DNS — CloudFront still points at the old one
  until I re-apply the CDN. Symptom: frontend fine, `/api/*` → 502. The fix
  is mechanical: re-apply the downstream stack after any upstream rebuild."*

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
- Why the `aws:SourceArn` condition pins the bucket policy to one specific
  distribution.
- The "rebuild compute → re-apply CDN" footgun.

**Tell me when you've reached this checkpoint**, and I'll write **Phase 6 —
Serverless**: an API Gateway + Lambda + DynamoDB feature for appointment
notifications / an audit log (traced with X-Ray), and a Lambda + SES contact form
— the two serverless slices from the original architecture diagrams.

Next: **Phase 6 — Serverless** (docs 16–17, written when you reach this
checkpoint).
