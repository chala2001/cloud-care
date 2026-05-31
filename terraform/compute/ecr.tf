# terraform/compute/ecr.tf

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true # free vulnerability scan on every push
  }

  force_delete = true # learning: allow `terraform destroy` even if images exist
}

output "ecr_repository_url" {
  description = "Push the backend image here"
  value       = aws_ecr_repository.backend.repository_url
}