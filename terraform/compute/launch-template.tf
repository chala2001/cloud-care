# terraform/compute/launch-template.tf

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # Attach the APP security group from Phase 1 (only :8000 from the ALB).
  vpc_security_group_ids = [
    data.terraform_remote_state.network.outputs.app_security_group_id
  ]

  # Force IMDSv2 (token-based metadata) — blocks a common SSRF credential-theft
  # path. A cheap, expected security hardening.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Boot script: install Docker, pull our image from ECR, and run the container
  # with DB credentials pulled from Secrets Manager at runtime.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    REGION="${var.aws_region}"
    ACCOUNT="${data.aws_caller_identity.current.account_id}"
    REPO="$${ACCOUNT}.dkr.ecr.$${REGION}.amazonaws.com/${var.project}-backend"

    # The AWS CLI and Python ship with Amazon Linux 2023. Add Docker + jq.
    dnf install -y docker jq
    systemctl enable --now docker

    # Authenticate Docker to ECR and pull our image.
    aws ecr get-login-password --region "$REGION" \
      | docker login --username AWS --password-stdin "$${ACCOUNT}.dkr.ecr.$${REGION}.amazonaws.com"
    docker pull "$${REPO}:latest"

    # Read DB credentials from Secrets Manager (allowed by the instance role).
    CREDS=$(aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id "${var.project}/db/credentials" --query SecretString --output text)

    # Run the container, injecting the DB connection as environment variables.
    docker run -d --restart always -p 8000:8000 \
      -e DB_HOST="$(echo "$CREDS" | jq -r .host)" \
      -e DB_PORT="$(echo "$CREDS" | jq -r .port)" \
      -e DB_NAME="$(echo "$CREDS" | jq -r .dbname)" \
      -e DB_USER="$(echo "$CREDS" | jq -r .username)" \
      -e DB_PASSWORD="$(echo "$CREDS" | jq -r .password)" \
      "$${REPO}:latest"
  EOF
  )


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project}-app"
    }
  }
}