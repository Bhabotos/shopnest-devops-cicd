# No output carries a secret value. The RDS master secret appears only as an ARN (an identifier, not the secret).

output "environment" {
  description = "Application environment this stack serves."
  value       = var.environment
}

output "vpc_id" {
  description = "ID of the dedicated VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnets (ALB, NAT Gateway), by Availability Zone."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "app_subnet_ids" {
  description = "Private application subnets, by Availability Zone."
  value       = { for az, s in aws_subnet.app : az => s.id }
}

output "db_subnet_ids" {
  description = "Private database subnets, by Availability Zone. They have no route to the internet."
  value       = { for az, s in aws_subnet.db : az => s.id }
}

output "security_group_ids" {
  description = "Security group IDs by tier."
  value = {
    alb = aws_security_group.alb.id
    app = aws_security_group.app.id
    db  = aws_security_group.db.id
  }
}

output "instance_ids" {
  description = "Application instance IDs by index and Availability Zone: the targets for Systems Manager (aws ssm start-session --target <id>) and for SSM Run Command. One instance in staging, two in production."
  value       = { for k, i in aws_instance.app : k => { id = i.id, availability_zone = i.availability_zone } }
}

output "instance_private_ips" {
  description = "Private addresses of the instances (no public address exists)."
  value       = { for k, i in aws_instance.app : k => i.private_ip }
}

output "instance_role_name" {
  description = "IAM role attached to the instance."
  value       = aws_iam_role.instance.name
}

output "alb_dns_name" {
  description = "DNS name of the load balancer. Do not write it into repository files while the live URL is pending the instructor's answer."
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "Target group the ALB forwards to."
  value       = aws_lb_target_group.app.arn
}

output "rds_instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.main.identifier
}

output "rds_endpoint_address" {
  description = "Private DNS name of the database. It resolves only inside the VPC."
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "Database port."
  value       = aws_db_instance.main.port
}

output "rds_master_secret_arn" {
  description = "ARN of the RDS-managed master secret in Secrets Manager (the ARN only; read the value through the console or CLI with your own permissions, never from Terraform)."
  value       = one(aws_db_instance.main.master_user_secret[*].secret_arn)
}

output "db_secret_ids" {
  description = "Names (identifiers) of the database secrets the backend reads at runtime with the AWS SDK. Put one of these in the application's configuration (for example DB_SECRET_ID), never the secret value. The secrets are created outside Terraform."
  value       = [for n in var.db_secret_names : "${var.project}/${var.environment}/${n}"]
}

output "nat_gateway_count" {
  description = "Number of NAT Gateways. 1 means outbound connectivity is a single point of failure."
  value       = length(aws_nat_gateway.main)
}

output "ecr_repository_urls" {
  description = "Repository URLs by name (registry host plus repository). CI pushes here; the instances pull from here."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "ecr_repository_arns" {
  description = "Repository ARNs by name."
  value       = { for k, r in aws_ecr_repository.app : k => r.arn }
}
