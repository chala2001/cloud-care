# terraform/compute/variables.tf

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix in Name tags"
  type        = string
  default     = "cloudcare"
}

variable "instance_type" {
  description = "EC2 instance type (t3.micro is free-tier eligible)"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimum number of app instances"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of app instances (scale to 2 only to demo)"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Normal number of app instances to keep running"
  type        = number
  default     = 1 # one instance = stays inside the 750 free t2.micro hours
}

# add to terraform/compute/variables.tf

variable "enable_nat_instance" {
  description = "Run a NAT instance so private app instances have internet egress"
  type        = bool
  default     = true
}