data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # One /24 per tier per AZ, carved from the VPC range with cidrsubnet:
  #   public       index 0, 1     (ALB, NAT Gateway)
  #   application  index 10, 11   (the EC2 instance)
  #   database     index 20, 21   (RDS)
  public_subnets = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, i) }
  app_subnets    = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, 10 + i) }
  db_subnets     = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, 20 + i) }

  # The first AZ always has a NAT Gateway. With nat_per_az every AZ has its own, and each AZ routes through its OWN gateway;
  # otherwise the one gateway serves all of them. Production defaults to one per AZ, staging to one in total.
  primary_az = local.azs[0]
  nat_per_az = var.nat_per_az == null ? var.environment == "production" : var.nat_per_az
  nat_azs    = local.nat_per_az ? local.azs : [local.primary_az]

  # Which AZ's NAT Gateway each AZ's application subnet uses. With nat_per_az every AZ maps to itself (no cross-AZ NAT routing).
  nat_az_for_az = { for az in local.azs : az => local.nat_per_az ? az : local.primary_az }

  # Application capacity: 1 instance for staging, 2 for production unless overridden. Placement is round-robin across the AZs.
  app_instance_count = var.app_instance_count != null ? var.app_instance_count : (var.environment == "production" ? 2 : 1)
  app_instances      = { for i in range(local.app_instance_count) : tostring(i + 1) => local.azs[i % length(local.azs)] }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }

  lifecycle {
    # Staging and production are separate states (workspaces). Applying one environment's variables to the
    # other's state would try to rebuild its network, so the workspace name must equal the environment.
    precondition {
      condition     = !endswith(data.aws_caller_identity.current.arn, ":root")
      error_message = "Refusing to run as the AWS root user. Use the short-lived 'devops' profile (never root credentials)."
    }
    precondition {
      condition     = terraform.workspace == var.environment
      error_message = "Select the matching Terraform workspace first: 'terraform workspace select ${var.environment}' (create it once with 'terraform workspace new ${var.environment}')."
    }
  }
}

# Nothing may use the default security group: it is emptied so it allows no traffic at all.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-default-unused" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-igw" }
}

# ---- subnets ---------------------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false # nothing launched here gets a public address on its own

  tags = { Name = "${local.name}-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "app" {
  for_each = local.app_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-app-${each.key}", Tier = "application" }
}

resource "aws_subnet" "db" {
  for_each = local.db_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-db-${each.key}", Tier = "database" }
}

# ---- NAT Gateway(s) (the selected way for private subnets to reach the internet; cost: see README) --------------------------
# One per entry in local.nat_azs.
#  - production (default): one gateway per AZ, and each AZ's application subnet routes through the gateway in its own AZ, so the
#    loss of one AZ does not remove outbound connectivity (Systems Manager, ECR, Secrets Manager) from the other. Cost: one more
#    gateway and Elastic IP (see README).
#  - staging (default): ONE gateway, a cost optimisation and a single point of failure for outbound connectivity. It is not
#    multi-AZ NAT, and it is not claimed to be.

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"

  tags = { Name = "${local.name}-nat-eip-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = { Name = "${local.name}-nat-${each.key}", Az = each.key }

  depends_on = [aws_internet_gateway.main]

  lifecycle {
    precondition {
      condition     = var.environment != "production" || local.nat_per_az
      error_message = "Production needs one NAT Gateway per Availability Zone (nat_per_az = true)."
    }
  }
}

# ---- route tables ------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Application subnets: outbound only, through a NAT Gateway. No inbound path from the internet.
# One route table per AZ: with nat_per_az each AZ uses the NAT Gateway in its own AZ; otherwise all use the single one.
resource "aws_route_table" "app" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[local.nat_az_for_az[each.key]].id
  }

  tags = { Name = "${local.name}-app-rt-${each.key}", NatAz = local.nat_az_for_az[each.key] }
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app[each.key].id
}

# Database subnets: local routes only. There is deliberately no route to the internet or to the NAT Gateway.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-db-rt" }
}

resource "aws_route_table_association" "db" {
  for_each = aws_subnet.db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}
