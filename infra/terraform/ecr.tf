# Amazon ECR: where CI pushes the versioned application image and where the instances pull it from.
#
# Deployment flow this supports (the workflows are NOT changed here):
#   1. CI builds the Docker image.
#   2. CI pushes it to this repository under an immutable version tag (the commit SHA).
#   3. The deploy workflow identifies the exact tag, and ideally the image digest.
#   4. SSM Run Command starts the deployment on each instance.
#   5. The instance authenticates to ECR with its IAM instance role and pulls the image (no access keys on the host).
#   6. The application's health checks validate the release.
#
# One repository set PER ENVIRONMENT, named <project>/<environment>/<name>, so each stack is self-contained and can be torn
# down without touching the other. Promoting an image from staging to production means copying that manifest to the production
# repository (the digest is preserved when the manifest is copied, not rebuilt). See README.

locals {
  ecr_repository_names = toset(var.ecr_repository_names)
}

resource "aws_ecr_repository" "app" {
  for_each = local.ecr_repository_names

  name = "${var.project}/${var.environment}/${each.key}"

  # A pushed tag can never be overwritten: a release tag always means the same image. Rollback targets stay trustworthy.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.ecr_kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.ecr_kms_key_arn
  }

  # Destroying the stack must not silently delete released images: a repository that still holds images cannot be deleted.
  force_delete = false

  tags = { Name = "${local.name}-${each.key}-images" }
}

# Cleanup: untagged images expire after a few days; only the newest ecr_keep_images images are kept (rollback needs the old ones).
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.ecr_untagged_expire_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest ${var.ecr_keep_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
