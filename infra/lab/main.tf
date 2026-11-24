data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = var.project
  az   = data.aws_availability_zones.available.names[0]

  # Both environments live on this one instance, as separate Compose projects (shopnest-staging, shopnest-production).
  environments = ["staging", "production"]
}

# Refuse to run as the AWS root user, whatever the profile says.
resource "terraform_data" "not_root" {
  lifecycle {
    precondition {
      condition     = !endswith(data.aws_caller_identity.current.arn, ":root")
      error_message = "Refusing to run as the AWS root user. Use the short-lived 'devops' profile (never root credentials)."
    }
  }
}
