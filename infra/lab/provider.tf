# Credentials never appear in this repository. The provider reads the named AWS CLI profile (short-lived credentials).
# No access keys, no root credentials.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Refuses any account that is not listed (from your untracked variable file): protects against a wrong profile.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project    = var.project
      ManagedBy  = "terraform"
      Repository = "shopnest-devops-cicd"
      Stack      = "lab"
    }
  }
}
