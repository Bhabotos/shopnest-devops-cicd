# Private RDS PostgreSQL. The database lives in the database subnets (no route to the internet), has no public address, is
# encrypted at rest, takes automated backups, and accepts port 5432 from the backend security group only.
#
# CREDENTIALS: Terraform never sees a database password. With manage_master_user_password the RDS service generates the
# master password, stores it in AWS Secrets Manager and can rotate it. State keeps only the secret's ARN, not its value.
# The application's own roles (shopnest_owner, shopnest_app) are created by a bootstrap step after the database exists; their
# secrets (shopnest/<environment>/...) are created out-of-band and are not part of this configuration. See README and
# INTEGRATION_GAPS.md.

locals {
  # Production always has deletion protection; staging only if asked.
  rds_deletion_protection = var.rds_deletion_protection == null ? var.environment == "production" : var.rds_deletion_protection

  # The name RDS gives the snapshot it takes when the database is deleted. It must be unique, so the suffix is a variable. (TF-06)
  final_snapshot_identifier = "${local.name}-final-${var.rds_final_snapshot_suffix}"

  # Production is always Multi-AZ; staging only if asked. (RDS-03)
  rds_multi_az = var.rds_multi_az == null ? var.environment == "production" : var.rds_multi_az

  # postgres16 for engine_version "16" or "16.4"
  rds_parameter_family = "postgres${split(".", var.rds_engine_version)[0]}"
}

resource "aws_db_subnet_group" "main" {
  name        = "${local.name}-db"
  description = "Private database subnets for ${local.name}"
  subnet_ids  = [for s in aws_subnet.db : s.id]

  tags = { Name = "${local.name}-db-subnets" }
}

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name}-pg-"
  family      = local.rds_parameter_family
  description = "ShopNest PostgreSQL parameters"

  # TLS is mandatory for every client connection (application, migrations and operators).
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  tags = { Name = "${local.name}-pg-params" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier = "${local.name}-pg"

  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage_gb
  max_allocated_storage = var.rds_max_allocated_storage_gb
  storage_type          = var.rds_storage_type
  storage_encrypted     = true # not configurable: unencrypted storage is not allowed
  kms_key_id            = var.rds_storage_kms_key_id

  db_name  = var.db_name
  username = var.db_master_username
  port     = 5432

  # The master password is generated and held by RDS in Secrets Manager. No password argument exists in this file.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.rds_master_secret_kms_key_id

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false # never: the instance gets no public address
  multi_az               = local.rds_multi_az

  backup_retention_period  = var.rds_backup_retention_days
  backup_window            = var.rds_backup_window
  maintenance_window       = var.rds_maintenance_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = var.environment == "production" ? false : true
  deletion_protection      = local.rds_deletion_protection
  skip_final_snapshot      = var.rds_skip_final_snapshot
  # A snapshot name can be used only once; bump rds_final_snapshot_suffix before deleting and recreating a database. (TF-06)
  final_snapshot_identifier = var.rds_skip_final_snapshot ? null : local.final_snapshot_identifier

  auto_minor_version_upgrade          = true
  allow_major_version_upgrade         = false
  apply_immediately                   = var.rds_apply_immediately
  iam_database_authentication_enabled = false
  performance_insights_enabled        = false

  tags = { Name = "${local.name}-pg" }

  lifecycle {
    # Minor versions move with automatic minor upgrades, and storage autoscaling moves the allocated size. Do not fight either:
    # a plan that tries to shrink autoscaled storage fails, because RDS cannot shrink storage. (TF-02)
    ignore_changes = [engine_version, allocated_storage]

    # The complete final snapshot name must satisfy the RDS rules: at most 255 characters, letters, digits and hyphens only, starting with a
    # letter, no trailing hyphen and no two hyphens in a row. The suffix variable checks its own part; this checks the whole name (it also
    # catches an unusual project name). Checked at plan time, because a bad name would otherwise fail only when the database is deleted.
    precondition {
      condition = var.rds_skip_final_snapshot || (
        length(local.final_snapshot_identifier) <= 255 &&
        can(regex("^[A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)*$", local.final_snapshot_identifier))
      )
      error_message = "The final snapshot identifier '${local.final_snapshot_identifier}' is not valid for RDS: it must be at most 255 characters, contain only letters, digits and single hyphens, start with a letter, and not end with a hyphen."
    }
    precondition {
      condition     = var.environment != "production" || local.rds_multi_az
      error_message = "Production RDS must be Multi-AZ."
    }
    precondition {
      condition     = var.environment != "production" || local.rds_deletion_protection
      error_message = "Production RDS must have deletion protection enabled."
    }
    precondition {
      condition     = var.environment != "production" || var.rds_backup_retention_days >= 7
      error_message = "Production RDS must keep automated backups for at least 7 days."
    }
    precondition {
      condition     = var.environment != "production" || !var.rds_skip_final_snapshot
      error_message = "Production RDS must take a final snapshot when deleted."
    }
  }
}
