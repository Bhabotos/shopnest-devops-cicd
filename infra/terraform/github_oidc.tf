# GitHub Actions deploy identity (OIDC). No access keys exist anywhere: the workflow exchanges its short-lived OIDC token for
# this role's temporary credentials. Everything here is created only when enable_cicd is true.
#
# What this role CAN do (and nothing else):
#   - push the backend image to THIS environment's ECR repository;
#   - upload the release bundle under THIS environment's prefix of the artifact bucket (it cannot read, list or delete);
#   - start the migrator CodeBuild project and read its result;
#   - send exactly two SSM command documents to exactly the application instance(s), and read their output.
# What it can NOT do: read any secret (db-app, db-owner or the RDS master secret), start the bootstrap project, touch RDS, EC2,
# IAM or any other resource, or run an arbitrary command on the instance (the documents have fixed commands and validated parameters).

locals {
  cicd = var.enable_cicd

  github_oidc_provider_arn = var.create_github_oidc_provider ? one(aws_iam_openid_connect_provider.github[*].arn) : var.github_oidc_provider_arn

  # Where the workflow may put a release bundle: deploy/<environment>/<sha>/bundle.tar.gz
  bundle_prefix = "${var.artifact_prefix}${var.environment}/"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.cicd && var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = { Name = "${var.project}-github-oidc" }
}

# Trust: only a token from GitHub, for the STS audience, whose subject is EXACTLY one of the approved ones. StringEquals, never a
# wildcard, so a different repository, branch or environment cannot assume the role.
data "aws_iam_policy_document" "github_trust" {
  count = local.cicd ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_oidc_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  count = local.cicd ? 1 : 0

  name                 = "${local.name}-github-deploy"
  description          = "GitHub Actions deploy role for ${var.environment}: push image, upload bundle, start the migrator, send two fixed SSM documents. No secret access."
  assume_role_policy   = data.aws_iam_policy_document.github_trust[0].json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = var.github_repository != "" && length(var.github_oidc_subjects) > 0
      error_message = "enable_cicd needs github_repository and at least one github_oidc_subjects value (the real OIDC claim, captured from a workflow run)."
    }
    precondition {
      condition     = var.create_github_oidc_provider != (var.github_oidc_provider_arn != "")
      error_message = "Set exactly one of create_github_oidc_provider = true or github_oidc_provider_arn (an account can hold only one GitHub OIDC provider)."
    }
    precondition {
      condition     = contains(var.ecr_repository_names, "backend")
      error_message = "The deploy role pushes the 'backend' repository: ecr_repository_names must contain it."
    }
  }
}

data "aws_iam_policy_document" "github_deploy" {
  count = local.cicd ? 1 : 0

  # ECR login cannot be scoped to a repository (AWS requires resource "*"); every other ECR action is limited to the one repository.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushBackendImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.app["backend"].arn]
  }

  # Upload only, and only under this environment's prefix: the role cannot read, list or delete bundles.
  statement {
    sid       = "UploadReleaseBundle"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/${local.bundle_prefix}*"]
  }

  dynamic "statement" {
    for_each = var.artifacts_kms_key_arn == null ? [] : [var.artifacts_kms_key_arn]
    content {
      sid       = "EncryptReleaseBundle"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey", "kms:Encrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${var.aws_region}.amazonaws.com"]
      }
    }
  }

  statement {
    sid       = "StartTheMigrator"
    effect    = "Allow"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.migrator[0].arn]
  }

  # Exactly two documents, to exactly the application instance(s).
  statement {
    sid     = "SendTheTwoFixedDocuments"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = concat(
      [aws_ssm_document.deploy[0].arn, aws_ssm_document.rollback[0].arn],
      [for i in aws_instance.app : i.arn],
    )
  }

  # Reading the result of a command has no resource-level scope in IAM; these are read-only.
  statement {
    sid    = "ReadCommandResults"
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadMigratorLogs"
    effect    = "Allow"
    actions   = ["logs:GetLogEvents"]
    resources = ["${aws_cloudwatch_log_group.migrator[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.cicd ? 1 : 0

  name   = "deploy-${var.environment}"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy[0].json
}
