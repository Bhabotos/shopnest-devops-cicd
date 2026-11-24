# One group for the one instance.
#   inbound   TCP 80 from anywhere (the live application: the production environment's nginx). NOTHING else: no SSH (22), no HTTPS,
#             no 5432. Staging's nginx listens on the loopback address only and is reached through Session Manager.
#   outbound  HTTPS (Systems Manager, GitHub, GHCR) and HTTP (the Ubuntu package mirrors). DNS needs no rule: the VPC resolver is
#             not filtered by security groups.
# Administration and deployment use AWS Systems Manager, which needs only these outbound connections.
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Lab instance: HTTP 80 in, no SSH, outbound 80 and 443"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "${local.name}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.app.id
  description       = "Public HTTP for the live application"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to Systems Manager, GitHub and GHCR"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP to the Ubuntu package mirrors"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}
