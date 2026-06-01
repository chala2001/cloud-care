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

Note your GitHub `<owner>/<repo>` (e.g., `chala2001/cloud-care`) — you'll use it
in §4.

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

> 🧠 **The `sub` condition is the security backbone.** Without it, *any* GitHub
> repo on the internet could theoretically assume your role. With it, only your
> repo + listed refs can. If you forked the repo to test, the fork's `sub`
> wouldn't match and the assume call would fail — exactly what you want.

> ⚠️ **Don't widen this to `"repo:owner/repo:*"`** without thinking. The `*`
> wildcard also matches workflows running on forks/PRs from forks (which can be
> opened by anyone). Restricting to specific refs is the safe default.

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

---

## 7. Configure the GitHub repo

In the GitHub UI, open your CloudCare repo and:

1. **Settings → Secrets and variables → Actions → Variables tab → New repository variable**:
   - Name: `AWS_DEPLOY_ROLE_ARN`
   - Value: (the ARN you just printed)

   > 🧠 **Variable, not secret.** This ARN isn't sensitive — anyone reading it
   > can't *use* it without GitHub minting a JWT for your repo. Storing it as a
   > variable means it's visible in logs (handy for debugging) and there's no
   > masking churn.

2. **Settings → Branches → Add branch protection rule** for `main`:
   - Require a pull request before merging.
   - Require status checks to pass (we'll add the Terraform plan check next).

---

## 8. The three workflows

Create the folder `.github/workflows/` in the repo root and the three files
below.

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

> 🧠 **One loop, dependency-ordered.** Network must apply before compute, which
> must apply before CDN, etc. The list encodes that. GitHub Actions' matrix
> *can't* guarantee order, so we use a plain shell loop.

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

> 🧠 **Why tag with `${GITHUB_SHA}` AND `latest`.** `latest` is what the launch
> template pulls (so the rollout is one-command). The SHA tag is the
> *immutable* version — useful when you need to roll back: pull the SHA tag from
> the previous deploy and run an instance refresh.

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

> 💡 **Path filters (`paths:` keys)** keep each workflow focused: the backend
> job doesn't run when you tweak the frontend, and vice versa. Faster CI, less
> noise.

---

## 9. Test the pipeline

1. **Test the PR plan path.** Create a branch, change one Terraform file
   (e.g., add a tag), open a PR. The `Terraform` workflow runs `plan` for every
   stack. The PR should NOT apply anything.

2. **Test the apply path.** Merge the PR to `main`. The `Terraform` workflow
   re-runs and **applies** each stack in order.

3. **Test backend rollout.** Change a string in `app/backend/app/main.py`
   (e.g., the `/health` response). Push to main. The `Backend image` workflow
   builds, pushes, and starts an instance refresh. Watch the ASG roll, then
   `curl https://<cloudfront>/health` to see the new response.

4. **Test frontend deploy.** Change a heading in `app/frontend/src/App.jsx`,
   push to main. The `Frontend deploy` workflow builds, syncs, and invalidates.
   Reload your CloudFront URL — the new UI appears.

---

## 10. Common failures & fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` doesn't match | Re-check `${var.github_owner}/${var.github_repo}` and that the run is on `main` or a PR |
| `AccessDenied` on an AWS API call | Role lacks the permission | Add it; for the lab, AdministratorAccess covers everything |
| `Terraform plan` shows huge unrelated changes | Local state drift vs S3 backend | Don't `apply` locally and via CI on the same stack; pick one. CI wins in production |
| `docker push` is denied | ECR login step missing or wrong region | Ensure `aws-actions/amazon-ecr-login@v2` runs after `configure-aws-credentials` |
| Workflow doesn't trigger on edit | `paths:` filter excludes your change | Adjust the filter or add the file's directory |

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

---

## ✅ Checkpoint

You're ready for Doc 20 when:

- [ ] `terraform/cicd/` applied; `AWS_DEPLOY_ROLE_ARN` set in GitHub variables.
- [ ] A PR ran `terraform plan` successfully; merging applied it.
- [ ] A backend code change pushed to `main` triggered an image build + ASG
      rollout.
- [ ] A frontend change pushed to `main` triggered an S3 sync + CloudFront
      invalidation.

And you can explain, from memory:

- How OIDC federation replaces stored AWS keys.
- What the `sub` claim is and why we pin it to specific refs.
- Why the Terraform workflow loops stacks in order instead of using a matrix.
- What the SHA tag on the Docker image is for (rollback).

Next: **[20 — Teardown & the Interview Story](20-teardown-and-interview-story.md)**
— the safe order to destroy every stack to return to ~$0, and a script for the
"tell me about a project" question that lands all the pillars above.
