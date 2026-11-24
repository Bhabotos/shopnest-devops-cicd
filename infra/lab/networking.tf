resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }

  depends_on = [terraform_data.not_root]
}

# Nothing may use the default security group: it is emptied so it allows no traffic at all.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.lab.id

  tags = { Name = "${local.name}-default-unused" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = { Name = "${local.name}-igw" }
}

# ONE public subnet. map_public_ip_on_launch stays off: the instance asks for its public address explicitly (see ec2.tf).
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  availability_zone       = local.az
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1) # the second /24 of the VPC range
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${local.az}", Tier = "public" }
}

# No NAT Gateway: the instance reaches the internet (Systems Manager, GitHub, GHCR, package mirrors) directly through the
# Internet Gateway with its own public address. Inbound traffic is controlled by the security group alone.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
