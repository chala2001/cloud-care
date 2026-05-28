# terraform/network/vpc.tf

# Ask AWS which AZs are usable in this region, then take the first TWO.
# Using a data source (not hardcoding "ap-south-1a/b") makes the code portable.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# The VPC itself — our private, isolated network. Everything hangs off this.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # let resources resolve DNS names inside the VPC
  enable_dns_hostnames = true # give instances internal DNS hostnames (needed by RDS later)

  tags = {
    Name = "${var.project}-vpc"
  }
}

# The Internet Gateway — the VPC's single door to the public internet.
# Creating it does nothing on its own; a subnet only becomes "public" once a
# route table points 0.0.0.0/0 at this IGW (see routing.tf).
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-igw"
  }
}