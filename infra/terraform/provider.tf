# Credentials never appear in this repository. The provider reads the named AWS CLI profile
# (short-lived credentials from `aws login` / SSO). No access keys, no root credentials.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Refuses any account that is not listed (from your untracked variable file). See also the non-root check on aws_vpc.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "shopnest-devops-cicd"
    }
  }
}
