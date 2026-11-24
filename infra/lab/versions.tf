terraform {
  # Same toolchain as infra/terraform (Terraform 1.17.x). use_lockfile needs Terraform 1.10 or newer.
  required_version = ">= 1.17.1, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Remote state in the EXISTING lab bucket (this configuration creates no state bucket). The bucket name carries the AWS account
  # ID, and the repository must not contain account IDs, so it is NOT written here: it comes from an untracked backend.hcl
  # (see backend.hcl.example):
  #   terraform init -backend-config=backend.hcl
  # Encryption is on and locking uses an S3 lock file (no DynamoDB table). Use the DEFAULT workspace: a named workspace would
  # move the state to a different key (env:/<workspace>/...).
  backend "s3" {
    key          = "terraform/shopnest/terraform.tfstate"
    region       = "ap-south-1"
    profile      = "devops"
    encrypt      = true
    use_lockfile = true
  }
}
