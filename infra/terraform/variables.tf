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
  description = "false (default): ONE NAT Gateway in the first Availability Zone serves every private subnet. That is a cost optimisation and a SINGLE POINT OF FAILURE for outbound connectivity (Systems Manager, ECR image pulls, Secrets Manager, packages): if that AZ fails, instances in the other AZ keep serving traffic through the ALB but cannot make outbound calls. true: one NAT Gateway per AZ, each AZ routes through its own (roughly doubles the NAT cost)."
  type        = bool
  default     = false
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
}

variable "alb_allowed_cidrs" {
  description = "Source CIDRs allowed to reach the load balancer. Required, no default, and never in a tracked file: put it in your own untracked variable file. Production states its audience explicitly; staging must list specific addresses (open-to-the-world is refused for staging)."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in ap-south-1. When empty the ALB serves plain HTTP (no domain exists yet); when set, HTTPS is served and HTTP redirects to it. HTTPS is not production-ready without a real domain and certificate."
  type        = string
  default     = ""
}

variable "enable_deletion_protection" {
  description = "ALB deletion protection. Off by default so assignment infrastructure can be torn down; turn on for anything long-lived."
  type        = bool
  default     = false
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
  description = "Storage type: gp3 (default), gp2 or io1."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp3", "gp2", "io1"], var.rds_storage_type)
    error_message = "rds_storage_type must be gp3, gp2 or io1."
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
  description = "Upper limit for storage autoscaling in GiB; null turns autoscaling off."
  type        = number
  default     = null
}

variable "rds_storage_kms_key_id" {
  description = "Optional customer-managed KMS key for RDS storage. null uses the AWS-managed aws/rds key. Storage encryption itself cannot be turned off."
  type        = string
  default     = null
}

variable "rds_multi_az" {
  description = "Run a synchronous standby in a second Availability Zone with automatic failover. Roughly doubles the instance and storage cost; see README."
  type        = bool
  default     = false
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
