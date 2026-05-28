# terraform/network/providers.tf

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Store THIS folder's state in the S3 bucket we created in Doc 06.
  # `key` is the path inside the bucket — unique per component (state isolation).
  backend "s3" {
    bucket         = "cloudcare-tfstate-670794226080"
    key            = "network/terraform.tfstate"
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
      Component = "network"
    }
  }
}