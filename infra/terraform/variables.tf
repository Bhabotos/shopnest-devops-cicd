# One stack per application environment. Staging and production are separate deployments of this same
# configuration, each with its own VPC, instance, load balancer and RDS database, its own Terraform
# workspace and its own variable file (see staging.tfvars.example and production.tfvars.example).

variable "project" {
  description = "Project name, used in resource names and tags."
  type        = string
  default     = "shopnest"
}

variable "environment" {
  description = "Application environment this stack serves. Must match the selected Terraform workspace (checked)."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "aws_region" {
  description = "AWS region. Fixed to Mumbai for this project."
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = var.aws_region == "ap-south-1"
    error_message = "This project is deployed only in ap-south-1."
  }
}

variable "allowed_account_ids" {
  description = "AWS account ID(s) this configuration may be applied to. Required, no default, and never in a tracked file: put it in your own untracked variable file. The provider refuses any other account, which protects against a wrong profile or the wrong credentials (TF-03)."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) >= 1 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must list at least one 12-digit AWS account ID."
  }
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Never root credentials, never access keys in code."
  type        = string
  default     = "devops"
}

# ---- network -------------------------------------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR of this stack's dedicated VPC (a /16 or larger; the /24 subnets are carved from it). No default on purpose: give staging and production different, non-overlapping ranges in their own variable files."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix of /16 or larger."
  }
}

variable "az_count" {
  description = "Number of Availability Zones for subnets (2 or 3). The ALB and the RDS subnet group need at least 2. The application instance runs in the first one only."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "nat_per_az" {
  description = "One NAT Gateway per Availability Zone, with each AZ's private subnet routing through the gateway in its own AZ (no cross-AZ NAT routing). null means: true for production, false for staging. With false there is ONE gateway, in the first AZ, serving every private subnet: a cost optimisation that is also a SINGLE POINT OF FAILURE for outbound connectivity (Systems Manager, ECR pulls, Secrets Manager, packages). Production cannot use false (checked)."
  type        = bool
  default     = null
}

# ---- application instance + load balancer ------------------------------------------------------------------------------

variable "app_instance_count" {
  description = "Number of application instances. null means: 1 for staging, 2 for production. Instances are spread round-robin across the Availability Zones and all are registered in the ALB target group. Production requires at least 2, in at least 2 different AZs (checked)."
  type        = number
  default     = null

  validation {
    condition     = var.app_instance_count == null || (var.app_instance_count >= 1 && var.app_instance_count <= 4)
    error_message = "app_instance_count must be null or between 1 and 4."
  }
}

variable "instance_type" {
  description = "EC2 type for each application instance (nginx + backend blue/green containers; no database)."
  type        = string
  default     = "t3.small"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like t3.small."
  }
}

variable "imds_hop_limit" {
  description = "IMDSv2 hop limit. The backend runs in a container and reads its database secret with the AWS SDK using the instance role, so the container must reach the instance metadata service: that needs 2. With 1 (the safer setting) the SDK in a container cannot obtain credentials. At 2, any process in a container on the host can obtain the instance role's credentials; the role is kept minimal for that reason (see README)."
  type        = number
  default     = 2

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 2
    error_message = "imds_hop_limit must be 1 or 2."
  }
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (OS, Docker images, release bundles)."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_size_gb >= 20 && var.root_volume_size_gb <= 200
    error_message = "root_volume_size_gb must be between 20 and 200."
  }
}

variable "kms_key_id" {
  description = "Optional customer-managed KMS key for the EBS volume. null uses the AWS-managed aws/ebs key (still encrypted)."
  type        = string
  default     = null
}

variable "app_port" {
  description = "Host port of this environment's nginx on the instance (matches deploy/env/<environment>.env: 80 for production, 8081 for staging). The ALB forwards to it."
  type        = number
  default     = 80

  validation {
    condition     = var.app_port >= 1 && var.app_port <= 65535 && !contains([22, 5432], var.app_port)
    error_message = "app_port must be between 1 and 65535 and must not be 22 or 5432."
  }
}

variable "alb_allowed_cidrs" {
  description = "Source CIDRs allowed to reach the load balancer. Required, no default, and never in a tracked file: put it in your own untracked variable file. Production states its audience explicitly; staging must list specific addresses (open-to-the-world is refused for staging). IPv4 only."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.alb_allowed_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c))])
    error_message = "Every alb_allowed_cidrs entry must be an IPv4 CIDR such as a /32 or /24 range (IPv6 and empty values are rejected)."
  }
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in ap-south-1. When empty the ALB serves plain HTTP (no domain exists yet); when set, HTTPS is served and HTTP redirects to it. HTTPS is not production-ready without a real domain and certificate."
  type        = string
  default     = ""
}

variable "enable_deletion_protection" {
  description = "ALB deletion protection. null means: on for production, off for staging so assignment infrastructure can be torn down. To decommission production, set this to false first."
  type        = bool
  default     = null
}

# ---- RDS PostgreSQL ------------------------------------------------------------------------------------------------------

variable "db_name" {
  description = "Name of the application database created in the RDS instance."
  type        = string
  default     = "shopnest"
}

variable "db_master_username" {
  description = "RDS master user name (not a secret). Its password is generated and stored by RDS in AWS Secrets Manager; it never appears in Terraform code or state."
  type        = string
  default     = "shopnest_admin"
}

variable "rds_engine_version" {
  description = "PostgreSQL version. Major 16 matches the version the application is built and tested against (PostgreSQL 16 in CI and in the local stacks). A major number lets RDS choose its current default minor version; the minor drifts with automatic minor upgrades and is ignored by Terraform. Confirm available minors with 'aws rds describe-db-engine-versions' before the first apply."
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?$", var.rds_engine_version))
    error_message = "rds_engine_version must look like 16 or 16.4."
  }
}

variable "rds_instance_class" {
  description = "DB instance class. Burstable Graviton classes are the cheapest fit for this workload."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_storage_type" {
  description = "Storage type: gp3 (default) or gp2. io1 is not offered because no provisioned-IOPS setting exists in this configuration."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp3", "gp2"], var.rds_storage_type)
    error_message = "rds_storage_type must be gp3 or gp2."
  }
}

variable "rds_allocated_storage_gb" {
  description = "Allocated storage in GiB (RDS PostgreSQL minimum is 20)."
  type        = number
  default     = 20

  validation {
    condition     = var.rds_allocated_storage_gb >= 20
    error_message = "rds_allocated_storage_gb must be at least 20."
  }
}

variable "rds_max_allocated_storage_gb" {
  description = "Upper limit for storage autoscaling in GiB; null turns autoscaling off. Must be greater than rds_allocated_storage_gb. Terraform ignores later changes to the allocated size (autoscaling moves it)."
  type        = number
  default     = null

  validation {
    condition     = var.rds_max_allocated_storage_gb == null || var.rds_max_allocated_storage_gb > var.rds_allocated_storage_gb
    error_message = "rds_max_allocated_storage_gb must be greater than rds_allocated_storage_gb (or null to disable autoscaling)."
  }
}

variable "rds_storage_kms_key_id" {
  description = "Optional customer-managed KMS key for RDS storage. null uses the AWS-managed aws/rds key. Storage encryption itself cannot be turned off."
  type        = string
  default     = null
}

variable "rds_multi_az" {
  description = "Run a synchronous standby in a second Availability Zone with automatic failover. null means: on for production, off for staging. Production cannot turn it off (checked). Roughly doubles instance and storage cost; see README."
  type        = bool
  default     = null
}

variable "rds_backup_retention_days" {
  description = "Days to keep automated backups (1 to 35). Zero (backups off) is not allowed. Production requires at least 7."
  type        = number
  default     = 7

  validation {
    condition     = var.rds_backup_retention_days >= 1 && var.rds_backup_retention_days <= 35
    error_message = "rds_backup_retention_days must be between 1 and 35."
  }
}

variable "rds_backup_window" {
  description = "Daily backup window, UTC (default is 02:30 to 03:30 IST)."
  type        = string
  default     = "21:00-22:00"
}

variable "rds_maintenance_window" {
  description = "Weekly maintenance window, UTC."
  type        = string
  default     = "sun:22:30-sun:23:30"
}

variable "rds_deletion_protection" {
  description = "Deletion protection. null means: on for production, off for staging. Production cannot turn it off (checked)."
  type        = bool
  default     = null
}

variable "rds_skip_final_snapshot" {
  description = "Skip the final snapshot when the instance is deleted. Production cannot skip it (checked); staging may, to allow a clean teardown."
  type        = bool
  default     = false
}

variable "rds_final_snapshot_suffix" {
  description = "Suffix of the final snapshot name (<project>-<environment>-final-<suffix>). A snapshot name can be used only once, so change this value (for example to 2) before deleting and recreating a database that already left a final snapshot behind. Allowed: letters and digits, with single hyphens between groups (for example 1, 2, final2 or 2026-11). Not allowed: an empty value, other characters, a leading or trailing hyphen, or two hyphens in a row. The complete name must not exceed 255 characters."
  type        = string
  default     = "1"

  # AWS RDS rules for a final DB snapshot identifier (DeleteDBInstance, FinalDBSnapshotIdentifier): 1 to 255 characters; letters, digits
  # and hyphens; the first character must be a letter; it cannot end with a hyphen or contain two consecutive hyphens. The name here
  # starts with the project name, so the first-character rule is checked on the complete name (precondition on aws_db_instance.main).
  validation {
    condition     = can(regex("^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", var.rds_final_snapshot_suffix))
    error_message = "rds_final_snapshot_suffix must be one or more letters or digits, with single hyphens only between groups (no leading or trailing hyphen, no two hyphens in a row, no other characters)."
  }

  validation {
    condition     = length("${var.project}-${var.environment}-final-${var.rds_final_snapshot_suffix}") <= 255
    error_message = "The complete final snapshot identifier (<project>-<environment>-final-<suffix>) must not exceed 255 characters, the RDS limit."
  }
}

variable "rds_apply_immediately" {
  description = "Apply database modifications immediately instead of in the next maintenance window. Off by default to avoid surprise restarts."
  type        = bool
  default     = false
}

variable "rds_master_secret_kms_key_id" {
  description = "Optional customer-managed KMS key that encrypts the RDS-managed master secret in Secrets Manager. null uses the AWS-managed aws/secretsmanager key."
  type        = string
  default     = null
}

variable "secrets_kms_key_arn" {
  description = "Optional ARN of the customer-managed KMS key that encrypts the application's database secret(s). When set, the instance role may decrypt with it, through Secrets Manager only; when null the default Secrets Manager key is assumed."
  type        = string
  default     = null
}

variable "db_secret_names" {
  description = "Names (the part after '<project>/<environment>/') of the database secrets the backend may read at runtime, e.g. db-app. The instance role is granted GetSecretValue on exactly these secrets, nothing else. The secrets are created outside Terraform, so their values never enter state. Add db-owner only if schema migrations run from the instance."
  type        = list(string)
  default     = ["db-app"]

  validation {
    condition     = length(var.db_secret_names) >= 1 && alltrue([for n in var.db_secret_names : can(regex("^[A-Za-z0-9_.@+=-]+$", n))])
    error_message = "db_secret_names must list at least one name using only letters, digits and _ . @ + = - (no wildcards, no slashes)."
  }
}

# ---- Amazon ECR -----------------------------------------------------------------------------------------------------

variable "ecr_repository_names" {
  description = "Repositories to create in this environment, named '<project>/<environment>/<name>'. backend is the application image; add frontend only if the frontend is also shipped as an image."
  type        = list(string)
  default     = ["backend"]

  validation {
    condition     = length(var.ecr_repository_names) >= 1 && alltrue([for n in var.ecr_repository_names : can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", n))])
    error_message = "ecr_repository_names must be lower-case names (letters, digits and . _ -)."
  }
}

variable "ecr_keep_images" {
  description = "How many of the newest images each repository keeps (older ones expire). Rollback is only possible to images that still exist, so keep enough releases."
  type        = number
  default     = 30

  validation {
    condition     = var.ecr_keep_images >= 5 && var.ecr_keep_images <= 1000
    error_message = "ecr_keep_images must be between 5 and 1000."
  }
}

variable "ecr_untagged_expire_days" {
  description = "Untagged images are removed this many days after they are pushed."
  type        = number
  default     = 7

  validation {
    condition     = var.ecr_untagged_expire_days >= 1
    error_message = "ecr_untagged_expire_days must be at least 1."
  }
}

variable "ecr_kms_key_arn" {
  description = "Optional customer-managed KMS key for ECR encryption. null uses AES-256 service-managed encryption (images are encrypted at rest either way)."
  type        = string
  default     = null
}

# ---- deployment artifact bucket -----------------------------------------------------------------------------------------

variable "artifact_prefix" {
  description = "Key prefix inside the deployment artifact bucket where scripts and configuration are stored. The instance role can read only this prefix."
  type        = string
  default     = "deploy/"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*/$", var.artifact_prefix))
    error_message = "artifact_prefix must be a path ending in a slash, for example deploy/."
  }
}

variable "artifacts_kms_key_arn" {
  description = "Optional customer-managed KMS key for the artifact bucket. null uses S3-managed AES-256 encryption (every object is encrypted at rest either way). When set, the instance role may decrypt with it through S3 only."
  type        = string
  default     = null
}

variable "artifact_noncurrent_retention_days" {
  description = "Days an overwritten or deleted object version is kept before it expires. Versioning keeps older releases of scripts available for rollback within this window."
  type        = number
  default     = 90

  validation {
    condition     = var.artifact_noncurrent_retention_days >= 7
    error_message = "artifact_noncurrent_retention_days must be at least 7."
  }
}

variable "artifact_noncurrent_versions_kept" {
  description = "How many of the newest noncurrent versions of each object are always kept, whatever their age."
  type        = number
  default     = 5

  validation {
    condition     = var.artifact_noncurrent_versions_kept >= 1
    error_message = "artifact_noncurrent_versions_kept must be at least 1."
  }
}
