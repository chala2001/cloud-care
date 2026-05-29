# terraform/compute/outputs.tf

output "asg_name" {
  description = "Name of the app Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "ID of the app launch template"
  value       = aws_launch_template.app.id
}