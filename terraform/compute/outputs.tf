# terraform/compute/outputs.tf

output "asg_name" {
  description = "Name of the app Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "ID of the app launch template"
  value       = aws_launch_template.app.id
}

# --- append to terraform/compute/outputs.tf ---

output "alb_dns_name" {
  description = "Public DNS name of the load balancer — open/curl this"
  value       = aws_lb.app.dns_name
}

output "alb_zone_id" {
  description = "Hosted-zone ID of the ALB (for Route 53 / CloudFront later)"
  value       = aws_lb.app.zone_id
}

output "target_group_arn" {
  description = "ARN of the app target group"
  value       = aws_lb_target_group.app.arn
}