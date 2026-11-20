# ---- the application instance -------------------------------------------------------------------------------------

# Ubuntu Server 24.04 LTS from Canonical. The newest matching image is looked up at plan time; the instance ignores
# later image changes (see lifecycle) so a new AMI never replaces the running host.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Runs nginx and the backend (blue/green) containers. It holds NO database: PostgreSQL is the private RDS instance.
# Capacity is environment-aware (see local.app_instances): staging has ONE instance; production has TWO, placed in different
# Availability Zones and both registered in the ALB target group. Each instance is private (no public address) and is
# administered only through Systems Manager.
resource "aws_instance" "app" {
  for_each = local.app_instances # key: "1", "2", ... ; value: the Availability Zone

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.app[each.value].id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  associate_public_ip_address = false # private: reachable only through the load balancer and Systems Manager
  monitoring                  = false # basic (5-minute) metrics only; detailed monitoring costs extra

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {})

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # 2 so the backend CONTAINER can reach the metadata service and the AWS SDK can use the instance role; see variables.tf.
    http_put_response_hop_limit = var.imds_hop_limit
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = true

    tags = { Name = "${local.name}-root-${each.key}" }
  }

  tags = { Name = "${local.name}-app-${each.key}" }

  lifecycle {
    # A new image or a changed boot script must not replace a running host.
    ignore_changes = [ami, user_data]

    precondition {
      condition     = var.environment != "production" || local.app_instance_count >= 2
      error_message = "Production needs at least two application instances."
    }
    precondition {
      condition     = var.environment != "production" || length(toset(values(local.app_instances))) >= 2
      error_message = "Production instances must be spread across at least two Availability Zones."
    }
  }
}

# ---- application load balancer --------------------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = var.enable_deletion_protection

  tags = { Name = "${local.name}-alb" }

  lifecycle {
    precondition {
      condition     = length(var.alb_allowed_cidrs) > 0
      error_message = "alb_allowed_cidrs must list at least one source CIDR (there is no default)."
    }
    precondition {
      condition     = var.environment == "production" || !contains(var.alb_allowed_cidrs, "0.0.0.0/0")
      error_message = "Staging must not be open to the whole internet; list specific CIDRs in alb_allowed_cidrs."
    }
  }
}

# The ALB reaches each instance's nginx on app_port, inside the VPC. The security groups allow exactly this path:
# ALB group -> app group on app_port, and nothing else inbound.
resource "aws_lb_target_group" "app" {
  name     = "${local.name}-app"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  deregistration_delay = 30

  # nginx answers /health by asking the live backend (see deploy/nginx/nginx.conf), so a dead backend shows up here as an
  # unhealthy target while the static frontend would still answer.
  health_check {
    enabled             = true
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name}-app-tg" }
}

# Every application instance is a target. With two targets in two AZs the ALB keeps serving when one of them fails its health check.
resource "aws_lb_target_group_attachment" "app" {
  for_each = aws_instance.app

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = each.value.id
  port             = var.app_port
}

# Without a certificate (no domain exists yet) the site is served over plain HTTP. See README "Risks".
resource "aws_lb_listener" "http_forward" {
  count = local.use_https ? 0 : 1

  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = local.use_https ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.use_https ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
