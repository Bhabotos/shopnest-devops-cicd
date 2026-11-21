# The ONLY two things the GitHub deploy role can make the application instance do, as AWS Systems Manager command documents.
# Created only when enable_cicd is true. There is no SSH and no generic "run this command" document: the commands below are fixed,
# and every parameter is validated by a strict pattern before it is substituted, so a caller cannot inject a command.
#
#   deploy    fetch the release bundle from S3, VERIFY ITS SHA-256 BEFORE EXTRACTING ANYTHING, extract it, and run the blue/green
#             deploy with the image identified by its ECR DIGEST. Exit codes of bluegreen-deploy.sh pass through: 0 deployed;
#             1 failed with the previous release still serving; 3 failed AND the automatic rollback failed (needs an operator).
#   rollback  fetch and verify a "carrier" bundle (any release's scripts), then roll back to an earlier release. It never runs
#             migrations: the schema is never reversed automatically.
#
# The instance role does the S3 read and the ECR pull (read-only). The host needs /home/deploy/shopnest/<environment>/runtime.env,
# written once by the operator (non-secret settings only).

locals {
  # Parameter patterns. The image reference must be a DIGEST of THIS environment's repository in THIS region.
  sha_pattern        = "^[0-9a-f]{40}$"
  sha256_pattern     = "^[0-9a-f]{64}$"
  bundle_key_pattern = "^${replace(local.bundle_prefix, ".", "\\.")}[0-9a-f]{40}/bundle\\.tar\\.gz$"
  image_ref_pattern  = "^[0-9]{12}\\.dkr\\.ecr\\.${replace(var.aws_region, ".", "\\.")}\\.amazonaws\\.com/${replace(var.project, ".", "\\.")}/${var.environment}/backend@sha256:[0-9a-f]{64}$"

  # Shared by both documents: fetch, verify the hash, then (and only then) extract. $1 is the target directory.
  fetch_and_verify = <<-EOT
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    aws s3 cp "s3://${aws_s3_bucket.artifacts.bucket}/$BUNDLE_KEY" "$TMP/bundle.tar.gz" --region ${var.aws_region} --only-show-errors
    echo "$BUNDLE_SHA256  $TMP/bundle.tar.gz" | sha256sum --check --strict
    rm -rf "$WORK"
    mkdir -p "$WORK"
    tar -xzf "$TMP/bundle.tar.gz" -C "$WORK" --no-same-owner
  EOT

  # Both scripts below start with a bash shebang: Systems Manager runs a run-command script with the default shell (sh) unless told
  # otherwise, and `set -o pipefail` is not guaranteed there. They also put /snap/bin on the PATH, because the AWS CLI is installed
  # with snap (see user_data.sh.tftpl) and a service started by systemd does not get that directory from /etc/environment.
  # deploy/tests/ssm-scripts.test.sh extracts them and runs ShellCheck on exactly this text.
  deploy_script = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"
    umask 077
    export SHOPNEST_HOME=/home/deploy/shopnest
    SHA='{{ Sha }}'
    IMAGE_REF='{{ ImageRef }}'
    BUNDLE_KEY='{{ BundleKey }}'
    BUNDLE_SHA256='{{ BundleSha256 }}'
    WORK="$SHOPNEST_HOME/incoming/$SHA"
    ${local.fetch_and_verify}
    rc=0
    bash "$WORK/deploy/scripts/bluegreen-deploy.sh" --env ${var.environment} --sha "$SHA" --image-ref "$IMAGE_REF" --bundle-key "$BUNDLE_KEY" --bundle-sha256 "$BUNDLE_SHA256" || rc=$?
    exit "$rc"
  EOT

  rollback_script = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"
    umask 077
    export SHOPNEST_HOME=/home/deploy/shopnest
    TARGET_SHA='{{ TargetSha }}'
    CARRIER_SHA='{{ CarrierSha }}'
    BUNDLE_KEY='{{ CarrierBundleKey }}'
    BUNDLE_SHA256='{{ CarrierBundleSha256 }}'
    WORK="$SHOPNEST_HOME/incoming/$CARRIER_SHA"
    ${local.fetch_and_verify}
    rc=0
    bash "$WORK/deploy/scripts/rollback.sh" --env ${var.environment} --sha "$TARGET_SHA" || rc=$?
    exit "$rc"
  EOT
}

resource "aws_ssm_document" "deploy" {
  count = local.cicd ? 1 : 0

  name            = "${local.name}-deploy"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy one release to the ${var.environment} application instance: verified bundle, image by ECR digest, blue/green with automatic rollback."
    parameters = {
      Sha = {
        type           = "String"
        description    = "The 40-character commit SHA of the release."
        allowedPattern = local.sha_pattern
      }
      ImageRef = {
        type           = "String"
        description    = "The backend image, by ECR digest, from this environment's repository."
        allowedPattern = local.image_ref_pattern
      }
      BundleKey = {
        type           = "String"
        description    = "S3 key of the release bundle."
        allowedPattern = local.bundle_key_pattern
      }
      BundleSha256 = {
        type           = "String"
        description    = "SHA-256 of the bundle, computed by the workflow; verified before anything is extracted."
        allowedPattern = local.sha256_pattern
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "Deploy"
      inputs = {
        timeoutSeconds = "1200"
        runCommand     = compact(split("\n", local.deploy_script))
      }
    }]
  })

  tags = { Name = "${local.name}-deploy" }
}

resource "aws_ssm_document" "rollback" {
  count = local.cicd ? 1 : 0

  name            = "${local.name}-rollback"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Roll the ${var.environment} application instance back to an earlier release. Never runs migrations; the schema is never reversed automatically."
    parameters = {
      TargetSha = {
        type           = "String"
        description    = "The earlier release to roll back to (must be recorded as deployed on the instance)."
        allowedPattern = local.sha_pattern
      }
      CarrierSha = {
        type           = "String"
        description    = "Identifier of the carrier bundle (40 hex digits). The workflow derives it from the bundle's own SHA-256, so a carrier can never overwrite a release bundle."
        allowedPattern = local.sha_pattern
      }
      CarrierBundleKey = {
        type           = "String"
        description    = "S3 key of the carrier bundle."
        allowedPattern = local.bundle_key_pattern
      }
      CarrierBundleSha256 = {
        type           = "String"
        description    = "SHA-256 of the carrier bundle; verified before anything is extracted."
        allowedPattern = local.sha256_pattern
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "Rollback"
      inputs = {
        timeoutSeconds = "1200"
        runCommand     = compact(split("\n", local.rollback_script))
      }
    }]
  })

  tags = { Name = "${local.name}-rollback" }
}
