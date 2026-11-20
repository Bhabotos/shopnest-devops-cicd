terraform {
  # Pinned to the toolchain used for this project (Terraform 1.17.x).
  required_version = ">= 1.17.1, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is local and git-ignored (project decision, see README "State"). No backend block on purpose:
  # a remote backend would need an S3 bucket and lock table, which are separate, approved resources.
}
