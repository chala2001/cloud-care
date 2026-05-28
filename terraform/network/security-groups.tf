# terraform/network/security-groups.tf
# -------------------------------------------------------------------------
# The three-tier chain:  internet --(80/443)--> ALB --(8000)--> App --(5432)--> DB
# Each tier only accepts traffic from the tier directly in front of it.
# -------------------------------------------------------------------------

# 1) ALB SG — the public edge. Anyone on the internet may reach 80/443.
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Public edge: allow HTTP/HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (so the ALB can reach the app instances)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 = all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb-sg" }
}

# 2) App SG — the FastAPI tier. Accept 8000 ONLY from the ALB SG (not the
#    internet). Note `security_groups`, not `cidr_blocks` — that's the chain.
resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "App tier: allow 8000 only from the ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "FastAPI port, from the ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (to reach the DB, and later to pull updates)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-app-sg" }
}

# 3) DB SG — PostgreSQL. Accept 5432 ONLY from the App SG. The database is
#    unreachable from anywhere else — including other things inside the VPC.
resource "aws_security_group" "db" {
  name        = "${var.project}-db-sg"
  description = "DB tier: allow 5432 only from the app security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL, from the app tier only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-db-sg" }
}