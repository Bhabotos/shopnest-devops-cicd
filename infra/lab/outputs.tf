# No output carries a secret value. The public address is an output so YOU can read it locally after an approved apply; it must not
# be written into any file that is committed before the live-URL step in README.md is done on purpose.

output "instance_id" {
  description = "The lab instance: the target for Session Manager (aws ssm start-session --target <id>) and for the deploy tunnel. Set it as the GitHub Environment variable LAB_INSTANCE_ID."
  value       = aws_instance.lab.id
}

output "region" {
  description = "AWS region."
  value       = var.aws_region
}

output "public_ip" {
  description = "Public IPv4 address of the instance (the Elastic IP when use_elastic_ip is true). The live URL is http://<this address>/ . Read it with: terraform output -raw public_ip"
  value       = var.use_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.lab.public_ip
}

output "deploy_role_arns" {
  description = "ARN of each environment's GitHub deploy role (empty unless enable_cicd). Set the matching one as the AWS_ROLE_ARN variable of the staging and production GitHub Environments."
  value       = { for env, r in aws_iam_role.github_deploy : env => r.arn }
}

output "ssm_document_names" {
  description = "Names of the optional fallback SSM documents (empty unless enable_cicd AND create_ssm_documents; the workflows do not use them)."
  value = {
    deploy   = { for env, d in aws_ssm_document.deploy : env => d.name }
    rollback = { for env, d in aws_ssm_document.rollback : env => d.name }
  }
}
