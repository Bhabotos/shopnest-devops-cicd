# What the instance may do in AWS: register with Systems Manager (AmazonSSMManagedInstanceCore), and nothing else. It has no ECR,
# S3, Secrets Manager or EC2 permission: images come from GHCR (public) and code from the public GitHub repository, so the host
# needs no AWS credential for either. This role is NEW and is not shared with infra/terraform.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  # Reuse a pre-provisioned instance profile when one is named; otherwise create the lab's own role and profile (the default).
  use_existing_profile = var.existing_instance_profile != ""
}

# READ ONLY lookup of the pre-provisioned profile (needs iam:GetInstanceProfile). Terraform never creates, changes, attaches to or
# deletes the existing role or profile.
data "aws_iam_instance_profile" "existing" {
  count = local.use_existing_profile ? 1 : 0

  name = var.existing_instance_profile
}

resource "aws_iam_role" "instance" {
  count = local.use_existing_profile ? 0 : 1

  name               = "${local.name}-instance"
  description        = "ShopNest lab instance: Systems Manager core only"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count = local.use_existing_profile ? 0 : 1

  role       = aws_iam_role.instance[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  count = local.use_existing_profile ? 0 : 1

  name = "${local.name}-instance"
  role = aws_iam_role.instance[0].name
}
