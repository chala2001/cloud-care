# terraform/compute/nat.tf

# Security group: accept anything from inside the VPC (so private subnets can
# route through it), allow all outbound to the internet.
resource "aws_security_group" "nat" {
  count       = var.enable_nat_instance ? 1 : 0
  name        = "${var.project}-nat-sg"
  description = "NAT instance: forward traffic from the VPC to the internet"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description = "All traffic from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.terraform_remote_state.network.outputs.vpc_cidr]
  }

  egress {
    description = "All outbound to the internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-nat-sg" }
}

# The NAT instance itself — a t3.micro in a PUBLIC subnet with a public IP.
# (t3.micro is the free-tier-eligible type in ap-south-1; t2.micro is not.)
resource "aws_instance" "nat" {
  count                       = var.enable_nat_instance ? 1 : 0
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = data.terraform_remote_state.network.outputs.public_subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.nat[0].id]

  # CRITICAL for a NAT: the instance must forward packets NOT addressed to itself.
  source_dest_check = false

  # Recreate the instance whenever this script changes (user_data only runs on
  # first boot, so an in-place update would never take effect otherwise).
  user_data_replace_on_change = true

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail
    # AL2023 does NOT ship the iptables CLI — install it FIRST, before using it.
    dnf install -y iptables iptables-services
    # Turn the box into a router:
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nat.conf
    # iptables-services ships a default ruleset whose FORWARD chain REJECTs traffic.
    # Clear it and default FORWARD to ACCEPT so the VPC can route THROUGH this box.
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD
    # Masquerade outbound traffic on the primary network interface:
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    # Persist the iptables rules across reboots:
    service iptables save
    systemctl enable iptables
  EOF
  )

  tags = { Name = "${var.project}-nat" }
}

# Send the PRIVATE route table's default route through the NAT instance.
# We look up the private route table (created in Phase 1) by its Name tag, so we
# don't have to modify the network stack. It has no other 0.0.0.0/0 route, so
# there's no conflict.
data "aws_route_table" "private" {
  filter {
    name   = "tag:Name"
    values = ["${var.project}-private-rt"]
  }
  vpc_id = data.terraform_remote_state.network.outputs.vpc_id
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_instance ? 1 : 0
  route_table_id         = data.aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[0].primary_network_interface_id
}