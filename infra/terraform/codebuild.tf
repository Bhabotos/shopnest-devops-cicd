# CodeBuild jobs that run in the PRIVATE application subnets, next to RDS, and hold the credentials the application host must never see.
# Created only when enable_cicd is true.
#
#   migrator   applies the schema migrations for a release BEFORE it is deployed. Reads db-owner and nothing else. Started by the
#              GitHub deploy role (the workflow), with the exact release image (by digest) as the image override. A failed
#              migration fails the build and the workflow does not deploy. Never reversed automatically.
#   bootstrap  creates the two application roles once. Reads the RDS master secret plus db-app and db-owner. Started ONLY by the
#              operator role (MFA); the GitHub deploy role and the instance role have no permission on it.
#
# Both reach RDS (5432, TLS verified in the application code), ECR, Secrets Manager and CloudWatch Logs through the same NAT
# Gateway(s) the application instances use. scripts/check-connectivity.js proves each path at run time, before any database work.
# One build at a time per project (concurrent_build_limit), and the migrator also takes a PostgreSQL advisory lock.

locals {
  db_owner_secret_id = "${var.project}/${var.environment}/${var.db_owner_secret_name}"
  db_app_secret_id   = "${var.project}/${var.environment}/db-app"

  # The names, so the roles can be written before the projects exist (the projects reference the roles).
  migrator_project_name  = "${local.name}-migrate"
  bootstrap_project_name = "${local.name}-bootstrap"
}

# ---- logs --------------------------------------------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "migrator" {
  count = local.cicd ? 1 : 0

  name              = "/shopnest/${var.environment}/migrator"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-migrator-logs" }
}

resource "aws_cloudwatch_log_group" "bootstrap" {
  count = local.cicd ? 1 : 0

  name              = "/shopnest/${var.environment}/bootstrap"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-bootstrap-logs" }
}

# ---- network: one security group per job; the database accepts each of them on 5432 and nothing else new ---------------------

resource "aws_security_group" "migrator" {
  count = local.cicd ? 1 : 0

  name        = "${local.name}-migrator"
  description = "CodeBuild migrator: PostgreSQL to RDS and HTTPS out only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-migrator-sg" }
}

resource "aws_security_group" "bootstrap" {
  count = local.cicd ? 1 : 0

  name        = "${local.name}-bootstrap"
  description = "CodeBuild bootstrap: PostgreSQL to RDS and HTTPS out only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-bootstrap-sg" }
}

resource "aws_vpc_security_group_egress_rule" "migrator_to_db" {
  count = local.cicd ? 1 : 0

  security_group_id            = aws_security_group.migrator[0].id
  description                  = "PostgreSQL to RDS"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "migrator_https_out" {
  count = local.cicd ? 1 : 0

  security_group_id = aws_security_group.migrator[0].id
  description       = "HTTPS out through the NAT Gateway (ECR, Secrets Manager, CloudWatch Logs)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "bootstrap_to_db" {
  count = local.cicd ? 1 : 0

  security_group_id            = aws_security_group.bootstrap[0].id
  description                  = "PostgreSQL to RDS"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "bootstrap_https_out" {
  count = local.cicd ? 1 : 0

  security_group_id = aws_security_group.bootstrap[0].id
  description       = "HTTPS out through the NAT Gateway (ECR, Secrets Manager, CloudWatch Logs)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_migrator" {
  count = local.cicd ? 1 : 0

  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the CodeBuild migrator"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.migrator[0].id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_bootstrap" {
  count = local.cicd ? 1 : 0

  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the CodeBuild bootstrap"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.bootstrap[0].id
}

# ---- roles ---------------------------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "codebuild_trust" {
  count = local.cicd ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "migrator" {
  count = local.cicd ? 1 : 0

  name               = "${local.name}-migrator"
  description        = "CodeBuild migrator for ${var.environment}: reads the owner secret only; pulls the backend image; logs"
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust[0].json
}

resource "aws_iam_role" "bootstrap" {
  count = local.cicd ? 1 : 0

  name               = "${local.name}-bootstrap"
  description        = "CodeBuild bootstrap for ${var.environment}: reads the master, owner and app secrets; operator-started only"
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust[0].json
}

# What both jobs need to run in the VPC at all (CodeBuild creates a network interface in the private subnets).
data "aws_iam_policy_document" "codebuild_vpc" {
  count = local.cicd ? 1 : 0

  # These Describe/Create/Delete actions have no resource-level scope in IAM (AWS documents "*" for them).
  statement {
    sid    = "NetworkInterfacesForCodeBuild"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  # Allowing CodeBuild to attach its interface is limited to the application subnets and to the CodeBuild service.
  statement {
    sid       = "AttachInterfaceInApplicationSubnetsOnly"
    effect    = "Allow"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values   = [for s in aws_subnet.app : s.arn]
    }
  }
}

# Pull the release image (the image override) with the project's own role.
data "aws_iam_policy_document" "codebuild_ecr_pull" {
  count = local.cicd ? 1 : 0

  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullBackendImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.app["backend"].arn]
  }
}

data "aws_iam_policy_document" "migrator" {
  count = local.cicd ? 1 : 0

  # The ONE secret the migrator may read. Secrets Manager appends a random six-character suffix to every ARN, hence the six
  # single-character wildcards: this matches that one secret name only, not a prefix.
  statement {
    sid       = "ReadOwnerSecretOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.db_owner_secret_id}-??????"]
  }

  dynamic "statement" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]
    content {
      sid       = "DecryptOwnerSecret"
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

  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.migrator[0].arn}:*"]
  }
}

data "aws_iam_policy_document" "bootstrap" {
  count = local.cicd ? 1 : 0

  # The bootstrap reads three secrets: the two it installs as role passwords, and the RDS master secret it connects with.
  statement {
    sid     = "ReadTheThreeBootstrapSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.db_owner_secret_id}-??????",
      "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.db_app_secret_id}-??????",
      one(aws_db_instance.main.master_user_secret[*].secret_arn),
    ]
  }

  dynamic "statement" {
    for_each = compact([var.secrets_kms_key_arn, var.rds_master_secret_kms_key_id])
    content {
      sid       = "DecryptBootstrapSecrets${statement.key}"
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

  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.bootstrap[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "migrator" {
  count = local.cicd ? 1 : 0

  name   = "migrator"
  role   = aws_iam_role.migrator[0].id
  policy = data.aws_iam_policy_document.migrator[0].json
}

resource "aws_iam_role_policy" "migrator_vpc" {
  count = local.cicd ? 1 : 0

  name   = "run-in-the-vpc"
  role   = aws_iam_role.migrator[0].id
  policy = data.aws_iam_policy_document.codebuild_vpc[0].json
}

resource "aws_iam_role_policy" "migrator_ecr_pull" {
  count = local.cicd ? 1 : 0

  name   = "pull-backend-image"
  role   = aws_iam_role.migrator[0].id
  policy = data.aws_iam_policy_document.codebuild_ecr_pull[0].json
}

resource "aws_iam_role_policy" "bootstrap" {
  count = local.cicd ? 1 : 0

  name   = "bootstrap"
  role   = aws_iam_role.bootstrap[0].id
  policy = data.aws_iam_policy_document.bootstrap[0].json
}

resource "aws_iam_role_policy" "bootstrap_vpc" {
  count = local.cicd ? 1 : 0

  name   = "run-in-the-vpc"
  role   = aws_iam_role.bootstrap[0].id
  policy = data.aws_iam_policy_document.codebuild_vpc[0].json
}

resource "aws_iam_role_policy" "bootstrap_ecr_pull" {
  count = local.cicd ? 1 : 0

  name   = "pull-backend-image"
  role   = aws_iam_role.bootstrap[0].id
  policy = data.aws_iam_policy_document.codebuild_ecr_pull[0].json
}

# ---- projects ------------------------------------------------------------------------------------------------------------------
# The project's own image is only a placeholder: every build is started with the RELEASE image (by digest) as the override, and the
# buildspec refuses to run in any other image. Environment values below are not secrets: the database address and secret NAMES.

resource "aws_codebuild_project" "migrator" {
  count = local.cicd ? 1 : 0

  name                   = local.migrator_project_name
  description            = "Applies the schema migrations for a release, as the owner role, before it is deployed (${var.environment})"
  service_role           = aws_iam_role.migrator[0].arn
  build_timeout          = var.codebuild_timeout_minutes
  concurrent_build_limit = 1

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = var.codebuild_compute_type
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = false

    environment_variable {
      name  = "DB_HOST"
      value = aws_db_instance.main.address
    }
    environment_variable {
      name  = "DB_PORT"
      value = "5432"
    }
    environment_variable {
      name  = "DB_NAME"
      value = var.db_name
    }
    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "DB_OWNER_SECRET_ID"
      value = local.db_owner_secret_id
    }
    environment_variable {
      name  = "DB_SSL_CA_FILE"
      value = "/app/certs/rds-global-bundle.pem"
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/../../deploy/codebuild/migrate.buildspec.yml")
  }

  vpc_config {
    vpc_id             = aws_vpc.main.id
    subnets            = [for s in aws_subnet.app : s.id]
    security_group_ids = [aws_security_group.migrator[0].id]
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.migrator[0].name
    }
  }

  depends_on = [
    aws_iam_role_policy.migrator,
    aws_iam_role_policy.migrator_vpc,
    aws_iam_role_policy.migrator_ecr_pull,
    aws_vpc_security_group_ingress_rule.db_from_migrator,
    aws_nat_gateway.main,
  ]

  tags = { Name = local.migrator_project_name }
}

resource "aws_codebuild_project" "bootstrap" {
  count = local.cicd ? 1 : 0

  name                   = local.bootstrap_project_name
  description            = "ONE-TIME creation of the application roles (${var.environment}); started only by the operator role"
  service_role           = aws_iam_role.bootstrap[0].arn
  build_timeout          = var.codebuild_timeout_minutes
  concurrent_build_limit = 1

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = var.codebuild_compute_type
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = false

    environment_variable {
      name  = "DB_HOST"
      value = aws_db_instance.main.address
    }
    environment_variable {
      name  = "DB_PORT"
      value = "5432"
    }
    environment_variable {
      name  = "DB_NAME"
      value = var.db_name
    }
    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "DB_SECRET_ID"
      value = local.db_app_secret_id
    }
    environment_variable {
      name  = "DB_OWNER_SECRET_ID"
      value = local.db_owner_secret_id
    }
    # The ARN of the RDS-managed master secret (a name, not the password).
    environment_variable {
      name  = "DB_MASTER_SECRET_ID"
      value = one(aws_db_instance.main.master_user_secret[*].secret_arn)
    }
    environment_variable {
      name  = "DB_SSL_CA_FILE"
      value = "/app/certs/rds-global-bundle.pem"
    }
    environment_variable {
      name  = "BOOTSTRAP_ENVIRONMENT"
      value = var.environment
    }
    # BOOTSTRAP_CONFIRM is deliberately NOT set here: the operator must supply it when starting the build.
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/../../deploy/codebuild/bootstrap.buildspec.yml")
  }

  vpc_config {
    vpc_id             = aws_vpc.main.id
    subnets            = [for s in aws_subnet.app : s.id]
    security_group_ids = [aws_security_group.bootstrap[0].id]
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.bootstrap[0].name
    }
  }

  depends_on = [
    aws_iam_role_policy.bootstrap,
    aws_iam_role_policy.bootstrap_vpc,
    aws_iam_role_policy.bootstrap_ecr_pull,
    aws_vpc_security_group_ingress_rule.db_from_bootstrap,
    aws_nat_gateway.main,
  ]

  tags = { Name = local.bootstrap_project_name }
}

# ---- the operator role (D11): the only way to start the bootstrap ----------------------------------------------------------------
# A person assumes this role WITH MFA. It can start and inspect the bootstrap project and read its logs, nothing else. The GitHub
# deploy role has no permission on the bootstrap project, and neither has the instance role. (Another administrator of the account
# could of course still start it: IAM cannot stop an administrator.)

data "aws_iam_policy_document" "operator_trust" {
  count = local.cicd ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.operator_principal_arns
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "bootstrap_operator" {
  count = local.cicd ? 1 : 0

  name                 = "${local.name}-bootstrap-operator"
  description          = "People only, with MFA: start and inspect the ${var.environment} bootstrap project, read its logs"
  assume_role_policy   = data.aws_iam_policy_document.operator_trust[0].json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = length(var.operator_principal_arns) > 0
      error_message = "enable_cicd needs at least one operator_principal_arns entry (the person or role allowed to start the bootstrap, with MFA)."
    }
  }
}

data "aws_iam_policy_document" "operator" {
  count = local.cicd ? 1 : 0

  statement {
    sid       = "StartAndInspectTheBootstrap"
    effect    = "Allow"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.bootstrap[0].arn]
  }

  statement {
    sid       = "ReadTheBootstrapLogs"
    effect    = "Allow"
    actions   = ["logs:GetLogEvents", "logs:DescribeLogStreams"]
    resources = [aws_cloudwatch_log_group.bootstrap[0].arn, "${aws_cloudwatch_log_group.bootstrap[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "bootstrap_operator" {
  count = local.cicd ? 1 : 0

  name   = "start-the-bootstrap"
  role   = aws_iam_role.bootstrap_operator[0].id
  policy = data.aws_iam_policy_document.operator[0].json
}
