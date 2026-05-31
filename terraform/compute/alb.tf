# terraform/compute/alb.tf

# 1) The load balancer — internet-facing, in the PUBLIC subnets, using alb-sg.
resource "aws_lb" "app" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [
    data.terraform_remote_state.network.outputs.alb_security_group_id
  ]
  subnets = data.terraform_remote_state.network.outputs.public_subnet_ids

  tags = { Name = "${var.project}-alb" }
}

# 2) The target group — the instances answer on :8000. The health check hits "/"
#    and expects HTTP 200 (our placeholder returns exactly that).
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health" # the real app's cheap health endpoint
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.project}-app-tg" }
}

# 3) The listener — accept HTTP on :80 and forward to the target group.
#    (HTTPS/:443 needs an ACM certificate; we add that with CloudFront in Phase 5.)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# 4) Connect the ASG to the target group. New instances auto-register; terminated
#    ones auto-deregister. This is the glue between Doc 09 and this doc.
resource "aws_autoscaling_attachment" "app" {
  autoscaling_group_name = aws_autoscaling_group.app.id
  lb_target_group_arn    = aws_lb_target_group.app.arn
}