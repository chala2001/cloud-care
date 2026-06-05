# 19 — CI/CD with GitHub Actions (OIDC federation)

> **Goal of this doc:** wire CloudCare to GitHub so changes ship automatically.
> Pull requests run `terraform plan`; merges to `main` apply Terraform, build &
> push the backend image, deploy the frontend to S3, and invalidate CloudFront.
> All without storing **any** long-lived AWS keys in GitHub — we use **OIDC
> federation** so GitHub Actions assumes an AWS role with short-lived,
> auto-rotated credentials. This is the modern way to do CI/CD on AWS and a
> guaranteed interview topic.

⏱️ Time: ~75 minutes. 💰 Cost: ~$0 (GitHub Actions has a free tier; AWS API
calls and a couple of CloudFront invalidations are negligible).

This is the first doc of **Phase 8 — Productionizing**.

---

## 0. Beginner read-me first — vocabulary in one place

CI/CD on AWS uses both GitHub-side terms and AWS-side terms. Re-read this
whenever a term feels foreign.

| Word | Plain-English meaning |
|---|---|
| **CI** (Continuous Integration) | Automatically running checks (build, test, lint, plan) on every code change. |
| **CD** (Continuous Delivery/Deployment) | Automatically shipping merged changes to a target environment. |
| **Workflow** | One YAML file in `.github/workflows/` that GitHub Actions runs in response to events. |
| **Event / Trigger** | What kicks off a workflow: `push`, `pull_request`, schedule, manual dispatch. |
| **Job** | A unit of work in a workflow that runs on one runner. Workflows can have many jobs (parallel by default; can declare dependencies). |
| **Step** | An ordered command or pre-built **action** inside a job. |
| **Action** | A reusable, versioned bundle of steps (e.g. `actions/checkout@v4`). Think "library function." |
| **Runner** | The VM (or container) the workflow executes on. GitHub-hosted runners are ephemeral and fresh per job. |
| **`runs-on: ubuntu-latest`** | Use a GitHub-hosted Ubuntu runner. |
| **`permissions:`** | Per-job GitHub token scopes. **`id-token: write`** is required for OIDC. |
| **`vars` vs `secrets`** (GitHub) | Both are repo/org-level config. **Variables** are visible (logs, etc.); **secrets** are masked. Use variables for non-sensitive values (like an IAM role ARN). |
| **OIDC** (OpenID Connect) | An identity protocol layered on OAuth 2.0. GitHub mints a signed JWT per workflow run; AWS verifies it. |
| **JWT** (JSON Web Token) | A signed token containing claims about who/what it represents. Format: `<header>.<payload>.<signature>`. |
| **Web identity** | A token issued by an external provider (GitHub, Google, etc.) that AWS accepts via `sts:AssumeRoleWithWebIdentity`. |
| **`sts:AssumeRoleWithWebIdentity`** | The AWS API call that exchanges a web-identity token for short-lived AWS credentials. |
| **Federated principal** | An IAM principal (a "who can assume") that lives outside AWS — like GitHub's OIDC provider. |
| **Trust policy** | The IAM policy on a role that says *"these principals may assume me, under these conditions."* |
| **`sub` claim** | The "subject" field in the GitHub OIDC token. Looks like `repo:owner/name:ref:refs/heads/main`. The single most important field for security scoping. |
| **OIDC provider (IdP)** in IAM | An AWS resource (`aws_iam_openid_connect_provider`) that registers an external identity issuer (GitHub) as trusted in your account. One per account. |
| **`paths:` filter** | A workflow trigger filter that only runs the workflow when files matching the listed globs change. |
| **`GITHUB_ENV`** | A magic file in each step. Lines you write to it become env vars in **subsequent** steps. |
| **`workflow_dispatch`** | A trigger that lets you run a workflow manually from the GitHub UI. Useful for one-shot deploys. |
| **Path-based concurrency** | Limiting one workflow to run at a time per branch/path; prevents racing apply runs. |
| **Branch protection** | A GitHub setting that requires PR + passing checks before a branch can be updated. |
| **Instance refresh** | The ASG action that replaces existing instances with new ones — how a new image rolls out. |

Now the why.

---

## 1. Why OIDC (and not GitHub repo secrets with `AKIA...` keys)

The "easy" pattern is to mint a long-lived AWS access key for a CI user and
paste it into GitHub repo secrets. Don't. **The modern, AWS-recommended pattern
is OIDC federation:**

```
GitHub Actions job  ─ requests an OIDC token from github.com
                       │
                       ▼
                 AWS STS  AssumeRoleWithWebIdentity
                       │  (trusts GitHub's OIDC provider,
                       │   scoped to a specific repo + branch)
                       ▼
              Short-lived (1 hour) AWS creds for the job
```

Why it's better:

| Stored secrets | Long-lived keys | OIDC |
|----------------|----------------|------|
| What lives in GitHub | `AKIA...` access key + secret | **nothing** (just an ARN) |
| Lifetime | until you rotate them (rarely) | **1 hour**, minted fresh per job |
| Scope | usually account-wide | scoped to **one repo, certain refs** |
| Revocation | manual key delete | delete role / change trust policy |

### What's actually in the GitHub OIDC token (the JWT)

A workflow run gets a JWT from GitHub that looks (decoded) like this:

```json
{
  "iss": "https://token.actions.githubusercontent.com",
  "aud": "sts.amazonaws.com",
  "sub": "repo:chala2001/cloud-care:ref:refs/heads/main",
  "repository": "chala2001/cloud-care",
  "ref": "refs/heads/main",
  "actor": "chala2001",
  "workflow": "Terraform",
  "exp": 1717497600,
  ...
}
```

The role's trust policy in AWS verifies:
- `iss` (issuer) = GitHub's OIDC URL → registered IdP.
- `aud` (audience) = `sts.amazonaws.com` → meant for AWS.
- `sub` matches your patterns (`repo:owner/name:ref:refs/heads/main` etc.) → the right repo + branch.
- Signature checks against GitHub's published JWKS keys.

If any check fails, AWS rejects with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Forks, other repos, other refs — all blocked **by signature + claims**, not by trust on the IP/HTTP level.

> 🧠 **Interview answer:** "We use GitHub OIDC: GitHub mints a signed JWT per
> workflow run, AWS verifies it against the GitHub OIDC provider, and we restrict
> the trust policy to specific `repo:owner/name` and refs. Result: no AWS keys in
> the repo, short-lived credentials, auditable per workflow run."

---

## 2. Push the project to GitHub first

This doc assumes the project is in a GitHub repo. If it isn't yet:

```bash
cd /home/chalaka/cloud-care
git init -b main      # if it isn't already
git add . && git commit -m "Initial CloudCare commit"
# Create a NEW empty private repo on github.com first (no README/license — empty)
git remote add origin git@github.com:<your-github-user>/cloud-care.git
git push -u origin main
```

| Command | Meaning |
|---|---|
| `git init -b main` | Initialize a git repo with `main` as the default branch. |
| `git add . && git commit -m "..."` | Stage everything and commit. |
| `git remote add origin git@github.com:...` | Tell git the URL of the remote repo (SSH form; `https://...` works too). |
| `git push -u origin main` | Push the local `main` and set it as the tracking branch for future `git push`. |

Note your GitHub `<owner>/<repo>` (e.g., `chala2001/cloud-care`) — you'll use it
in §4.

> ⚠️ **Push to a PRIVATE repo.** Your Terraform isn't secret, but tying a public
> repo to a real AWS account is a footgun: any open PR (from anyone) that
> touches a workflow could trigger an OIDC assume. Private repo + branch
> protection is the safe default for a learning project.

---

## 3. The new Terraform stack

```
terraform/
├── …existing stacks…
└── cicd/
    ├── providers.tf
    ├── variables.tf
    ├── oidc.tf       # the GitHub OIDC provider + the deploy role
    └── outputs.tf
```

### File-purpose table

| File | One-line purpose |
|---|---|
| `providers.tf` | AWS provider + S3 backend at `cicd/`. |
| `variables.tf` | Inputs: region, project, **your GitHub owner + repo name (no defaults — required)**. |
| `oidc.tf` | Register GitHub as an OIDC IdP + create the role with a scoped trust policy. |
| `outputs.tf` | Publish the role ARN (you paste this into a GitHub repo variable). |

---

## 4. `providers.tf`, `variables.tf`

```hcl
# terraform/cicd/providers.tf
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "cicd/terraform.tfstate"
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
      Component = "cicd"
    }
  }
}
```

```hcl
# terraform/cicd/variables.tf
variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "cloudcare"
}

variable "github_owner" {
  description = "Your GitHub user or organization (e.g., chala2001)"
  type        = string
}

variable "github_repo" {
  description = "The CloudCare repo name (e.g., cloud-care)"
  type        = string
}
```

`terraform/cicd/terraform.tfvars`:
```hcl
github_owner = "chala2001"
github_repo  = "cloud-care"
```

### Walk-through — what's new

| Line | Meaning |
|---|---|
| `key = "cicd/terraform.tfstate"` | New state path. |
| `github_owner` / `github_repo` **no default** | Forces you to specify both — otherwise Terraform prompts/fails. Prevents accidentally minting a role trusting "anyone." |

---

## 5. `oidc.tf` — the OIDC provider + the scoped role

```hcl
# terraform/cicd/oidc.tf

# Register GitHub as a trusted OIDC IdP for this AWS account. (You only need
# ONE of these per account, even if you have many repos.)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # AWS validates the cert chain against trusted roots automatically; the
  # thumbprint field is still required by the API. The value below is GitHub's
  # well-known thumbprint at time of writing. AWS uses this as a hint only.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust policy: only this repo, only main branch OR pull request events.
data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # The audience GitHub places in the JWT.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The `sub` claim encodes which repo/ref the workflow is running for.
    # We allow only: pushes to main, and PRs (any branch into any branch).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_owner}/${var.github_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.project}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

# For a learning project we attach AdministratorAccess so all three workflows
# (Terraform, backend, frontend) work without authoring a sprawling policy.
# Production split: one ROLE PER WORKFLOW, each with the smallest possible
# policy. Mention that in interviews — it's the obvious next hardening step.
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```

### Walk-through

#### Block 1 — register GitHub as an OIDC IdP

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

| Field | Meaning |
|---|---|
| `url` | GitHub's OIDC issuer URL. Must be HTTPS. AWS will fetch its JWKS keys from here to verify token signatures. |
| `client_id_list = ["sts.amazonaws.com"]` | The **audience** values AWS accepts. GitHub's OIDC tokens have `aud=sts.amazonaws.com` by default for AWS, so this is the required string. |
| `thumbprint_list = [...]` | The TLS certificate thumbprint of GitHub's OIDC endpoint. Required by the API but **AWS validates the cert chain against trusted roots regardless** — this field is essentially a hint now. |

> ⚠️ **You only need ONE OIDC provider per AWS account.** If you already have
> one for GitHub from another project, `terraform import` it here instead of
> creating a duplicate (AWS allows only one provider per URL).

#### Block 2 — the trust policy document

```hcl
data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition { ... aud ... }
    condition { ... sub ... }
  }
}
```

| Line | Meaning |
|---|---|
| `actions = ["sts:AssumeRoleWithWebIdentity"]` | The specific STS API for federated identities. (Not `sts:AssumeRole`, which is for AWS-internal assumes.) |
| `principals.type = "Federated"` | The "who" is an external IdP (vs `Service` for AWS services or `AWS` for AWS accounts). |
| `principals.identifiers = [aws_iam_openid_connect_provider.github.arn]` | Specifically, GitHub's OIDC provider we registered above. |

##### The `aud` condition (must match)

```hcl
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:aud"
  values   = ["sts.amazonaws.com"]
}
```

Checks that the JWT's `aud` claim equals `sts.amazonaws.com`. This is the
**audience** field meaning "intended for AWS." Anyone receiving the token
verifies they're the intended audience — defense against token reuse attacks.

##### The `sub` condition (the security backbone)

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values = [
    "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_owner}/${var.github_repo}:pull_request",
  ]
}
```

The `sub` claim format encodes the running workflow's context:

| Trigger | `sub` value |
|---|---|
| push to a branch | `repo:owner/name:ref:refs/heads/<branch>` |
| pull request | `repo:owner/name:pull_request` |
| tag push | `repo:owner/name:ref:refs/tags/<tag>` |
| environment-scoped run | `repo:owner/name:environment:<env>` |

Our trust policy allows **only**:
1. Pushes to **main** in *our* repo.
2. **PRs** in *our* repo (any branch into any branch).

Forks, other repos, other branches → `sub` doesn't match → STS refuses.
`StringLike` (vs `StringEquals`) supports `*` wildcards if needed, but we use
exact strings here to be precise.

> 🧠 **The `sub` condition is the security backbone.** Without it, *any* GitHub
> repo on the internet could theoretically assume your role. With it, only your
> repo + listed refs can. If you forked the repo to test, the fork's `sub`
> wouldn't match and the assume call would fail — exactly what you want.

> ⚠️ **Don't widen this to `"repo:owner/repo:*"`** without thinking. The `*`
> wildcard also matches workflows running on forks/PRs from forks (which can be
> opened by anyone). Restricting to specific refs is the safe default.

#### Block 3 — the role itself

```hcl
resource "aws_iam_role" "deploy" {
  name               = "${var.project}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}
```

Just creates the role and plugs in the trust policy. No permissions yet.

#### Block 4 — attach AdministratorAccess (lab-only)

```hcl
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```

For a learning project, attaching `AdministratorAccess` lets all three workflows
work without authoring a sprawling per-service policy. **In production this is
the lazy mistake** — instead you'd split into one role per workflow with the
minimum policy each needs (e.g., the frontend workflow needs S3 + CloudFront, not
EC2/IAM).

| Workflow | Production permissions it'd need |
|---|---|
| Terraform apply | Broad — `iam:*`, `ec2:*`, `rds:*`, `lambda:*`, etc. (or per-stack roles) |
| Backend image | `ecr:*` (limited to one repo), `autoscaling:StartInstanceRefresh`, scoped DescribeInstances |
| Frontend deploy | `s3:PutObject/DeleteObject` on one bucket, `cloudfront:CreateInvalidation` on one distribution |

Mention this split in interviews — it's the obvious next hardening step.

---

## 6. `outputs.tf`

```hcl
# terraform/cicd/outputs.tf
output "deploy_role_arn" {
  description = "Set this as the GitHub Actions repo variable AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}
```

Apply:

```bash
cd terraform/cicd
terraform init
terraform plan      # 3 to add
terraform apply

# Grab the ARN — you'll paste it into GitHub next:
terraform output -raw deploy_role_arn
```

The ARN looks like: `arn:aws:iam::670794226080:role/cloudcare-github-deploy`.

---

## 7. Configure the GitHub repo

In the GitHub UI, open your CloudCare repo and:

### Step 1 — Add the role ARN as a repo variable

1. **Settings → Secrets and variables → Actions → Variables tab → New repository variable**:
   - Name: `AWS_DEPLOY_ROLE_ARN`
   - Value: (the ARN you just printed)

#### Why a variable, not a secret?

| | Variable | Secret |
|---|---|---|
| Visible in logs | ✅ yes | ❌ masked as `***` |
| Best for | non-sensitive config | API keys, passwords, tokens |

The role ARN **isn't sensitive on its own** — knowing the ARN doesn't let
anyone assume it. Only a workflow in **your** repo, running on the right ref,
can get GitHub to mint a token whose `sub` matches.

> 🧠 **Variable, not secret.** This ARN isn't sensitive — anyone reading it
> can't *use* it without GitHub minting a JWT for your repo. Storing it as a
> variable means it's visible in logs (handy for debugging) and there's no
> masking churn.

### Step 2 — Add branch protection on `main`

1. **Settings → Branches → Add branch protection rule** for `main`:
   - Require a pull request before merging.
   - Require status checks to pass (we'll add the Terraform plan check next).

This prevents direct pushes to `main` and forces every change through a PR
where the Terraform plan workflow runs first — your safety net.

---

## 8. The three workflows

Create the folder `.github/workflows/` in the repo root and the three files
below.

### Common structure

Every workflow has these sections:

```yaml
name: <human-readable name>    # shown in the GitHub UI
on:                            # what triggers the workflow
  ...
permissions:                   # token scopes the job needs
  ...
env:                           # workflow-wide env vars
  ...
jobs:                          # one or more jobs
  job_name:
    runs-on: <runner type>
    steps:                     # ordered actions/commands
      - ...
```

### 8a. `.github/workflows/terraform.yml` — plan-on-PR, apply-on-main

```yaml
name: Terraform

on:
  pull_request:
    paths: ["terraform/**", ".github/workflows/terraform.yml"]
  push:
    branches: [main]
    paths: ["terraform/**", ".github/workflows/terraform.yml"]

# OIDC needs id-token; reading the repo needs contents.
permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1
  # Dependency-ordered list. Apply runs the loop top-to-bottom; destroy would
  # reverse it. cicd/ is excluded since it bootstraps THIS workflow.
  STACKS: "bootstrap network database compute cdn serverless-audit serverless-contact observability"

jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.9.0

      - name: Plan or Apply each stack
        run: |
          set -euo pipefail
          for stack in $STACKS; do
            echo "::group::terraform $stack"
            cd "terraform/$stack"
            terraform init -input=false
            if [[ "${{ github.event_name }}" == "pull_request" ]]; then
              terraform plan -input=false -no-color
            else
              terraform apply -input=false -auto-approve
            fi
            cd - > /dev/null
            echo "::endgroup::"
          done
```

#### Walk-through

**Triggers (`on:`)**:
```yaml
on:
  pull_request:
    paths: ["terraform/**", ".github/workflows/terraform.yml"]
  push:
    branches: [main]
    paths: ["terraform/**", ".github/workflows/terraform.yml"]
```

| Line | Meaning |
|---|---|
| `pull_request:` | Run on PR open/sync/reopen. |
| `paths: [...]` | **Only** if files matching these globs changed. `terraform/**` = anything in the terraform tree; the workflow file itself triggers it too. |
| `push: branches: [main]` | Run on push to main (i.e., after merge). |

**Permissions**:
```yaml
permissions:
  id-token: write
  contents: read
```

| Line | Meaning |
|---|---|
| `id-token: write` | **Required for OIDC.** Lets the workflow request a JWT from GitHub. |
| `contents: read` | Required for `actions/checkout` to read the repo. |

**Environment**:
```yaml
env:
  AWS_REGION: ap-south-1
  STACKS: "bootstrap network database compute cdn serverless-audit serverless-contact observability"
```

A workflow-wide variable for the dependency-ordered list of stacks. Hard-coding
the order ensures network applies before compute applies before cdn, etc.

> 🧠 **One loop, dependency-ordered.** Network must apply before compute, which
> must apply before CDN, etc. The list encodes that. GitHub Actions' matrix
> *can't* guarantee order, so we use a plain shell loop.

**The steps**:

| Step | Meaning |
|---|---|
| `actions/checkout@v4` | Clone the repo onto the runner. Required for any workflow that needs source code. |
| `aws-actions/configure-aws-credentials@v4` | The OIDC magic. With `role-to-assume`, it asks GitHub for a JWT, calls `sts:AssumeRoleWithWebIdentity`, sets `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` env vars for subsequent steps. |
| `hashicorp/setup-terraform@v3` | Install the Terraform CLI on the runner. Pin a version with `terraform_version`. |
| Custom `run:` step | The shell loop that plans or applies based on the trigger. |

**The shell loop**:
```bash
for stack in $STACKS; do
  echo "::group::terraform $stack"
  cd "terraform/$stack"
  terraform init -input=false
  if [[ "${{ github.event_name }}" == "pull_request" ]]; then
    terraform plan -input=false -no-color
  else
    terraform apply -input=false -auto-approve
  fi
  cd - > /dev/null
  echo "::endgroup::"
done
```

| Piece | Meaning |
|---|---|
| `::group::name` / `::endgroup::` | GitHub Actions log-folding directives — makes the UI collapsible per stack. |
| `terraform init -input=false` | Init with no interactive prompts. |
| `${{ github.event_name }}` | GitHub Actions expression — the trigger name (`pull_request`, `push`, etc.). |
| `terraform plan -no-color -input=false` | Dry-run only, no colors (cleaner logs). |
| `terraform apply -auto-approve -input=false` | Apply non-interactively. |
| `cd - > /dev/null` | Go back to previous directory, suppress its output. |

> 💡 **`bootstrap` rarely changes** — you could remove it from the list once
> stable. Leaving it in is a "noop apply" (Terraform reports `0 to add, 0 to
> change`) and proves the role can see it, which is useful diagnostically.

### 8b. `.github/workflows/backend.yml` — build, push, roll

```yaml
name: Backend image

on:
  push:
    branches: [main]
    paths: ["app/backend/**", ".github/workflows/backend.yml"]

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: aws-actions/amazon-ecr-login@v2

      - uses: hashicorp/setup-terraform@v3

      - name: Read ECR URL and ASG name from compute state
        run: |
          cd terraform/compute
          terraform init -input=false
          {
            echo "REPO=$(terraform output -raw ecr_repository_url)"
            echo "ASG=$(terraform output -raw asg_name)"
          } >> "$GITHUB_ENV"

      - name: Build & push image
        run: |
          cd app/backend
          # Tag with both the commit SHA (immutable) and :latest (what the LT pulls)
          docker build -t "$REPO:${GITHUB_SHA}" -t "$REPO:latest" .
          docker push "$REPO:${GITHUB_SHA}"
          docker push "$REPO:latest"

      - name: Roll the ASG so instances pull the new image
        run: |
          aws autoscaling start-instance-refresh \
            --auto-scaling-group-name "$ASG" \
            --preferences MinHealthyPercentage=50
```

#### Walk-through — what's different from the Terraform workflow

| Element | Why |
|---|---|
| `paths: ["app/backend/**", ...]` | Only run when backend code changes — skips CI for unrelated edits. |
| `aws-actions/amazon-ecr-login@v2` | Authenticate Docker to ECR using the assumed role's credentials. |
| **Reading Terraform outputs** | The script reads `ecr_repository_url` and `asg_name` from the compute stack's state and writes them to `$GITHUB_ENV` so subsequent steps have them as env vars. |

#### The `$GITHUB_ENV` trick

```yaml
{
  echo "REPO=$(terraform output -raw ecr_repository_url)"
  echo "ASG=$(terraform output -raw asg_name)"
} >> "$GITHUB_ENV"
```

`$GITHUB_ENV` is a magic file path in every step. **Lines you append to it
become env vars in *subsequent* steps.** This is GitHub Actions' standard way
to pass values between steps. (You can't set normal env vars across steps —
each step runs in a fresh shell.)

After this step, `$REPO` and `$ASG` are usable in any later step's `run:`.

#### The double-tag pattern

```bash
docker build -t "$REPO:${GITHUB_SHA}" -t "$REPO:latest" .
docker push "$REPO:${GITHUB_SHA}"
docker push "$REPO:latest"
```

`docker build -t a -t b` builds **one image** and tags it with **two names**.
We push both:

| Tag | Purpose |
|---|---|
| `:${GITHUB_SHA}` | **Immutable** version pinned to this exact commit. For rollback ("redeploy the SHA from yesterday") and forensic tracing. |
| `:latest` | **Mutable**. What the launch template's `docker pull` looks for. Always points at the newest deploy. |

> 🧠 **Why tag with `${GITHUB_SHA}` AND `latest`.** `latest` is what the launch
> template pulls (so the rollout is one-command). The SHA tag is the
> *immutable* version — useful when you need to roll back: pull the SHA tag from
> the previous deploy and run an instance refresh.

#### The instance refresh

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG" \
  --preferences MinHealthyPercentage=50
```

This tells the ASG to **replace** instances with new ones. The new EC2s boot
with the same launch template; their `user_data` does `docker pull
:latest` → gets the new image; ALB health check passes; ASG drains the old
instances. Zero-downtime rollout (with `MinHealthyPercentage=50`, at least half
the fleet stays serving during the refresh).

### 8c. `.github/workflows/frontend.yml` — build, sync, invalidate

```yaml
name: Frontend deploy

on:
  push:
    branches: [main]
    paths: ["app/frontend/**", ".github/workflows/frontend.yml"]

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - uses: hashicorp/setup-terraform@v3

      - name: Read bucket and distribution from cdn state
        run: |
          cd terraform/cdn
          terraform init -input=false
          {
            echo "BUCKET=$(terraform output -raw frontend_bucket)"
            echo "DIST=$(terraform output -raw cloudfront_distribution_id)"
          } >> "$GITHUB_ENV"

      - name: Build the SPA
        working-directory: app/frontend
        run: |
          npm ci
          npm run build      # VITE_API_URL unset → same-origin /api/* calls

      - name: Sync to S3 and invalidate CloudFront
        run: |
          aws s3 sync app/frontend/dist/ "s3://$BUCKET/" --delete
          aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*"
```

#### Walk-through — what's different

| Element | Meaning |
|---|---|
| `actions/setup-node@v4` + `node-version: 20` | Install Node.js 20 on the runner. |
| `working-directory: app/frontend` | Per-step `cd`. All `run:` commands in this step start there. |
| `npm ci` | "Clean install" — wipes `node_modules/` and installs exactly what `package-lock.json` says. **Use in CI** instead of `npm install` because it's faster, deterministic, and refuses if the lockfile is out of date. |
| `npm run build` | Vite production build. With `VITE_API_URL` unset, the bundle calls `/api/*` paths same-origin (handled by the CloudFront `/api/*` behavior). |
| `aws s3 sync ... --delete` | Upload changed files, delete removed ones. |
| `aws cloudfront create-invalidation --paths "/*"` | Force CloudFront to forget everything cached — viewers see the new bundle immediately. |

> 💡 **Path filters (`paths:` keys)** keep each workflow focused: the backend
> job doesn't run when you tweak the frontend, and vice versa. Faster CI, less
> noise.

---

## 9. Test the pipeline

### Step 1 — Test the PR plan path

Create a branch, change one Terraform file (e.g., add a tag), open a PR. The
`Terraform` workflow runs `plan` for every stack. The PR should NOT apply
anything.

In the PR view, you should see:
- A "Terraform" check appear, run, and turn green/red.
- The plan output in the logs (under each `::group::` heading).
- **No infrastructure changes** in AWS — only a dry-run.

### Step 2 — Test the apply path

Merge the PR to `main`. The `Terraform` workflow re-runs and **applies** each
stack in order. Open the Actions tab — you should see one "Terraform" run
showing the apply output for every stack.

### Step 3 — Test backend rollout

Change a string in `app/backend/app/main.py` (e.g., the `/health` response).
Push to main. The `Backend image` workflow:
1. Builds a Docker image tagged with the commit SHA + `latest`.
2. Pushes both to ECR.
3. Starts an instance refresh on the ASG.

Watch the ASG roll in the EC2 console (or
`aws elbv2 describe-target-health ...`), then
`curl https://<cloudfront>/health` to see the new response.

### Step 4 — Test frontend deploy

Change a heading in `app/frontend/src/App.jsx`, push to main. The `Frontend
deploy` workflow:
1. Runs `npm ci && npm run build`.
2. Syncs `dist/` to S3 with `--delete`.
3. Creates a `/*` CloudFront invalidation.

Reload your CloudFront URL — the new UI appears (within a few seconds of the
invalidation completing).

---

## 10. Common failures & fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` doesn't match | Re-check `${var.github_owner}/${var.github_repo}` and that the run is on `main` or a PR |
| `AccessDenied` on an AWS API call | Role lacks the permission | Add it; for the lab, AdministratorAccess covers everything |
| `Terraform plan` shows huge unrelated changes | Local state drift vs S3 backend | Don't `apply` locally and via CI on the same stack; pick one. CI wins in production |
| `docker push` is denied | ECR login step missing or wrong region | Ensure `aws-actions/amazon-ecr-login@v2` runs after `configure-aws-credentials` |
| Workflow doesn't trigger on edit | `paths:` filter excludes your change | Adjust the filter or add the file's directory |
| `npm ci` fails with "lockfile out of date" | `package.json` changed but `package-lock.json` wasn't updated | Run `npm install` locally and commit the new lockfile |
| CloudFront still serves old content after deploy | Invalidation not yet propagated | Wait ~1-2 min; refresh with cache bypass (Cmd+Shift+R) |

### How to diagnose an OIDC failure

```bash
# 1. Confirm the role exists and the trust policy is what you think
aws iam get-role --role-name cloudcare-github-deploy \
  --query 'Role.AssumeRolePolicyDocument' --output json | jq .

# 2. Look at the workflow run's failed step — the JWT sub value is logged
# (configure-aws-credentials prints it on auth failures)
```

If the printed `sub` is e.g. `repo:chala2001/cloud-care:pull_request_target`,
your trust policy probably only allows `:pull_request` (without `_target`).
Mismatch → fix the policy or change the workflow trigger.

---

## 11. 💰 Cost & teardown

| Resource | Cost |
|----------|------|
| IAM OIDC provider + role | free |
| GitHub Actions | 2,000 free min/month on the free plan (Linux runners) |
| ECR storage of build images | within 500 MB free tier |
| CloudFront invalidations | first 1,000 paths/month free |

Teardown of the CI/CD stack itself is just:

```bash
terraform destroy   # in terraform/cicd/
```

After that, GitHub can no longer assume the role — workflows will fail until
you recreate it.

> ⚠️ **Don't delete the OIDC provider casually.** It's shared across the
> account. If you have other projects using GitHub OIDC, destroying this stack
> removes the provider and breaks them too. In that case, import the provider
> into this state and mark it `lifecycle { prevent_destroy = true }`.

---

## 12. Plain-English summary (what you just built)

If asked to explain Phase 8 part 1:

1. **GitHub OIDC** registered as an IdP in AWS. One per account.
2. **One IAM role** (`cloudcare-github-deploy`) with a **scoped trust policy**
   that only accepts JWTs whose `sub` matches `repo:owner/name:ref:refs/heads/main`
   or `repo:owner/name:pull_request`. Forks, other repos, other refs → rejected.
3. **AdministratorAccess** attached to the role **for the lab** — production
   would split per-workflow with least-privilege.
4. **One GitHub repo variable** `AWS_DEPLOY_ROLE_ARN` (not a secret — the ARN
   alone isn't usable).
5. **Three workflows**:
   - `terraform.yml` — `plan` on PR, `apply` on `main`, loops 8 stacks in
     dependency order.
   - `backend.yml` — build image with SHA + `latest` tags, push to ECR, start
     ASG instance refresh.
   - `frontend.yml` — `npm ci && npm run build`, `aws s3 sync --delete`,
     CloudFront invalidation.
6. **Path filters** keep each workflow focused on its directory.
7. **Branch protection** on `main` requires PR + passing checks.
8. End to end: every code change ships through a PR → plan → review → merge →
   apply → image build → ASG refresh → frontend invalidation. **Zero stored AWS
   keys, ever.**

---

## 13. Interview soundbites

- **Why OIDC** — *"We use GitHub OIDC federation: per-workflow-run JWT minted
  by GitHub, validated by AWS against the registered OIDC provider, scoped by
  a `sub`-claim condition to our specific repo and refs. No long-lived AWS
  keys in the repo, 1-hour credentials, auditable per run."*

- **The `sub` claim is the security knob** — *"The `sub` looks like
  `repo:owner/name:ref:refs/heads/main`. The trust policy pins this exactly,
  so forks, other repos, other branches, or PRs from forks all fail the assume.
  Don't use the `*` wildcard casually — it widens to attacker-controlled
  workflows."*

- **One role vs many roles** — *"For the lab the one role uses
  AdministratorAccess. In production it'd be one role per workflow, each
  scoped — frontend gets S3 + CloudFront only, backend gets ECR + autoscaling
  refresh only, Terraform gets the broad set. Same trust pattern, smaller
  blast radius per workflow."*

- **Why a shell loop over stacks instead of a matrix** — *"Network must apply
  before compute, which must apply before CDN — there's an explicit
  dependency order. GitHub Actions matrix doesn't guarantee execution order,
  so a hard-coded shell loop is the simplest correct option."*

- **The double-tag pattern** — *"Each image gets two tags: the commit SHA
  (immutable, for rollback / forensics) and `:latest` (what the launch
  template pulls). The deploy pushes both; rolling back is a re-tag of an old
  SHA as `:latest` plus an instance refresh."*

- **`$GITHUB_ENV` for cross-step values** — *"Each step runs in a fresh shell,
  so normal env vars don't persist. The `$GITHUB_ENV` file lets a step
  `echo VAR=value >> $GITHUB_ENV` and later steps see it as an env var. Same
  pattern for outputs via `$GITHUB_OUTPUT`."*

- **Path filters** — *"Each workflow's `paths:` filter restricts it to its
  own subtree. Edit only frontend code → only the frontend workflow runs.
  Less CI cost, faster feedback, and the Terraform workflow stays out of
  app-only PRs."*

- **Branch protection + plan-on-PR** — *"Direct push to `main` is blocked.
  Every change is a PR; the Terraform workflow runs `plan` on every PR; review
  + plan output gates the merge. After merge, the same workflow applies. The
  plan-then-apply two-phase is the heart of safe IaC delivery."*

---

## ✅ Checkpoint

You're ready for Doc 20 when:

- [ ] `terraform/cicd/` applied; `AWS_DEPLOY_ROLE_ARN` set in GitHub variables.
- [ ] A PR ran `terraform plan` successfully; merging applied it.
- [ ] A backend code change pushed to `main` triggered an image build + ASG
      rollout.
- [ ] A frontend change pushed to `main` triggered an S3 sync + CloudFront
      invalidation.
- [ ] You can read each workflow YAML and explain what every step does.

And you can explain, from memory:

- How OIDC federation replaces stored AWS keys.
- What the `sub` claim is and why we pin it to specific refs.
- Why the Terraform workflow loops stacks in order instead of using a matrix.
- What the SHA tag on the Docker image is for (rollback).
- The difference between GitHub variables and secrets.
- Why `npm ci` is preferred over `npm install` in CI.

Next: **[20 — Teardown & the Interview Story](20-teardown-and-interview-story.md)**
— the safe order to destroy every stack to return to ~$0, and a script for the
"tell me about a project" question that lands all the pillars above.
