# Minimal lab stack: ONE EC2 instance in ONE public subnet runs BOTH environments (staging and production) as separate Compose
# projects. No NAT Gateway, load balancer, RDS or ECR. Every value below is configuration, never a credential.

variable "project" {
  description = "Name prefix for resources and tags. Deliberately different from the staging/production stack in infra/terraform so the two can never collide."
  type        = string
  default     = "shopnest-lab"
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

variable "allowed_account_ids" {
  description = "AWS account ID(s) this configuration may be applied to. Required, no default, and never in a tracked file: put it in your own untracked variable file."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) >= 1 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must list at least one 12-digit AWS account ID."
  }
}

# ---- network -------------------------------------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC (a /16 or larger; the one public subnet is carved from it with cidrsubnet). No default on purpose, and never in a tracked file: put a private IPv4 range of your choice in your own untracked variable file."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix of /24 or larger."
  }
}

# ---- instance --------------------------------------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 type. The approved lab size is t3.small (2 GiB: nginx, two backends and a PostgreSQL container per environment)."
  type        = string
  default     = "t3.small"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like t3.small."
  }
}

variable "existing_instance_profile" {
  description = "Name of a pre-provisioned IAM instance profile to attach to the instance instead of creating one. Empty (the default) creates the lab's own role and profile. When set, Terraform only READS the profile and neither creates nor changes any IAM role or profile and attaches no policy: the profile's role must already trust ec2.amazonaws.com and carry AmazonSSMManagedInstanceCore, and the applying identity still needs iam:PassRole for that role."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_instance_profile == "" || can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", var.existing_instance_profile))
    error_message = "existing_instance_profile must be an instance profile name (letters, digits and + = , . @ _ - only), or empty."
  }
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (OS, Docker images, both PostgreSQL data volumes)."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_size_gb >= 20 && var.root_volume_size_gb <= 100
    error_message = "root_volume_size_gb must be between 20 and 100."
  }
}

variable "swap_size_gb" {
  description = "Size of the swap file created at first boot (a t3.small has 2 GiB of RAM; swap absorbs the short peak while a new colour starts). 0 disables it."
  type        = number
  default     = 1

  validation {
    condition     = var.swap_size_gb >= 0 && var.swap_size_gb <= 4
    error_message = "swap_size_gb must be between 0 and 4."
  }
}

variable "use_elastic_ip" {
  description = "Attach an Elastic IP so the live URL survives a stop/start. An address attached to a RUNNING instance costs the same as an auto-assigned public IPv4 address; an unattached or stopped one keeps billing, so release it (terraform destroy) after grading."
  type        = bool
  default     = true
}

# ---- CI/CD (GitHub OIDC deploy roles; the SSM command documents are an optional fallback) ---------------------------------
# All of this is gated by enable_cicd (default false). Nothing here is a secret.

variable "enable_cicd" {
  description = "Create the GitHub OIDC provider (optional) and the two GitHub deploy roles (one per environment; each can only open an SSM port-forwarding session to the lab instance). Default false."
  type        = bool
  default     = false
}

variable "create_ssm_documents" {
  description = "Also create the four fixed SSM command documents (deploy and rollback, per environment), the earlier SSM Run Command way of deploying. NOT used by the workflows (they deploy over SSH through an SSM tunnel) and no role can send them, so the default is false. Only has an effect when enable_cicd is true. Creating them needs ssm:CreateDocument."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "The GitHub repository allowed to deploy, as owner/name. Required when enable_cicd is true. The instance fetches this PUBLIC repository at the exact commit being deployed."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "github_oidc_subjects" {
  description = "The exact OIDC 'sub' claim that may assume each environment's deploy role, as {staging = \"...\", production = \"...\"}. Capture the REAL claim from a workflow run (an environment subject ends in ':environment:<name>'); do not guess it. Matched with StringEquals: wildcards are refused."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k, s in var.github_oidc_subjects : contains(["staging", "production"], k) && length(s) > 0 && !can(regex("[*?]", s))])
    error_message = "github_oidc_subjects keys must be staging or production, and each subject must be non-empty and must not contain wildcards (* or ?)."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the account's GitHub OIDC identity provider. An account can hold only ONE provider for token.actions.githubusercontent.com: check first whether it already exists, and if it does set this to false and give github_oidc_provider_arn."
  type        = bool
  default     = false
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC identity provider in this account (used when create_github_oidc_provider is false)."
  type        = string
  default     = ""

  validation {
    condition     = var.github_oidc_provider_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must be the ARN of the token.actions.githubusercontent.com OIDC provider."
  }
}
