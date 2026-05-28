# terraform/network/variables.tf

variable "aws_region" {
  description = "AWS region for all networking resources"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix in resource Name tags"
  type        = string
  default     = "cloudcare"
}

variable "vpc_cidr" {
  description = "CIDR block for the whole VPC (65,536 addresses)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the public subnets — one per AZ (ALB tier)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "app_subnet_cidrs" {
  description = "CIDRs for the private application subnets — one per AZ (EC2 tier)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDRs for the private database subnets — one per AZ (RDS tier)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}