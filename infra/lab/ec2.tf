# Ubuntu Server 24.04 LTS from Canonical. The newest matching image is looked up at plan time; the instance ignores later image
# changes (see lifecycle) so a new AMI never replaces the running host.
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

# Runs, for BOTH environments, nginx, the backend (blue/green) containers and a PostgreSQL container, as separate Compose projects.
# The database has no published port, and the security group would not admit it anyway. No SSH key pair exists.
resource "aws_instance" "lab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = local.use_existing_profile ? data.aws_iam_instance_profile.existing[0].name : aws_iam_instance_profile.instance[0].name

  # A public IPv4 address is how the instance reaches Systems Manager, GitHub and GHCR without a NAT Gateway.
  associate_public_ip_address = true
  monitoring                  = false # basic (5-minute) metrics only; detailed monitoring costs extra

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    swap_size_gb = var.swap_size_gb
  })

  # The boot script needs outbound internet at once, and the Systems Manager agent needs its permissions.
  depends_on = [
    aws_route_table_association.public,
    aws_iam_role_policy_attachment.ssm_core,
    aws_vpc_security_group_egress_rule.https,
    aws_vpc_security_group_egress_rule.http_out,
  ]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # 1: no container needs the instance role (images and code are public), so a container cannot reach the metadata service.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true

    tags = { Name = "${local.name}-root" }
  }

  tags = { Name = "${local.name}-app" }

  lifecycle {
    # A new image or a changed boot script must not replace a running host (it would wipe both databases).
    ignore_changes = [ami, user_data]
  }
}

# A stable public address for the live URL. Costs the same as an auto-assigned address while the instance runs.
resource "aws_eip" "app" {
  count = var.use_elastic_ip ? 1 : 0

  domain = "vpc"

  tags = { Name = "${local.name}-eip" }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_eip_association" "app" {
  count = var.use_elastic_ip ? 1 : 0

  instance_id   = aws_instance.lab.id
  allocation_id = aws_eip.app[0].id
}
