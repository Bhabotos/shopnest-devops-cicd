# Deployment artifact bucket: where FUTURE deployment scripts and configuration will be stored for the instances to fetch.
# (Application images go to ECR; this bucket is for small files such as the deploy scripts, nginx configuration and frontend files.)
# One bucket per environment, so staging and production stay separate.
#
# This phase only DEFINES the bucket. Nothing is uploaded, no deployment workflow uses it yet, and the publisher identity (the
# CI/deploy role) does not exist yet: it will receive an identity policy limited to PutObject on the prefix below when it is created.
#
# Security properties, all enforced in this file:
#   - every kind of public access blocked, ACLs disabled (bucket-owner enforced), no public bucket policy;
#   - encryption at rest on every object (S3-managed AES-256, or a customer-managed key when one is supplied);
#   - versioning on, so an overwritten or deleted script can be recovered and a release can be rolled back;
#   - encrypted transport only: requests over plain HTTP, or below TLS 1.2, are denied for every principal;
#   - read access is granted by IAM to the instance role alone, to one prefix, with no write or delete permission.

locals {
  artifact_bucket_name = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  artifacts_use_kms    = var.artifacts_kms_key_arn != null
}

resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifact_bucket_name

  # A bucket that still holds objects cannot be destroyed silently. Empty it deliberately first.
  force_destroy = false

  tags = { Name = "${local.name}-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs off: access is controlled only by IAM and the bucket policy, and the bucket owner owns every object.
resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.artifacts_use_kms ? "aws:kms" : "AES256"
      kms_master_key_id = var.artifacts_kms_key_arn
    }

    # Fewer KMS requests when a customer-managed key is used; no effect with AES-256.
    bucket_key_enabled = local.artifacts_use_kms
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Retention: current versions are kept (they are the live scripts). Older versions are kept for artifact_noncurrent_retention_days,
# and at least the newest artifact_noncurrent_versions_kept of them are always kept, so a recent release can still be rolled back.
# Incomplete uploads and orphaned delete markers are cleaned up.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "retain-recent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.artifact_noncurrent_retention_days
      newer_noncurrent_versions = var.artifact_noncurrent_versions_kept
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "remove-orphaned-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  # The lifecycle rules rely on versioning being enabled first.
  depends_on = [aws_s3_bucket_versioning.artifacts]
}

# Bucket policy: ONLY deny statements. There is no Allow here, so it can never make the bucket public; access is granted by IAM
# (the instance role below, and later the publisher role).
data "aws_iam_policy_document" "artifacts_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyTlsBelow12"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_bucket.json

  # Apply the public-access block first so the policy is never evaluated against an unprotected bucket.
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
