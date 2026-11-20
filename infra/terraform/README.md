# ShopNest AWS infrastructure (Terraform)

Status: **configuration written and statically validated (`terraform fmt`, `terraform validate`; a dedicated Terraform CI workflow runs the
same checks). Phase 4.2 remediation has been applied (see [`REMEDIATION_LOG.md`](REMEDIATION_LOG.md)). No AWS authentication, no
`terraform plan`, no apply, no deployment has been done**, so none of it has been exercised against AWS. `terraform apply` and `terraform destroy`
need the owner's explicit approval in that turn. Region `ap-south-1`, AWS CLI profile `devops` (short-lived credentials; never root, never access keys, nothing in
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
| Private subnet internet access | NAT Gateway: **production one per Availability Zone** (each AZ routes through its own); staging a single one (see "NAT Gateway") |
| Values kept out of tracked files | `vpc_cidr`, `alb_allowed_cidrs` and `allowed_account_ids` live only in your untracked variable files |
| Availability | Staging: one instance. Production: two instances in two Availability Zones behind the ALB |
| Deployment artifacts | A private, encrypted, versioned S3 bucket per environment for future deployment scripts and configuration (see section 8a) |
| Infrastructure CI | `.github/workflows/terraform-ci.yml`: fmt, init without a backend, validate, secret scan; no AWS access (see section 14) |

## Layout: one stack per environment
Staging and production are two deployments of this same configuration, each with its **own VPC, instances, ALB, RDS and ECR
repository**, its own Terraform workspace and its own variable file.

```powershell
terraform workspace new staging            # once
terraform workspace select staging
terraform plan -var-file=staging.tfvars    # plan only; never apply without approval
```
The VPC refuses to plan unless the selected workspace equals the `environment` variable, so staging variables cannot be applied to
production state. Start from `staging.tfvars.example` / `production.tfvars.example`; add **`allowed_account_ids`, `vpc_cidr` and `alb_allowed_cidrs`**
in your untracked copy (the examples deliberately contain no account IDs or network ranges, so gitleaks has nothing to flag).
Two guards run before anything is created: the provider refuses any account not listed in `allowed_account_ids`, and the VPC refuses to plan when the caller
is the AWS root user.

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
  1. **Production has one NAT Gateway per AZ**, and each AZ's private subnet routes through the gateway in its own AZ, so losing one AZ does not
     take outbound connectivity (Systems Manager, ECR pulls, Secrets Manager reads) away from the other. This removes the outbound single point of
     failure for production, not every dependency: a regional service problem, or a failure of the gateway's own AZ for the instance in that AZ, still
     applies. **Staging keeps a single NAT Gateway: a cost optimisation and a single point of failure for outbound connectivity, not multi-AZ NAT.**
  2. **The database is only redundant if `rds_multi_az = true`**, and then only across two AZs; a failover takes about a minute or two (AWS-stated,
     not measured here), during which `/health` fails and the ALB serves 503.
  3. **Both instances run the same release and need a coordinated deploy** (the current scripts handle one host). A bad release reaches both.
  4. The ALB is regional and spans two AZs, but there is no cross-region recovery. No ALB access logs, flow logs or alarms.
  5. Backups protect against bad data; a restore has **not** been rehearsed.

## 4. NAT Gateway
The NAT Gateway is the selected way for private subnets to reach the internet.

| | Staging | Production |
|---|---|---|
| Gateways | **one**, in the first AZ | **one per Availability Zone** (`nat_per_az`, checked) |
| Application subnet routes through | that one gateway | the gateway **in its own AZ**: no cross-AZ NAT routing |
| Outbound if one AZ fails | lost (single point of failure) | kept for the surviving AZ |
| Why | cost optimisation | production availability |

The routing is visible in the outputs `nat_gateway_ids` and `app_subnet_nat_az` (for each AZ, the AZ whose gateway it uses; in production each maps to
itself). Route tables are per AZ and tagged with the NAT AZ they use. Production cannot be planned with `nat_per_az = false` (precondition).

**Trade-off:** one more NAT Gateway, Elastic IP and public IPv4 address for production, roughly **$37 to $45 a month** more (estimate; section 12), in exchange
for AZ-independent outbound connectivity. A single NAT Gateway is **not** multi-AZ NAT and is never described as such here.

The instances need outbound HTTPS (443; 80 for apt mirrors) to:

| Service | Why |
|---|---|
| `ssm`, `ssmmessages`, `ec2messages` (regional endpoints) | Systems Manager agent registration, sessions and Run Command |
| ECR API and ECR registry (`api.ecr`, `dkr.ecr`) and Amazon S3 | `docker pull` (image layers are served from S3), and reading the deployment artifacts |
| `secretsmanager` | the backend's runtime secret read (AWS SDK) |
| `kms` (only with customer-managed keys) | decrypt of secrets, ECR images or artifacts |
| Ubuntu mirrors, container base-image registries | packages at boot, any non-ECR images |

VPC interface endpoints are an alternative for the AWS services only; they would not replace the NAT Gateway while packages and base images come from
the internet. They are **not** configured (NAT was the decision).

**First-boot ordering (TF-01).** Each instance is created only after the NAT Gateways, the application route-table associations and the SSM policy attachment
exist (`depends_on` on `aws_instance.app`), and its boot script retries its network calls (`apt-get update` for up to five minutes) and writes
`/var/lib/shopnest/bootstrap-complete` when finished, or `/var/lib/shopnest/bootstrap-failed` with the failing line. The deploy tooling must check for the
complete marker. Recovery from a failed boot: re-run the script from an SSM session (cloud-init keeps it under `/var/lib/cloud/instance/scripts/`), or replace
the instance with `terraform apply -replace` (needs approval). Instances ignore later boot-script and image changes, so this applies to new instances only.

## 5. RDS PostgreSQL
| Setting | Value |
|---|---|
| Engine | PostgreSQL **16** (major; RDS picks its current default minor, which then moves with automatic minor upgrades and is ignored by Terraform). Matches CI and local development. Confirm available minors with `aws rds describe-db-engine-versions` before the first apply (not done: no AWS access) |
| Class / storage | `db.t4g.micro` (staging), `db.t4g.small` (production); gp3, 20 GiB / 50 GiB, autoscaling limit configurable |
| Access | `publicly_accessible = false`, private DB subnet group, port 5432, TLS enforced. Hard-coded, not variables |
| Encryption | always on (AWS-managed key, or `rds_storage_kms_key_id`); not a variable |
| Multi-AZ | `rds_multi_az`: off for staging, on for production |
| Backups | automated; `rds_backup_retention_days` 1 to 35 (never 0); staging 1, production 7; point-in-time recovery within the window |
| Deletion protection | on for production (cannot be turned off: precondition); a final snapshot is required for production. Taking production RDS out of service needs a reviewed code change: see "Production RDS Decommission Procedure" |
| Final snapshot name | `<project>-<environment>-final-<suffix>` (for example `shopnest-production-final-1`); the suffix and the complete name are validated against the RDS naming rules (see the procedure below) |
| Credentials | **none in Terraform.** `manage_master_user_password = true`: RDS generates the master password and keeps it in Secrets Manager. State and outputs hold only the secret's ARN |

**Single-AZ vs Multi-AZ:** Multi-AZ adds a synchronous standby in another AZ with automatic failover and roughly **doubles** instance and storage cost.
It protects against an instance or AZ failure, not against bad data, a bad migration or deletion; backups do. Single-AZ is cheaper and is down until RDS
recovers or you restore.

## Production RDS Decommission Procedure
**This section is documentation only.** Nothing in it has been run. Deletion protection has not been disabled, no production variable has been changed to permit
deletion, and `terraform destroy` has not been run. It describes how decommissioning production RDS is meant to be done; it does not authorise it.

**Why a code change is needed.** Production RDS has `deletion_protection = true`, and a precondition in `rds.tf` ("Production RDS must have deletion protection
enabled") refuses any production configuration that turns it off. So the protection cannot be lifted with a variable change; a reviewed change to the Terraform
configuration is required, by design. The same file also requires production to take a final snapshot (`rds_skip_final_snapshot = false`).

**What the configuration provides for the final snapshot.** The snapshot is named `<project>-<environment>-final-<rds_final_snapshot_suffix>`, default
`shopnest-production-final-1`. A snapshot name can be used only once, so the suffix must be new for each deletion. The suffix variable and the complete name are
checked against the RDS rules for a final snapshot identifier (DeleteDBInstance, `FinalDBSnapshotIdentifier`): 1 to 255 characters; letters, digits and hyphens;
the first character a letter; no trailing hyphen; no two consecutive hyphens. The suffix must be letters and digits with single hyphens between groups; the length
limit applies to the complete name (the suffix can be at most 229 characters for production with the default project name); the first-letter rule is checked on the
complete name at plan time. The AWS wording says "letters or numbers" while the other rules imply hyphens inside the name are allowed; the existing naming convention
relies on that, so confirm it during the staging rehearsal. For production, automated backups are kept after the instance is deleted (`delete_automated_backups = false`).

**What is not known yet (needs a controlled validation before production use).**
- Whether Terraform evaluates the resource preconditions (the deletion-protection, Multi-AZ and snapshot checks) in a destroy-only plan. **This has not been tested.**
  The exact mechanism (change then apply then destroy, or removing the resource from the configuration) must be rehearsed on staging with equivalent guardrails first.
- Whether the change to `deletion_protection = false` takes effect without `rds_apply_immediately = true`. Confirm that the instance reports protection disabled before any
  delete step; do not assume it.
- Whether only the database is decommissioned or the whole production stack. The rest of the stack has its own protections (ALB deletion protection, ECR repositories
  with images, a non-empty artifact bucket) that must each be handled on purpose; that is a separate decision.
- What happens to the RDS-managed master secret when the instance is deleted (it is expected to be removed with the instance; verify), and the application's own
  database secrets (`shopnest/production/...`), which were created outside Terraform and must be retired by hand.

**Procedure** (each step needs a recorded owner; stop if any check fails):
1. **Approval and change record.** The owner approves the decommission in writing, with a change record that states the reason, the date, the expected data loss
   after the final snapshot, who may execute it and who verifies it. Plan the application outage first; take the application out of service so there are no writes.
2. **Confirm the target.** In the `production` Terraform workspace, with the `devops` profile and not root, confirm the account (your untracked `allowed_account_ids`),
   region `ap-south-1`, environment `production` and the instance identifier (`<project>-production-pg`; `shopnest-production-pg` by default), for example with read-only
   `aws sts get-caller-identity` and `aws rds describe-db-instances --db-instance-identifier <identifier>`. Check status, `DeletionProtection`, Multi-AZ, and that it is not publicly accessible.
3. **Confirm a recent restorable backup.** Check that automated backups exist inside the 7-day retention window (`aws rds describe-db-instance-automated-backups`) and
   that a recent restore point is available. Consider taking an extra manual snapshot immediately before the outage window, with its own name.
4. **Choose and check the final snapshot identifier.** Pick a new `rds_final_snapshot_suffix` that has never been used (list existing snapshots with
   `aws rds describe-db-snapshots` and confirm the complete name `<project>-production-final-<suffix>` is absent). Decide how long the snapshot is kept
   (a final snapshot is a manual snapshot and stays until someone deletes it) and who owns that retention. Note that snapshots of this encrypted database use its KMS key, so the key must
   stay available for any later restore.
5. **Review deletion protection and the precondition.** Read the production deletion-protection precondition and `deletion_protection` in `rds.tf`, and decide exactly which
   lines change. Do not change them as part of this documentation task.
6. **Make the reviewed configuration change.** In a branch and pull request that follows the repository rules (feature branch, reviewed, CI green, gitleaks clean), make the minimal change that
   permits decommissioning: relax the production deletion-protection precondition for this change, and set `rds_deletion_protection = false` in your untracked production
   variable file, together with the new snapshot suffix. Keep `rds_skip_final_snapshot = false`. The change record links the pull request.
7. **Review the Terraform plan carefully before any destroy.** Run a real `terraform plan` (approved, authenticated) in the `production` workspace and read every line: only
   the intended resources change; the DB instance shows `deletion_protection` going to false (and later the destroy), `skip_final_snapshot` is false, and the final snapshot
   identifier is the expected name. Any resource you did not intend to touch is a stop. Apply the protection change first, then confirm with `describe-db-instances` that
   protection is off.
8. **Confirm the final snapshot will be retained.** Before the delete, re-read the plan or configuration: `skip_final_snapshot = false`, the snapshot name is new and valid, and retention ownership is agreed.
9. **Execute the approved operation** through the authorised process only (an explicit approval in that session; the CI workflow never applies or destroys). Do the delete as one
   controlled step, watch for errors, and do not retry blindly: a failed delete can leave a snapshot behind that blocks reusing the same name.
10. **Verify the final snapshot exists and is restorable.** Confirm with `aws rds describe-db-snapshots --db-snapshot-identifier <name>` that it is `available`, encrypted, the expected size and
    engine version, and that the creation time matches the deletion. Prove restorability with a test restore into a temporary, private, small instance (not publicly
    accessible), check the data, then delete the test instance; that test has its own cost and needs its own approval.
11. **Record the evidence.** Record the final snapshot identifier, the time, its status, the retention owner, the restore-test result, the pull request and plan reviewed, who
    approved and who executed. Store it without account IDs, credentials, endpoints or secret values. Retire the application secrets and update the status documents.

**Stop conditions:** wrong account, region, workspace or instance; no recent restore point; a snapshot name that already exists or fails validation; a plan that touches anything
unexpected; protection not confirmed off before the delete; no approval on record.

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
| NAT Gateway | 1 (cost optimisation, outbound SPOF) | **1 per AZ**, each AZ routes through its own (enforced) |
| ALB deletion protection | off by default (clean teardown) | on by default; set false first to decommission |
| RDS Multi-AZ | off | on (enforced: precondition) |
| ECR retention | newest 30 | newest 50 |

## 12. Estimated monthly cost (USD, 730 h, Mumbai) — APPROXIMATE
**Estimates with stated assumptions, not quotes.** The AWS pricing API could not be queried (no authentication was allowed) and public pages showed no Mumbai
rates, so ranges come from general list prices; only the public IPv4 charge ($0.005 per address-hour) was confirmed from an AWS-sourced page. Confirm
with the AWS Pricing Calculator (Asia Pacific, Mumbai).

| Item (assumption) | A. Staging | B. Production (NAT per AZ, the approved design) |
|---|---|---|
| ALB (about $0.0225 to $0.027 per hour, about 1 LCU) | $22 to $26 | $22 to $28 |
| EC2 `t3.small` (about $0.021 to $0.025 per hour) | 1 instance: $15 to $18 | 2 instances: $30 to $36 |
| EBS gp3 root, 20 GiB each | $2 | $3 to $4 |
| RDS instance (A: `db.t4g.micro` single-AZ; B: `db.t4g.small` Multi-AZ, about 2x single) | $13 to $17 | $52 to $67 |
| RDS storage (A: 20 GiB; B: 50 GiB billed twice) | $3 | $13 to $15 |
| RDS backup storage (A: 1 day within the free allowance; B: 7 days) | $0 | $2 to $6 |
| NAT Gateway(s) (about $0.045 to $0.056 per hour each) plus data processing | $33 to $42 (1 gateway, 10 GB) | $70 to $88 (2 gateways, 50 GB) |
| Public IPv4 at $0.005 per hour (ALB 2 + each NAT 1) | $11 (3) | $14 (4) |
| ECR (storage about $0.10 per GB-month; scan on push, basic) | $1 | $1 to $2 |
| Secrets Manager (about 2 secrets per environment; per-secret price is an assumption) | $1 | $1 |
| S3 deployment artifact bucket (a few small, versioned objects; requests negligible) | $0 to $1 | $0 to $1 |
| VPC endpoints | not used | not used |
| Data transfer, cross-AZ, misc. | $1 to $3 | $3 to $8 |
| **Approximate total** | **about $102 to $125** | **about $211 to $270** |

Both environments running (A + B): about **$313 to $395 a month**. The production NAT-per-AZ decision adds roughly $37 to $45 a month over a single NAT Gateway
(one gateway, Elastic IP and IPv4 address). Fixed costs run whether or not anyone uses the stacks; tear staging down between sessions (with approval).
CloudWatch logs and alarms, VPC Flow Logs, a Route 53 zone and Patch Manager are deferred to Phase 4.4 and are **not** in these figures.

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
| Account and identity guard | `allowed_account_ids` (untracked, required) on the provider; the VPC refuses to run as the AWS root user |
| Artifact bucket | all public access blocked, ACLs disabled, encrypted, versioned, TLS 1.2 or higher only, no Allow statement in the bucket policy, read-only instance access to one prefix |
| Production guardrails | Multi-AZ RDS, deletion protection (RDS and ALB), NAT per AZ, two instances in two AZs, 7-day backups and a final snapshot |
| Gitleaks | no findings: no account IDs, CIDRs or secrets in tracked files; also run by the Terraform CI workflow |
| Not verifiable without AWS | a real plan and resource count, availability of the instance class and engine version, quotas, IAM evaluation |

## 8a. Deployment artifact bucket
A private S3 bucket **per environment** (`<project>-<environment>-artifacts-<account>-<region>`) for **future** deployment scripts and configuration. Application
images go to ECR; this is for small files (deploy scripts, nginx configuration, frontend files). Defined in `artifacts.tf`; **nothing is created or uploaded**, no
workflow uses it yet, and the identity that will publish to it (CI/deploy role) does not exist yet.

| Property | Setting |
|---|---|
| Public access | all four block settings on; ACLs disabled (bucket-owner enforced); the bucket policy contains **only Deny** statements, so it can never make the bucket public |
| Encryption | every object encrypted at rest: S3-managed AES-256, or `artifacts_kms_key_arn` (then the instance role may decrypt through S3 only) |
| Versioning | on: an overwritten or deleted script can be recovered and an earlier release restored |
| Transport | requests over plain HTTP, or below TLS 1.2, are denied for every principal |
| Retention | current versions kept; noncurrent versions expire after `artifact_noncurrent_retention_days` (90) but the newest `artifact_noncurrent_versions_kept` (5) always stay; incomplete uploads removed after 7 days; orphaned delete markers cleaned |
| Instance access | IAM, read-only, to one prefix (`artifact_prefix`, default `deploy/`): `GetObject`, `GetObjectVersion`, and `ListBucket` limited to that prefix. No write, no delete, nothing else in the bucket |
| Publishing | later, by the CI/deploy role through its own identity policy limited to `PutObject` on that prefix (Phase 4.3). Not granted to anyone now |
| Deletion | `force_destroy = false`: a bucket that holds objects cannot be destroyed silently |

Not configured here (Phase 4.4 logging scope): S3 server-access logging, CloudTrail data events and replication. Because access is by IAM and the policy has no
Allow, an administrator cannot be locked out by it.

## 14. Terraform CI workflow
`.github/workflows/terraform-ci.yml` ("Terraform CI") checks the infrastructure code without touching AWS.

| Item | Behaviour |
|---|---|
| Triggers | pull requests to `main` and pushes to `main`, only when `infra/terraform/**` or the workflow itself changes |
| Permissions | `contents: read` for the workflow and each job; no secrets, no variables, no cloud role |
| Job "Terraform fmt and validate" | checks no state, plan or variable file is tracked; `terraform fmt -check -recursive`; `terraform init -backend=false -lockfile=readonly`; `terraform validate`. Terraform is pinned to 1.17.1 through `hashicorp/setup-terraform` pinned by commit |
| Job "Terraform secret scan" | installs gitleaks 8.30.1 after verifying its SHA-256, scans `infra/`, the workflow file and the full Git history with the repository's `.gitleaks.toml` (including its IP-address and EC2-hostname rules) |
| Never runs | `plan`, `apply`, `destroy`, `import`, any state command, any AWS call |
| Existing CI | `ci.yml` is unchanged and unaffected |

`-lockfile=readonly` makes the job fail instead of changing `.terraform.lock.hcl`, which proves the committed lock file (now carrying hashes for Windows, Linux and
macOS) covers the runner. The workflow has not run on GitHub yet. The two job names are suitable for branch protection later, but the workflow is path-filtered, so
they must not be made required until a same-named pass-through job exists for pull requests that do not touch these paths.

## Open decisions
1. ECR repository per environment (implemented) vs one shared repository.
3. Whether to mitigate the hop-limit-2 exposure (block metadata for non-backend containers, or run the backend with host networking).
4. Whether migrations run from the instance (then `db-owner` must be added to `db_secret_names`).
5. SSM Run Command vs the assignment's "deployment over SSH" wording: confirm with the instructor.
6. Remote Terraform state (approved, Phase 4.4): bucket, locking, per-environment separation.
7. Publisher identity for the artifact bucket and the deployment workflow (Phase 4.3), and which instance-side tool reads the artifacts.
8. Production domain and ACM certificate (approved, Phase 4.4); until then production serves plain HTTP.
