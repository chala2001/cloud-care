# terraform/observability/data.tf

data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "compute/terraform.tfstate"
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "database/terraform.tfstate"
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "audit" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "serverless/audit/terraform.tfstate"
    region = "ap-south-1"
  }
}

data "terraform_remote_state" "contact" {
  backend = "s3"
  config = {
    bucket = "cloudcare-tfstate-670794226080"
    key    = "serverless/contact/terraform.tfstate"
    region = "ap-south-1"
  }
}