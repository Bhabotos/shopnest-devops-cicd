# ShopNest cloud architecture (design record for `infra/terraform`)

Status: a **design**, written as Terraform and statically validated. Nothing has been planned against AWS, created or deployed.
This file records the decisions, the flows and the failure modes. Operating details, costs and the security review are in
[`README.md`](README.md); required changes to the existing deploy code are in [`INTEGRATION_GAPS.md`](INTEGRATION_GAPS.md).
It supersedes, for the AWS side, the earlier single-instance design in `docs/ARCHITECTURE.md` (not yet updated: that needs approval).

## Decisions (final)
| # | Area | Decision | Consequence |
|---|---|---|---|
| 1 | Database | private AWS RDS PostgreSQL | no PostgreSQL container; the Compose `db` service and `@db:5432` go away |
| 2 | Deployment access | AWS Systems Manager | no SSH, no key pair, no inbound port; the SSH-based workflows must be rewritten |
| 3 | Application delivery | Amazon ECR | CI pushes an immutable image; instances pull it with their role; no bundle upload |
| 4 | Database secret | AWS SDK at runtime | the backend needs a code change; config holds only the secret identifier |
| 5 | Private internet access | NAT Gateway | outbound dependency; production one NAT per AZ, staging a single NAT (cost optimisation and an outbound SPOF; not multi-AZ NAT) |
| 6 | Network ranges in tracked files | none | `vpc_cidr` and `alb_allowed_cidrs` are supplied in untracked variable files |
| 7 | Availability | staging 1 instance; production 2 instances in 2 AZs | redundancy for the application tier only, with the limits below |
| 8 | Production NAT | one NAT Gateway per AZ; each AZ routes through its own | no cross-AZ NAT routing in production; about $37 to $45 a month more; staging keeps one NAT (cost optimisation, outbound SPOF) |
| 9 | Deployment artifacts | private, encrypted, versioned S3 bucket per environment | for future scripts and configuration; read-only for the instance, nothing uploaded yet |
| 10 | Infrastructure CI | dedicated Terraform CI workflow | fmt, init without a backend, validate, secret scan; no AWS access |
| 11 | Account safety | `allowed_account_ids` required; root identity refused | stops a wrong profile or root credentials before anything is created |

Interpretations made while implementing (to confirm): one ECR repository set **per environment**; the application secret is read through a
`-??????` name pattern (one named secret, not a prefix); IMDS hop limit 2 so the container's SDK can use the instance role; `t3.small` instances.

## Components per environment (one stack each)
VPC with 2 AZs; public subnets (ALB, NAT); private application subnets (EC2); private database subnets (RDS); Internet Gateway; NAT Gateway; one
application security group, one database security group, one ALB security group; EC2 instances; ALB with one target group; RDS PostgreSQL with a DB
subnet group and a parameter group (TLS required); ECR repositories with a lifecycle policy; a private, encrypted, versioned S3 artifact bucket; an EC2 instance role and profile. Not created: the GitHub
OIDC provider and deploy role, the database secrets, the TLS certificate and domain.

## Flow 1: a release (target design; the workflows are not changed yet)
1. CI builds the Docker image and pushes it to ECR under an immutable tag (the commit SHA). The push uses the CI role (OIDC), not stored keys.
2. The deploy workflow resolves the exact tag, preferably the image **digest**, and checks the scan result.
3. It calls SSM Run Command on each instance (production: one after the other, so one instance always serves).
4. The instance logs in to ECR with its role (`aws ecr get-login-password`), pulls the image by digest and starts the idle colour.
5. The blue/green script validates `/health` and `/version`, switches nginx, verifies, and rolls back on failure (exit 1 or 3 as today).
6. The ALB health check (`/health` through nginx, which queries the database) confirms the instance is serving; the workflow reports the result.

## Flow 2: database credentials at runtime
`backend` starts, reads `DB_SECRET_ID` (an identifier) from its environment, calls Secrets Manager `GetSecretValue` with the instance role (reached through
IMDSv2, hence hop limit 2), builds its connection from the returned JSON and connects to the RDS private name on 5432 over TLS. The secret value is never in
Terraform state, outputs, images or repository files. The RDS master secret is not readable by the instances; it is for operator bootstrap only.

## Flow 3: administration
An operator (or the deploy role) uses Systems Manager over the instance's outbound HTTPS connection: `start-session` for a shell, port-forwarding to reach a
private port, Run Command for deploys. There is nothing to connect to inbound.

## Availability and failure modes (honest summary)
| Failure | Staging (1 instance, single-AZ RDS) | Production (2 instances, Multi-AZ RDS, NAT per AZ) |
|---|---|---|
| One application instance dies | outage until replaced | ALB stops sending to it; the other serves |
| One AZ fails | outage if it holds the instance | the instance in the other AZ serves; if the NAT AZ failed, it loses outbound (no deploys, pulls, secret reads) |
| RDS instance or AZ fails | down until RDS recovers or a restore | automatic failover, typically a minute or two of failing `/health` (503) |
| Bad migration or bad data | restore from backup (1 day) | restore from backup (7 days); Multi-AZ does not help |
| Bad release | rollback script (exit 1 or 3) | the same, per instance; a bad release deployed to both reaches both |
| NAT Gateway AZ lost | outbound lost (single gateway) | the other AZ keeps its own gateway; the instance in the failed AZ is lost anyway |
| Region failure | total outage | total outage (no cross-region design) |

Production is **redundant across two AZs at the application tier, and at the database only if Multi-AZ is on**. It is not "highly available" in any
absolute sense: the outbound path, the single release stream and the single region remain.

## What is not decided or not done
Bundle/digest handling in the deploy scripts, the SSM deploy document, the OIDC roles, the TLS certificate and domain (the site is HTTP-only until then),
alarms and logging, remote Terraform state, and everything in `INTEGRATION_GAPS.md`. No evidence collected so far (local Docker rehearsals, attempts 1 to 5)
applies to this architecture.
