# terraform/compute/data.tf

# Read the Phase 1 network stack's outputs (subnets, security groups, VPC id).
# This is how stacks share data without redefining resources.
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "network/terraform.tfstate"
    region = "ap-south-1"
  }
}

# Always boot the LATEST Amazon Linux 2023 image, rather than hardcoding an AMI
# ID (AMI IDs differ per region and change as AWS patches them).
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}