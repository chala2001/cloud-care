# terraform/network/outputs.tf

output "vpc_id" {
  description = "ID of the CloudCare VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (ALB tier)"
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "IDs of the private application subnets (EC2 tier)"
  value       = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  description = "IDs of the private database subnets (RDS tier)"
  value       = aws_subnet.db[*].id
}

# --- append to terraform/network/outputs.tf ---

output "alb_security_group_id" {
  description = "Security group for the load balancer (used by the compute phase)"
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group for the EC2/app tier"
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "Security group for the RDS tier"
  value       = aws_security_group.db.id
}
