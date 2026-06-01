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