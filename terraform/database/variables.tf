# terraform/database/variables.tf

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as a prefix"
  type        = string
  default     = "cloudcare"
}

variable "db_instance_class" {
  description = "RDS instance class (db.t3.micro is free-tier eligible)"
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "allocated_storage" {
  description = "Storage in GB (free tier covers 20 GB)"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the initial database"
  type        = string
  default     = "cloudcare"
}

variable "db_username" {
  description = "Master username (avoid reserved words like 'admin'/'postgres')"
  type        = string
  default     = "cloudcare_admin"
}

variable "backup_retention_days" {
  description = "Days of automated backups to keep (0 disables them)"
  type        = number
  default     = 1
}

variable "multi_az" {
  description = "Run a standby in a second AZ (DOUBLES cost — keep false to stay free)"
  type        = bool
  default     = false
}