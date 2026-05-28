# terraform/network/routing.tf

# PUBLIC route table: send all non-local traffic to the Internet Gateway.
# This single 0.0.0.0/0 route is what MAKES the public subnets public.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project}-public-rt"
  }
}

# Tie BOTH public subnets to the public route table.
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# PRIVATE route table: NO 0.0.0.0/0 route. AWS auto-adds an implicit "local"
# route for 10.0.0.0/16, so these subnets can talk WITHIN the VPC but cannot
# reach — or be reached from — the internet. That is the whole point.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-private-rt"
  }
}

# Tie all FOUR private subnets (app + db) to the private route table.
resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  count          = length(aws_subnet.db)
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.private.id
}