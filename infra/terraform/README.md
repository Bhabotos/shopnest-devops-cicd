# ShopNest AWS infrastructure (Terraform)

Status: **configuration written and statically validated (`terraform fmt`, `terraform validate`). No AWS authentication, no
`terraform plan`, no apply, no deployment has been done.** `terraform apply` and `terraform destroy` need the owner's explicit approval
in that turn. Region `ap-south-1`, AWS CLI profile `devops` (short-lived credentials; never root, never access keys, nothing in
code). Terraform `>= 1.17.1`, AWS provider `~> 6.0` (locked in `.terraform.lock.hcl`, which is committed).

Read next: [`ARCHITECTURE.md`](ARCHITECTURE.md) (decisions, flows, failure modes) and
[`INTEGRATION_GAPS.md`](INTEGRATION_GAPS.md) (what the deploy scripts, backend and workflows must change; none of them was modified).

## Decisions implemented
| Area | Decision |
|---|---|
| Database | Private AWS RDS PostgreSQL (no PostgreSQL container anywhere) |
| Deployment access | AWS Systems Manager only: no SSH, no key pair, no inbound port 22 |
| Application delivery | Amazon ECR (immutable, scanned, encrypted, lifecycle-managed); instances pull with their IAM role |
| Database secret retrieval | AWS SDK in the backend at runtime; configuration holds only the secret's identifier |
| Private subnet internet access | NAT Gateway (a single one by default: see "NAT Gateway") |
| Network values in tracked files | None: `vpc_cidr` and `alb_allowed_cidrs` live only in your untracked variable files |
| Availability | Staging: one instance. Production: two instances in two Availability Zones behind the ALB |

## Layout: one stack per environment
Staging and production are two deployments of this same configuration, each with its **own VPC, instances, ALB, RDS and ECR
repository**, its own Terraform workspace and its own variable file.

```powershell
terraform workspace new staging            # once
terraform workspace select staging
terraform plan -var-file=staging.tfvars    # plan only; never apply without approval
```
The VPC refuses to plan unless the selected workspace equals the `environment` variable, so staging variables cannot be applied to
production state. Start from `staging.tfvars.example` / `production.tfvars.example`; add `vpc_cidr` and `alb_allowed_cidrs` in your
untracked copy (the examples deliberately contain no network ranges, so gitleaks has nothing to flag).

## 1. Architecture and traffic flow
```text
                              Internet
                                 |
                      +----------v-----------+      public subnets (2 AZs): ALB, NAT Gateway
                      |  Application Load    |
                      |  Balancer            |
                      +----+-------------+---+
            app_port, from |             | app_port, from the ALB security group only
          the ALB group    |             |
      +--------------------v--+   +------v-----------------+   private application subnets (one per AZ)
      | EC2 #1 (AZ a)         |   | EC2 #2 (AZ b)          |   staging: only #1 exists
      | nginx + backend       |   | nginx + backend        |   production: both, both in the target group
      +-----------+-----------+   +-----------+------------+
                  |  5432 (TLS), backend group -> db group  |
                  +--------------------+--------------------+
                                       v
                          +------------+-------------+     private database subnets (2 AZs),
                          |  RDS PostgreSQL          |     no route to the internet
                          |  (optional Multi-AZ)     |
                          +--------------------------+
   Outbound (instances): NAT Gateway -> Systems Manager, ECR, Secrets Manager, package repositories. No inbound administration.
```
- **Users:** browser to the ALB, to nginx on an instance (`app_port`), to the live backend colour.
- **ALB to the application tier:** inside the VPC only, on `app_port`. The one security-group path is ALB group to backend group on that port.
  Target-group health checks call `/health` through nginx; the backend answers it by querying the database, so a target is healthy only if
  its backend can reach RDS.
- **Backend to database:** the backend connects to the RDS private DNS name on 5432 over TLS (`rds.force_ssl = 1`), allowed only from the backend
  security group to the database security group.
- **Listeners:** without a certificate the ALB serves **plain HTTP** on 80. With `acm_certificate_arn` it serves HTTPS on 443 and redirects 80.
  **HTTPS is not production-ready until a real domain and an ACM certificate exist.**

## 2. Subnets
| Tier | Subnets | Holds | Internet |
|---|---|---|---|
| Public | one /24 per AZ (2) | ALB, NAT Gateway(s) | Internet Gateway |
| Application (private) | one /24 per AZ (2) | the instances (staging: AZ a only; production: one per AZ) | outbound only, via a NAT Gateway |
| Database (private) | one /24 per AZ (2) | RDS and its optional standby; the DB subnet group spans both | none |

All ranges are derived from your `vpc_cidr` (a /16 you choose per environment) with `cidrsubnet`.

## 3. Application capacity and availability
- **Staging:** one instance, one target. Cost-conscious, not redundant.
- **Production:** `app_instance_count` defaults to 2; instances are placed round-robin across the two AZs and **both are registered in the ALB
  target group**. Preconditions refuse production with fewer than two instances or with all instances in one AZ.
- **What this gives:** if one instance (or its AZ) fails its health check the ALB stops sending traffic to it and the other keeps serving. It does
  not make production "highly available" on its own: see the limitations below. Nothing here is a claim of 100% availability.
- **Remaining limitations (production):**
  1. **Single NAT Gateway by default.** It lives in one AZ. If that AZ fails, instances in the other AZ keep serving through the ALB but lose
     outbound connectivity: no new Systems Manager sessions or deploys, no image pulls, no Secrets Manager reads (a restarted backend cannot
     fetch its database secret). `nat_per_az = true` gives each AZ its own gateway.
  2. **The database is only redundant if `rds_multi_az = true`**, and then only across two AZs; a failover takes about a minute or two (AWS-stated,
     not measured here), during which `/health` fails and the ALB serves 503.
  3. **Both instances run the same release and need a coordinated deploy** (the current scripts handle one host). A bad release reaches both.
  4. The ALB is regional and spans two AZs, but there is no cross-region recovery. No ALB access logs, flow logs or alarms.
  5. Backups protect against bad data; a restore has **not** been rehearsed.

## 4. NAT Gateway
The NAT Gateway is the selected way for private subnets to reach the internet. **A single NAT Gateway is a cost optimisation (staging) and a single
point of failure for outbound connectivity; it is not multi-AZ NAT.** `nat_per_az = true` creates one per AZ (outbound then survives the loss of an AZ, at
roughly double the NAT cost). The instances need outbound HTTPS (443; 80 for apt mirrors) to:

| Service | Why |
|---|---|
| `ssm`, `ssmmessages`, `ec2messages` (regional endpoints) | Systems Manager agent registration, sessions and Run Command |
| ECR API and ECR registry (`api.ecr`, `dkr.ecr`) and Amazon S3 | `docker pull` (image layers are served from S3) |
| `secretsmanager` | the backend's runtime secret read (AWS SDK) |
| `kms` (only with customer-managed keys) | decrypt of secrets or ECR images |
| Ubuntu mirrors, container base-image registries | packages at boot, any non-ECR images |

VPC interface endpoints are an alternative for the AWS services only; they would not replace the NAT Gateway while packages and base images come from
the internet. They are **not** configured (NAT was the decision).

## 5. RDS PostgreSQL
| Setting | Value |
|---|---|
| Engine | PostgreSQL **16** (major; RDS picks its current default minor, which then moves with automatic minor upgrades and is ignored by Terraform). Matches CI and local development. Confirm available minors with `aws rds describe-db-engine-versions` before the first apply (not done: no AWS access) |
| Class / storage | `db.t4g.micro` (staging), `db.t4g.small` (production); gp3, 20 GiB / 50 GiB, autoscaling limit configurable |
| Access | `publicly_accessible = false`, private DB subnet group, port 5432, TLS enforced. Hard-coded, not variables |
| Encryption | always on (AWS-managed key, or `rds_storage_kms_key_id`); not a variable |
| Multi-AZ | `rds_multi_az`: off for staging, on for production |
| Backups | automated; `rds_backup_retention_days` 1 to 35 (never 0); staging 1, production 7; point-in-time recovery within the window |
| Deletion protection | on for production (cannot be turned off: precondition); a final snapshot is required for production |
| Credentials | **none in Terraform.** `manage_master_user_password = true`: RDS generates the master password and keeps it in Secrets Manager. State and outputs hold only the secret's ARN |

**Single-AZ vs Multi-AZ:** Multi-AZ adds a synchronous standby in another AZ with automatic failover and roughly **doubles** instance and storage cost.
It protects against an instance or AZ failure, not against bad data, a bad migration or deletion; backups do. Single-AZ is cheaper and is down until RDS
recovers or you restore.

## 6. Security groups
No rule opens port 22 anywhere, and none opens 5432 to a CIDR.

| Group | Inbound | Outbound |
|---|---|---|
| `alb` | 80 (or 443 plus 80 for the redirect) from `alb_allowed_cidrs` (required, no default; staging refuses the whole internet) | `app_port` to the `app` group only |
| `app` (backend instances) | `app_port` from the `alb` group only | 443 and 80 to anywhere (via NAT); 5432 to the `db` group |
| `db` (RDS) | 5432 from the `app` group only | none |
| default SG | none (emptied) | none |

Also: no public address on any instance or on RDS; EBS and RDS encrypted; IMDSv2 required (see the hop-limit note below).

## 7. Systems Manager: access and minimum permissions
SSM is the only administrative access: no key pair, no sshd configuration, no inbound port.
- **Instance role (created here):** `AmazonSSMManagedInstanceCore`. The SSM agent is preinstalled on the Ubuntu AMI and registers over outbound HTTPS.
- **Deploy role (NOT created; needs the OIDC `sub` claim, `docs/OIDC_DESIGN.md` item 2a). Minimum permissions it will need:**
  - `ssm:SendCommand` on the specific instance ARNs and on one SSM document (not `AWS-RunShellScript` open to anything), with a tag or ID condition;
  - `ssm:GetCommandInvocation` and `ssm:ListCommandInvocations` to read the result;
  - `ssm:DescribeInstanceInformation` to check the instances are online;
  - for CI, ECR push: `ecr:GetAuthorizationToken` (resource `*`), `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`,
    `ecr:CompleteLayerUpload`, `ecr:PutImage`, scoped to this environment's repository ARN.
- **Operators:** the `devops` profile needs `ssm:StartSession` on the instances to open a shell or port-forward.

## 8. Amazon ECR
| Property | Value |
|---|---|
| Repositories | `<project>/<environment>/<name>`, by default `shopnest/<environment>/backend` (`ecr_repository_names` adds more, for example `frontend`) |
| Tags | **immutable**: a pushed tag can never be overwritten |
| Scanning | scan on push (basic scanning) |
| Encryption | at rest, AES-256 by default or a customer-managed key (`ecr_kms_key_arn`) |
| Lifecycle | untagged images expire after `ecr_untagged_expire_days` (7); only the newest `ecr_keep_images` (30 staging, 50 production) are kept. **Rollback is only possible to images that still exist.** |
| Deletion | `force_delete = false`: a repository that holds images cannot be destroyed silently |
| Pull permission | the instance role may pull from this environment's repositories only (login token, layer reads, image reads, `DescribeImages`); it cannot push |
| Credentials | none on the host: the instance role authenticates (`aws ecr get-login-password`) |
| Outputs | repository URLs and ARNs |

Per-environment repositories keep each stack self-contained (destroying staging cannot delete production's images). Promoting a release means
copying the image manifest from the staging repository to the production one (digest preserved); a single shared repository would avoid the copy but
tie staging's teardown to production's images. **Interpretation to confirm.**

## 9. Secrets Manager and runtime retrieval (AWS SDK)
- **Master secret:** created and held by RDS in Secrets Manager. Not readable by the instances; for operator bootstrap only.
- **Application secret:** `shopnest/<environment>/db-app` (JSON with the `shopnest_app` credentials), created **outside Terraform** after the database exists, so its value
  never enters state or plan output.
- **Instance access is to that one secret only.** The policy lists the exact secret name followed by six single-character wildcards (`-??????`), which is
  how AWS expects a secret to be named before its random suffix is known. It is **not** a prefix wildcard: `db-app-x` or `db-owner` do not match. Names come
  from `db_secret_names` (default `db-app`; add `db-owner` only if migrations run on the instance). `kms:Decrypt` is added only if a customer key is set,
  restricted to use through Secrets Manager.
- **Application configuration holds only an identifier** (for example `DB_SECRET_ID=shopnest/<environment>/db-app`, plus host, port and database name from
  Terraform outputs), never the secret value. The backend calls `GetSecretValue` at start-up through the instance role.
- **IMDS hop limit is 2 (`imds_hop_limit`).** The backend runs in a container; with the safer limit of 1 its SDK could not reach the instance metadata
  service to get credentials. At 2, **any process in a container on that host can obtain the instance role's credentials**, so the role is deliberately small
  (SSM core, ECR pull, one secret). This is a deliberate trade-off against the earlier hop-limit-1 hardening; mitigations (blocking metadata for other
  containers, or host networking for the backend only) are listed in `INTEGRATION_GAPS.md`.
- **Limits of passing sensitive values through Terraform:** a secret given to a resource argument is stored in plaintext in state and may appear in plan
  output. This configuration never does that. A secret the application reads is still visible to that process.

## 10. Terraform state
Local backend, git-ignored (`*.tfstate`, `terraform.tfstate.d/`, `*.tfplan`). Workspaces keep staging and production apart. State holds identifiers and
attributes, no secret values here. There is no locking, versioning or encryption beyond the disk, and losing state orphans billed resources. A remote S3
backend with versioning, encryption and locking is the usual remedy and needs its own approval.

## 11. Staging and production differences
| | Staging | Production |
|---|---|---|
| Application instances | **1** (`t3.small`) | **2**, in two AZs, both in the ALB target group (`t3.small` each) |
| ALB sources | specific addresses only | stated explicitly in your untracked file |
| `app_port` | 8081 (matches `deploy/env/staging.env`) | 80 (matches `deploy/env/production.env`) |
| RDS | `db.t4g.micro`, single-AZ, 20 GiB, 1 day of backups, no deletion protection, no final snapshot | `db.t4g.small`, **Multi-AZ**, 50 GiB, 7 days, **deletion protection**, final snapshot |
| NAT Gateway | 1 (cost optimisation, outbound SPOF) | 1 by default (same SPOF); `nat_per_az = true` is an open decision |
| ECR retention | newest 30 | newest 50 |

## 12. Estimated monthly cost (USD, 730 h, Mumbai) — APPROXIMATE
**Estimates with stated assumptions, not quotes.** The AWS pricing API could not be queried (no authentication was allowed) and public pages showed no Mumbai
rates, so ranges come from general list prices; only the public IPv4 charge ($0.005 per address-hour) was confirmed from an AWS-sourced page. Confirm
with the AWS Pricing Calculator (Asia Pacific, Mumbai).

| Item (assumption) | A. Staging | B. Production, single NAT | C. Production, NAT per AZ |
|---|---|---|---|
| ALB (about $0.0225 to $0.027 per hour, about 1 LCU) | $22 to $26 | $22 to $28 | $22 to $28 |
| EC2 `t3.small` (about $0.021 to $0.025 per hour) | 1 instance: $15 to $18 | 2 instances: $30 to $36 | 2 instances: $30 to $36 |
| EBS gp3 root, 20 GiB each | $2 | $3 to $4 | $3 to $4 |
| RDS instance (A: `db.t4g.micro` single-AZ; B and C: `db.t4g.small` Multi-AZ, about 2x single) | $13 to $17 | $52 to $67 | $52 to $67 |
| RDS storage (A: 20 GiB; B and C: 50 GiB billed twice) | $3 | $13 to $15 | $13 to $15 |
| RDS backup storage (A: 1 day within the free allowance; B and C: 7 days) | $0 | $2 to $6 | $2 to $6 |
| NAT Gateway (about $0.045 to $0.056 per hour) plus data processing | $33 to $42 (1 gateway, 10 GB) | $35 to $45 (1 gateway, 50 GB) | $70 to $88 (2 gateways, 50 GB) |
| Public IPv4 at $0.005 per hour (ALB 2 + each NAT 1) | $11 (3) | $11 (3) | $14 (4) |
| ECR (storage about $0.10 per GB-month; scan on push, basic) | $1 | $1 to $2 | $1 to $2 |
| VPC endpoints | not used | not used | not used |
| Data transfer, cross-AZ, misc. | $1 to $3 | $3 to $8 | $3 to $8 |
| **Approximate total** | **about $101 to $123** | **about $172 to $222** | **about $209 to $267** |

Both environments running (A + B): about **$273 to $345 a month**. Fixed costs run whether or not anyone uses the stacks; tear staging down between sessions (with approval).

## 13. Security review (static)
| Check | Result |
|---|---|
| RDS public | no: private subnets, `publicly_accessible = false`, no internet route |
| 5432 open to a CIDR | no: backend group to database group only |
| Port 22 / SSH keys | no rule, no key pair, no sshd configuration |
| Public IP on instances | none |
| Unencrypted storage | none: EBS, RDS and ECR encrypted |
| Backups, production deletion protection | backups always on; protection and 7-day retention enforced for production |
| Secret values in files, outputs, state | none (master password RDS-managed; application secret out-of-band; outputs carry ARNs and names only) |
| IAM | SSM core, ECR pull (scoped), one named secret; one unavoidable `*` resource (`ecr:GetAuthorizationToken`, which AWS cannot scope) |
| IMDS | v2 required; hop limit 2 is a deliberate, documented trade-off (section 9) |
| Stateful replacement | RDS deletion protection (production), ignored minor drift; ECR `force_delete = false`; instances ignore AMI and boot-script changes |
| Gitleaks | no findings: no CIDRs in tracked files |
| Not verifiable without AWS | a real plan and resource count, availability of the instance class and engine version, quotas, IAM evaluation |

## Open decisions
1. NAT per AZ for production (about +$37 to $45 a month) or accept the outbound single point of failure.
2. ECR repository per environment (implemented) vs one shared repository.
3. Whether to mitigate the hop-limit-2 exposure (block metadata for non-backend containers, or run the backend with host networking).
4. Whether migrations run from the instance (then `db-owner` must be added to `db_secret_names`).
5. SSM Run Command vs the assignment's "deployment over SSH" wording: confirm with the instructor.
6. Remote Terraform state.
