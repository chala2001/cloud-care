# terraform/network/subnets.tf

# PUBLIC subnets (one per AZ) — hold internet-facing things (the ALB).
# map_public_ip_on_launch = true → anything launched here gets a public IP.
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

# PRIVATE application subnets (one per AZ) — the EC2/FastAPI tier. No public IPs.
resource "aws_subnet" "app" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = var.app_subnet_cidrs[count.index]

  tags = {
    Name = "${var.project}-app-${local.azs[count.index]}"
    Tier = "app"
  }
}

# PRIVATE database subnets (one per AZ) — RDS lives here. The most isolated tier.
resource "aws_subnet" "db" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = var.db_subnet_cidrs[count.index]

  tags = {
    Name = "${var.project}-db-${local.azs[count.index]}"
    Tier = "db"
  }
}