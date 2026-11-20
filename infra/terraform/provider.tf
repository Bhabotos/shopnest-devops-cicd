# Credentials never appear in this repository. The provider reads the named AWS CLI profile
# (short-lived credentials from `aws login` / SSO). No access keys, no root credentials.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "shopnest-devops-cicd"
    }
  }
}
