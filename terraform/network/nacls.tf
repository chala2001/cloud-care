# terraform/network/nacls.tf
# -------------------------------------------------------------------------
# NACLs are STATELESS, subnet-level guardrails. Unlike security groups, you
# must explicitly allow RETURN traffic (the ephemeral 1024-65535 ports).
# We keep these coarse and let the security groups above do the precise work.
# -------------------------------------------------------------------------

# PUBLIC NACL — attached to the public subnets (the ALB tier).
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id

  # ---- inbound ----
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidr_block = "0.0.0.0/0"
  }
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidr_block = "0.0.0.0/0"
  }
  ingress {
    # Return traffic for connections this tier OPENED outbound (e.g. responses
    # from the app instances, and replies coming back to web clients).
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # ---- outbound ----
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }

  tags = { Name = "${var.project}-public-nacl" }
}

# PRIVATE NACL — attached to BOTH app and db subnets. Only accept traffic that
# originates INSIDE the VPC; allow all outbound (replies + intra-VPC calls).
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = concat(aws_subnet.app[*].id, aws_subnet.db[*].id)

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = var.vpc_cidr # 10.0.0.0/16 — only traffic from within the VPC
  }
  ingress {
    # Return traffic for connections the private instances OPEN outbound through
    # the NAT instance (e.g. pulling the image from ECR, dnf, Secrets Manager).
    # NACLs are stateless, so these replies arrive from public IPs on ephemeral
    # ports and must be explicitly allowed or every outbound connection stalls.
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }

  tags = { Name = "${var.project}-private-nacl" }
}