locals {
  use_https = var.acm_certificate_arn != ""
}

# One group per tier. Rules are separate resources so each can be reviewed on its own.
# No rule anywhere opens port 22, and none opens port 5432 to a CIDR: administration and deployment use
# AWS Systems Manager (outbound only), and the database accepts connections from the application group alone.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public entry point: web traffic to the load balancer only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb-sg" }
}

# The backend / application tier: the instance running nginx and the backend containers.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Backend instance: web traffic from the load balancer only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app-sg" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS PostgreSQL: port 5432 from the backend group only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-db-sg" }
}

# ---- ALB: inbound ------------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_web" {
  for_each = toset(var.alb_allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = local.use_https ? "HTTPS from allowed sources" : "HTTP from allowed sources"
  ip_protocol       = "tcp"
  from_port         = local.use_https ? 443 : 80
  to_port           = local.use_https ? 443 : 80
  cidr_ipv4         = each.value
}

# With a certificate, plain HTTP is only accepted to be redirected to HTTPS.
resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  for_each = local.use_https ? toset(var.alb_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTP, redirected to HTTPS"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

# ---- ALB: outbound (only to the backend group) -------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Traffic and health checks to the backend instance"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# ---- backend instance: inbound (only from the ALB) --------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "nginx from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

# ---- backend instance: outbound -----------------------------------------------------------------------
# HTTPS reaches Systems Manager, Secrets Manager, package and image registries; HTTP is for apt mirrors.
# DNS to the VPC resolver and the Amazon Time Sync address are link-local and are not filtered by security groups.

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS out (Systems Manager, Secrets Manager, registries, packages)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_http_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP out (apt mirrors)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to RDS"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

# ---- database tier ---------------------------------------------------------------------------------------
# The database group has NO outbound rules: RDS does not need to initiate connections to anything in the VPC.

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the backend group only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}
