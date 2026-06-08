# terraform/cicd/oidc.tf

# Register GitHub as a trusted OIDC IdP for this AWS account. (You only need
# ONE of these per account, even if you have many repos.)
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
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