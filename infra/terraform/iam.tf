data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ---- instance role -----------------------------------------------------------------------------------------------
# What the application instances may do in AWS, and nothing more:
#   1. register with Systems Manager (AmazonSSMManagedInstanceCore): how operators and the deploy workflow reach them,
#      with no inbound port;
#   2. pull images from THIS environment's ECR repositories (read-only), using the instance role: no access keys on the host;
#   3. read the specific database secret(s) named in db_secret_names (GetSecretValue), for the backend's AWS SDK;
#   4. read (never write) the deployment artifact prefix of THIS environment's bucket.
# It may NOT push images, read the RDS-managed master secret or any other secret, write to S3, or use EC2 or IAM.
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

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  description        = "ShopNest ${var.environment} instances: Systems Manager core, ECR pull and own database secret only"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR pull. GetAuthorizationToken cannot be scoped to a repository (AWS requires resource "*"); every other action is limited
# to this environment's repositories.
data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPullOwnRepositories"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }
}

resource "aws_iam_role_policy" "ecr_pull" {
  name   = "pull-own-environment-images"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.ecr_pull.json
}

# Runtime secret retrieval for the backend (AWS SDK). One resource entry per named secret. Secrets Manager appends a random
# six-character suffix to every secret ARN, so each ARN ends in six single-character wildcards (the documented way to
# refer to a secret by name before its suffix is known). This matches that one secret name only: it is NOT a prefix wildcard, and
# a different secret (even 'db-app-x') does not match. The role cannot read the RDS-managed master secret.
data "aws_iam_policy_document" "app_secrets" {
  statement {
    sid       = "ReadNamedDatabaseSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for n in var.db_secret_names : "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/${var.environment}/${n}-??????"]
  }

  # Only needed when those secrets use a customer-managed key; the default Secrets Manager key needs no grant here.
  dynamic "statement" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]
    content {
      sid       = "DecryptDatabaseSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "app_secrets" {
  name   = "read-named-database-secrets"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.app_secrets.json
}

# Read-only access to the deployment artifact prefix (scripts and configuration), nothing else in the bucket. The instance cannot
# write, delete or list outside the prefix. When the bucket uses a customer-managed key the role may decrypt with it, through S3 only.
data "aws_iam_policy_document" "artifacts_read" {
  statement {
    sid    = "ReadArtifactPrefix"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/${var.artifact_prefix}*"]
  }

  statement {
    sid       = "ListArtifactPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.artifact_prefix}*"]
    }
  }

  dynamic "statement" {
    for_each = var.artifacts_kms_key_arn == null ? [] : [var.artifacts_kms_key_arn]
    content {
      sid       = "DecryptArtifacts"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${var.aws_region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "artifacts_read" {
  name   = "read-deployment-artifacts"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.artifacts_read.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# NOT created here, on purpose:
#  - the GitHub OIDC provider and the deploy role (ecr:PutImage and friends for CI; ssm:SendCommand on these instances and
#    one document for the deploy workflow). The trust policy needs the repository's real OIDC `sub` claim, which has not been
#    captured (docs/OIDC_DESIGN.md, open item 2a). It is a separate, approved change; the minimum permissions are in README.
#  - the artifact PUBLISHER permission (PutObject on the artifact prefix): it belongs to the CI/deploy identity, which does not exist yet.
#  - the database secrets (shopnest/<environment>/<name>): created out-of-band so their values never enter Terraform state.
