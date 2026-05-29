# terraform/compute/asg.tf

resource "aws_autoscaling_group" "app" {
  name             = "${var.project}-app-asg"
  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # Spread instances across BOTH private app subnets (one per AZ).
  vpc_zone_identifier = data.terraform_remote_state.network.outputs.app_subnet_ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # For now, use EC2 status checks for health. Doc 10 upgrades this to "ELB" so
  # the ALB's HTTP health check decides whether an instance is healthy.
  health_check_type         = "EC2"
  health_check_grace_period = 60

  # Tag every launched instance (propagate_at_launch) so they show your project.
  tag {
    key                 = "Name"
    value               = "${var.project}-app"
    propagate_at_launch = true
  }

  # Replace instances one at a time when the launch template changes.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }
}
