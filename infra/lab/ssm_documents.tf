# OPTIONAL FALLBACK, NOT USED BY THE WORKFLOWS. The deploy now goes over SSH through an SSM port-forwarding tunnel (deploy/ci/ssh-deploy.sh),
# and no deploy role can send a command, so nothing can run these documents. They are kept as the earlier, SSM-Run-Command way of
# deploying (four fixed Systems Manager command documents, one deploy and one rollback per environment) and are created ONLY when
# BOTH enable_cicd and create_ssm_documents are true (create_ssm_documents defaults to false, which also means the applying identity
# does not need ssm:CreateDocument). To use them again, a role would have to be given ssm:SendCommand on them and the workflows changed.
# There is no generic "run this command" document: the commands are fixed (deploy.sh.tftpl, rollback.sh.tftpl), the environment is baked
# into each document, and every parameter is validated by a strict pattern before it is substituted, so a caller cannot inject a command.

locals {
  cicd = var.enable_cicd

  # The fallback documents exist only when CI/CD is enabled AND they were asked for.
  ssm_documents = var.enable_cicd && var.create_ssm_documents

  repository_owner = var.github_repository == "" ? "" : lower(split("/", var.github_repository)[0])

  # Parameter patterns. An image must be a DIGEST of THIS repository owner's ShopNest image on GHCR, never a tag.
  sha_pattern            = "^[0-9a-f]{40}$"
  seed_pattern           = "^(true|false)$"
  backend_image_pattern  = "^ghcr\\.io/${local.repository_owner}/shopnest-backend@sha256:[0-9a-f]{64}$"
  frontend_image_pattern = "^ghcr\\.io/${local.repository_owner}/shopnest-frontend@sha256:[0-9a-f]{64}$"

  deploy_scripts = {
    for env in local.environments : env => templatefile("${path.module}/deploy.sh.tftpl", {
      environment = env
      repository  = var.github_repository
    })
  }
  rollback_scripts = {
    for env in local.environments : env => templatefile("${path.module}/rollback.sh.tftpl", {
      environment = env
      repository  = var.github_repository
    })
  }
}

resource "aws_ssm_document" "deploy" {
  for_each = local.ssm_documents ? toset(local.environments) : toset([])

  name            = "${local.name}-deploy-${each.key}"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy one release to the ${each.key} environment: the exact commit is fetched from the public repository, the images are pulled from GHCR by digest, then blue/green with automatic rollback."
    parameters = {
      Sha = {
        type           = "String"
        description    = "The 40-character commit SHA of the release."
        allowedPattern = local.sha_pattern
      }
      ImageRef = {
        type           = "String"
        description    = "The backend image, by GHCR digest."
        allowedPattern = local.backend_image_pattern
      }
      FrontendRef = {
        type           = "String"
        description    = "The frontend image (static files), by GHCR digest."
        allowedPattern = local.frontend_image_pattern
      }
      Seed = {
        type           = "String"
        description    = "true loads the idempotent demo catalogue (staging only in practice: the production seed needs an explicit operator choice)."
        allowedPattern = local.seed_pattern
        default        = "false"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "Deploy"
      inputs = {
        timeoutSeconds = "1200"
        runCommand     = compact(split("\n", local.deploy_scripts[each.key]))
      }
    }]
  })

  tags = { Name = "${local.name}-deploy-${each.key}" }

  lifecycle {
    precondition {
      condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$", var.github_repository))
      error_message = "enable_cicd needs github_repository as owner/name (the owner part may contain only letters, digits and hyphens)."
    }
  }
}

resource "aws_ssm_document" "rollback" {
  for_each = local.ssm_documents ? toset(local.environments) : toset([])

  name            = "${local.name}-rollback-${each.key}"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Roll the ${each.key} environment back to an earlier release that was deployed on this host. Never runs migrations; the schema is never reversed automatically."
    parameters = {
      TargetSha = {
        type           = "String"
        description    = "The commit SHA of the earlier release (it must appear as deployed in the release history on the host)."
        allowedPattern = local.sha_pattern
      }
      CarrierSha = {
        type           = "String"
        description    = "The commit whose rollback tooling is used (the current main)."
        allowedPattern = local.sha_pattern
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "Rollback"
      inputs = {
        timeoutSeconds = "1200"
        runCommand     = compact(split("\n", local.rollback_scripts[each.key]))
      }
    }]
  })

  tags = { Name = "${local.name}-rollback-${each.key}" }

  lifecycle {
    precondition {
      condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$", var.github_repository))
      error_message = "enable_cicd needs github_repository as owner/name (the owner part may contain only letters, digits and hyphens)."
    }
  }
}
