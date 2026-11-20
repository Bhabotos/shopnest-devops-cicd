# Terraform architecture and security review (Phase 4.1)

Read-only review of `infra/terraform/` at commit `cbffa6ac7f53a18bac452a174b18422c0c8f8ecf` on branch `feature/terraform-aws-infra`, with the
existing CI/CD and deployment code on the same commit. **No AWS access, no `terraform plan` and no change to any existing file was used or made.**
Nothing below is marked fixed: the repository was not changed. Items that could not be verified without AWS or network access are labelled
"verify". Prices are estimates, not quotes.

## 1. Executive summary
The configuration is internally consistent, validates, and is clean on secrets: private RDS with no password in code, no inbound SSH, private
application instances, encrypted storage, scoped IAM, immutable scanned ECR repositories and production guardrails enforced by preconditions. The
infrastructure itself is close to plannable.

**The application and its deployment code are not.** None of the existing deployment path works against this architecture (SSH workflows, `docker
save` and `scp`, a database container, a `secrets.env` file, a backend that reads one connection URL with no TLS or AWS SDK), and nothing
creates the database roles on RDS. Three further items are infrastructure-side: instances can race the NAT Gateway at first boot, production would
serve plain HTTP, and Terraform state is local.

| Severity | Count |
|---|---|
| Critical | 3 |
| High | 8 |
| Medium | 26 |
| Low | 12 |
| **Total** | **49** |

14 findings are marked as blocking deployment (some only for production or for CD). **Top deployment blockers:**
1. **INT-01** SSH-based workflows cannot reach private instances.
2. **INT-02** Backend has no AWS SDK secret retrieval and no TLS to RDS.
3. **RDS-01** Database roles are not bootstrapped and migration 003 would silently skip the grants.
4. **INT-05 / INT-03** The delivery of scripts and images to the instances (ECR digest flow, script distribution) is undecided and unimplemented.
5. **TF-01** Instances can boot before the NAT route exists, leaving a half-configured host.

Production-only blockers: **ALB-01** (HTTP only), **ST-01** (local state), **INT-06** (two-host rolling deploy and one-time migrations), **ST-04** (no CI identity).

## 2. Architecture assessment
**What the code gets right (verified in the files):**

| Check | Evidence |
|---|---|
| Two AZs, three subnet tiers, IGW, NAT, route tables | `networking.tf`; database route table has no default route |
| No public IP on instances; subnets do not auto-assign | `compute.tf` `associate_public_ip_address = false`; `map_public_ip_on_launch = false` |
| RDS private, encrypted, backed up, TLS required | `rds.tf` (`publicly_accessible = false`, `storage_encrypted = true`, `rds.force_ssl = 1`, retention 1 to 35) |
| 5432 only from the application group; no CIDR rules for the database | `security.tf`; the only CIDR-sourced inbound rules are the ALB's, from a required variable |
| No port 22, no key pair, no sshd setup | no `22`, `key_name` or `aws_key_pair` in any `.tf`; boot script has no SSH configuration |
| IMDSv2 required; EBS encrypted | `compute.tf` `http_tokens = "required"`, `encrypted = true` |
| Production guardrails enforced, not just defaulted | `rds.tf` preconditions (deletion protection, 7-day backups, final snapshot); `compute.tf` (two instances in two AZs) |
| Staging cannot be open to the whole internet; ALB sources required | `compute.tf` `aws_lb` preconditions |
| Secrets scoped to named secrets; ECR pull scoped to own repositories | `iam.tf` (`-??????` name pattern; repository ARNs; one unavoidable `*` for `GetAuthorizationToken`) |
| ECR immutable, scan on push, encrypted, lifecycle, no force delete | `ecr.tf` |
| No credential, key, password, account ID or CIDR in tracked files | gitleaks clean; no AWS key or private-key patterns; the only 12-digit number is Canonical's public AMI publisher ID |
| No sensitive outputs | `outputs.tf` (ARNs, names, private identifiers only) |

**Terraform structure review:**
- *Providers and versions:* Terraform `>= 1.17.1, < 2.0.0`, AWS provider `~> 6.0` locked at 6.73.0 (TF-04 on platform hashes).
- *Naming and tagging:* a consistent `<project>-<environment>-<role>` scheme and provider `default_tags` (Project, Environment, ManagedBy, Repository); no owner or cost-centre tag (minor).
- *Variables:* sensible validations (region, environment, backups, CIDR length, ports in the ECR names); gaps in TF-05.
- *Environment separation:* one root module deployed twice through workspaces and separate variable files; the workspace-equals-environment check is a good safety net (ST-03 on shared state).
- *Reusability:* a single flat root module (no child modules), appropriate for two stacks; resource-level `for_each` keeps AZ, ECR and instance counts configurable.
- *Dependencies:* implicit references are mostly right; TF-01 is the missing ordering.
- *`.gitignore` and examples:* state, plans, `.terraform/`, `*.tfvars` and workspace directories are ignored; the lock file is tracked; the two example files contain no CIDRs and are safe to commit (they are not plannable alone because `vpc_cidr` and `alb_allowed_cidrs` are deliberately absent).
- *Outputs:* nothing sensitive; the ALB DNS name is an output only (not written to files, per the live-URL rule).

Findings on Terraform structure and safety:

#### TF-01 — Instances can boot before the NAT route exists, so first-boot setup can fail permanently
- **Severity:** High
- **Reference:** `compute.tf` `aws_instance.app`; `networking.tf` `aws_nat_gateway.main`, `aws_route_table.app`, `aws_route_table_association.app`
- **Current behavior:** The instance references its subnet, security group and instance profile only. Nothing orders it after the NAT Gateway, the application route table or its association. `user_data` runs once, starts with `apt-get update` under `set -euo pipefail`, and `ignore_changes = [ami, user_data]` guarantees it is never re-run.
- **Risk / impact:** A NAT Gateway takes minutes to become available. If the instance boots first, the script aborts part-way: no Docker, no `deploy` user, no CA bundle. The instance still shows as running (and may register with Systems Manager), so the failure stays silent until the first deploy.
- **Recommended remediation:** Add `depends_on = [aws_route_table_association.app, aws_nat_gateway.main]` to the instance; add retries around the first network calls and a completion marker that the deploy tooling checks; document the recovery (replace the instance).
- **Blocks deployment:** Yes (first-boot reliability)

#### TF-02 — RDS storage autoscaling causes permanent plan drift and a failing apply
- **Severity:** Medium
- **Reference:** `rds.tf` `aws_db_instance.main` (`allocated_storage`, `max_allocated_storage`)
- **Current behavior:** `allocated_storage` comes from a variable and is not in `ignore_changes`.
- **Risk / impact:** After RDS autoscales storage up, the next plan tries to set the smaller configured value. RDS cannot shrink storage, so the apply fails or the plan stays dirty.
- **Recommended remediation:** Add `allocated_storage` to `ignore_changes`; validate `max_allocated_storage` is greater than `allocated_storage` (or null).
- **Blocks deployment:** No

#### TF-03 — Nothing prevents applying to the wrong AWS account or with a root identity
- **Severity:** Medium
- **Reference:** `provider.tf`; `iam.tf` `data.aws_caller_identity.current` (used only to build ARNs)
- **Current behavior:** The provider uses aws_profile (default). The profile name is not constrained to a non-root identity. There is no allowed_account_ids and no check that the caller is not root.
- **Risk / impact:** A changed profile variable could plan or apply against another account (for example another project's account) or with root credentials, breaking the project hard rule on root credentials.
- **Recommended remediation:** Add `allowed_account_ids` supplied from an untracked variable (not hard-coded in tracked files) and a precondition that the caller ARN does not end in `:root`.
- **Blocks deployment:** No (do before the first plan)

#### TF-04 — Lock file records one platform hash
- **Severity:** Low
- **Reference:** `.terraform.lock.hcl`
- **Current behavior:** One `h1:` hash (the platform where `init` ran, Windows) plus `zh:` archive hashes.
- **Risk / impact:** Running `init` on Linux (a CI runner) may warn about incomplete lock information and add hashes at run time, which is not reproducible.
- **Recommended remediation:** `terraform providers lock -platform=windows_amd64 -platform=linux_amd64 -platform=darwin_arm64` and commit the result.
- **Blocks deployment:** No

#### TF-05 — Variable validation gaps
- **Severity:** Low
- **Reference:** `variables.tf` (`alb_allowed_cidrs`, `app_port`, `instance_type`, `rds_storage_type`, `rds_max_allocated_storage_gb`)
- **Current behavior:** `alb_allowed_cidrs` is not checked to be valid CIDRs; `app_port` has no range; `io1` storage is accepted although no IOPS argument exists; the autoscaling ceiling is not compared with the allocation.
- **Risk / impact:** Mistakes surface as apply-time API errors, or as an unintended source range on the ALB.
- **Recommended remediation:** Validate CIDR syntax (`can(cidrhost(...))`) and reject IPv6 or empty strings; range-check `app_port`; drop `io1` or add `iops`; compare storage values.
- **Blocks deployment:** No

#### TF-06 — Fixed final-snapshot name collides on a second delete
- **Severity:** Low
- **Reference:** `rds.tf` `final_snapshot_identifier = "<name>-final"`
- **Current behavior:** The identifier is constant.
- **Risk / impact:** Deleting and recreating a database (staging, or production after protection is lifted) fails the second time because the snapshot already exists.
- **Recommended remediation:** Add a timestamp or a `-final-<n>` suffix through a variable, or document renaming the old snapshot first.
- **Blocks deployment:** No


## 3. Security findings
**Secrets and encryption scan (all files under `infra/terraform/`):** no hard-coded credential, password, access key or private key; no account ID in source
(IAM policies obtain it at plan time through a data source, so it appears in state and plans, not in files); no sensitive output; no secret in
`user_data`; EBS, RDS and ECR encrypted at rest; gitleaks clean and its configuration untouched.

Security-relevant findings (details in the sections that follow):

| ID | Severity | Topic |
|---|---|---|
| IAM-01 | Medium | IMDS hop limit 2 exposes the role credentials (and user data) to every container |
| IAM-02 | Medium | AWS-managed SSM policy is broad (verify its contents) |
| TF-03 | Medium | No guard against the wrong account or a root identity |
| NET-04 | Medium | No flow logs, ALB access logs or WAF |
| IAM-03 | Medium | No logging, alarms or session audit |
| RDS-02 | Medium | No safe channel for using the master secret during bootstrap |
| RDS-05 | Medium | Application database credentials are static |
| ALB-01 | High | Production would run over plain HTTP with checkout data |
| ST-01 | High | Unlocked, unversioned local state |
| IAM-05 / IAM-06 | Medium | No patching process; unrotated Docker logs and image accumulation |
| NET-03, IAM-04 | Low | Open outbound 80 and 443; the deploy-user model is not enforced |

## 4. Networking findings
Verified correct: two AZs; public, application and database tiers; IGW; NAT; separate route tables with the database tier unrouted; security groups
reference each other instead of CIDRs except on the ALB; the ALB is the only internet-facing component; instances have no public address; no
inbound SSH; no public PostgreSQL port; the default security group is emptied; the database group has no outbound rules. Outbound access from the
application group is limited to 443, 80 and 5432 to the database group.

**Single points of failure:** one NAT Gateway (NET-01); one application instance in staging (by design); one region; the ALB and RDS endpoints are
regional services but depend on the AZ placement chosen.

#### NET-01 — A single NAT Gateway is an outbound single point of failure in both environments
- **Severity:** Medium
- **Reference:** `networking.tf` `aws_nat_gateway.main`; `variables.tf` `nat_per_az` (default false); `staging.tfvars.example`, `production.tfvars.example` (both false)
- **Current behavior:** One gateway in the first AZ serves every private subnet; all application route tables point at it.
- **Risk / impact:** If that AZ fails, instances in the other AZ keep serving through the ALB but lose outbound access: no Systems Manager sessions or deploys, no ECR pulls, no Secrets Manager reads. A backend that restarts then cannot fetch its database secret. In production this undermines the two-AZ design. Cross-AZ NAT traffic is also billed.
- **Recommended remediation:** Accept explicitly for staging (cost optimisation, as documented). For production decide between `nat_per_az = true` (about one more gateway) and acceptance; document the decision. Do not describe production as multi-AZ for outbound traffic.
- **Blocks deployment:** No (needs an explicit decision before production)

#### NET-02 — All image and layer downloads cross the NAT; Docker Hub is an unmanaged dependency behind one shared address
- **Severity:** Medium
- **Reference:** `networking.tf` (no S3 gateway endpoint); `deploy/docker-compose.prod.yml` (nginx image from Docker Hub)
- **Current behavior:** ECR image layers are served from S3 and travel through the NAT Gateway. The production Compose file pulls the nginx image from Docker Hub, anonymously, through the single NAT address.
- **Risk / impact:** NAT data-processing cost grows with every deploy and instance. Anonymous Docker Hub pulls from one shared address can be rate-limited, and Hub availability becomes a deploy dependency.
- **Recommended remediation:** Add a free S3 gateway endpoint (a supplementary endpoint; needs approval because NAT was the stated decision). Mirror the nginx image into this environment's ECR repository and pull it from there.
- **Blocks deployment:** No (may surface at the first deploy)

#### NET-03 — Instances may reach any host on 443 and 80
- **Severity:** Low
- **Reference:** `security.tf` `aws_vpc_security_group_egress_rule.app_https_out`, `app_http_out`
- **Current behavior:** Outbound 443 and 80 are open to any destination, which is required while the services used have no fixed addresses.
- **Risk / impact:** A compromised container could exfiltrate data to any host.
- **Recommended remediation:** Accept for now; add DNS-level or proxy egress filtering only if the threat model needs it. VPC Flow Logs (NET-04) give visibility.
- **Blocks deployment:** No

#### NET-04 — No network or request logging, and no WAF
- **Severity:** Medium
- **Reference:** `networking.tf` (no flow logs); `compute.tf` `aws_lb.main` (no access logs)
- **Current behavior:** No VPC Flow Logs, no ALB access logs, no AWS WAF.
- **Risk / impact:** No evidence trail for an incident and no filtering of common web attacks on the internet-facing ALB. Part of this is the cost of a log bucket or log group.
- **Recommended remediation:** Enable ALB access logs to a private, encrypted S3 bucket and flow logs for the production VPC; consider a WAF managed rule set for production.
- **Blocks deployment:** No (production should not go live without logging)


## 5. IAM and EC2 findings
Staging and production share one definition: the same role policy shape, separated only by name and by the secret and ECR repository they are scoped
to (the secret path contains the environment, so staging's role cannot read production's secret, and each environment has its own repositories).
Production's two instances share one role and one security group, so a compromise of one host is a compromise of the role for both. KMS
permissions are not needed with the default AWS-managed keys; `kms:Decrypt` is added only if a customer key is configured, restricted to use through
Secrets Manager. IMDSv2 is enforced (hop limit discussed in IAM-01). EBS volumes are encrypted. `t3.small` with a 20 GiB root volume is a reasonable
starting size now that the database is off the host (confirm memory during a deploy, when four backend containers can run).

#### IAM-01 — IMDS hop limit 2 lets any container read the instance role credentials; user data is readable the same way
- **Severity:** Medium
- **Reference:** `compute.tf` `metadata_options`; `variables.tf` `imds_hop_limit` (default 2)
- **Current behavior:** IMDSv2 is required, but the hop limit is 2 so the backend container's AWS SDK can reach the metadata service. The role holds Systems Manager core, ECR pull and one secret.
- **Risk / impact:** Any process in any container on the host (for example through a server-side request forgery in the app) can obtain the role's credentials and the boot script text. This reverses the earlier hardening and was a consequence of the "SDK at runtime" decision.
- **Recommended remediation:** Choose a mitigation: block metadata for every container except the backend (host firewall rule on the Docker bridge), run the backend with host networking, or accept it given the role size. Keep `user_data` free of secrets (it is today).
- **Blocks deployment:** No (decision needed)

#### IAM-02 — The AWS-managed SSM instance policy is broad
- **Severity:** Medium
- **Reference:** `iam.tf` `aws_iam_role_policy_attachment.ssm_core`
- **Current behavior:** The role carries `AmazonSSMManagedInstanceCore`. As documented by AWS it grants several Systems Manager read actions on all resources (including parameter reads). The current policy text was not retrieved (no AWS access); verify in the console.
- **Risk / impact:** Combined with IAM-01, a stolen credential can read Parameter Store data in the account, which may include other projects' parameters.
- **Recommended remediation:** Replace with a custom policy listing only the actions the agent needs, or confirm the managed policy contents and accept the exposure; keep other projects' parameters out of this account or protect them with resource-based conditions.
- **Blocks deployment:** No

#### IAM-03 — No logging, CloudWatch permissions, alarms or session audit
- **Severity:** Medium
- **Reference:** `iam.tf` (no logs permissions); `user_data.sh.tftpl`; no `aws_cloudwatch_*` resources
- **Current behavior:** The role has no CloudWatch Logs permissions and no agent is installed; no alarms exist; Session Manager logging is not configured.
- **Risk / impact:** Container and host logs stay on the instance and are lost with it; nobody is alerted to unhealthy targets, CPU, disk or RDS problems; administrative sessions and commands are visible only through CloudTrail, which this stack does not configure.
- **Recommended remediation:** Add a log group per environment, minimal `logs:*` permissions for the agent or log driver, alarms for target health, instance status, disk and RDS metrics, and Session Manager logging. Budget the cost.
- **Blocks deployment:** No (staging); production should not go live without it

#### IAM-04 — The "deploy" service user is not actually what runs deploys, and docker-group membership is root-equivalent
- **Severity:** Low
- **Reference:** `user_data.sh.tftpl` (`deploy` user, `docker` group, comment about the Systems Manager document)
- **Current behavior:** The comment says the deploy document runs commands as `deploy`. SSM Run Command runs as root unless the command itself uses `sudo -u`. The CA bundle is also downloaded without a checksum.
- **Risk / impact:** The least-privilege intent is not enforced; `deploy` in the `docker` group can become root anyway; a tampered download is possible in principle (HTTPS to an AWS host).
- **Recommended remediation:** Decide the real execution model (root through the managed document, or an explicit `sudo -u deploy`), correct the comment, and verify the CA bundle fingerprint against the AWS documentation.
- **Blocks deployment:** No

#### IAM-05 — No operating-system patching process
- **Severity:** Medium
- **Reference:** `compute.tf` `ignore_changes = [ami, user_data]`; no Patch Manager resources
- **Current behavior:** Hosts are never replaced for a new AMI and nothing patches them on a schedule (Ubuntu security updates may apply automatically, kernel reboots do not).
- **Risk / impact:** Long-lived hosts accumulate vulnerabilities; two production hosts drift apart.
- **Recommended remediation:** Define patching: Systems Manager Patch Manager with a maintenance window, or periodic instance replacement behind the ALB (rolling).
- **Blocks deployment:** No (production)

#### IAM-06 — Docker logs are not rotated and old images accumulate on a 20 GiB disk
- **Severity:** Medium
- **Reference:** `user_data.sh.tftpl` (no `daemon.json`); `variables.tf` `root_volume_size_gb` (20)
- **Current behavior:** No log-rotation options and no image pruning. The deploy scripts deliberately keep old backend images for rollback.
- **Risk / impact:** The root volume can fill and take down the host; with ECR retention of 30 or 50 images the host can hold far more than it needs.
- **Recommended remediation:** Set `log-driver` options (size and file count) in `/etc/docker/daemon.json`; add a prune step that keeps the live and previous release; alarm on disk usage.
- **Blocks deployment:** No

#### IAM-07 — Burstable instances default to unlimited CPU credits
- **Severity:** Low
- **Reference:** `compute.tf` `aws_instance.app` (no `credit_specification`)
- **Current behavior:** T3 instances launch in "unlimited" mode by default.
- **Risk / impact:** Sustained load incurs surplus-credit charges; the cost cap in the estimates assumes baseline use.
- **Recommended remediation:** Set `credit_specification { cpu_credits = "standard" }` for staging, or monitor CPU credit balance.
- **Blocks deployment:** No


## 6. RDS findings
Verified: private DB subnet group across two AZs; not publicly accessible; encryption at rest; automated backups with 1 to 35 days (production at least
7); deletion protection and a final snapshot enforced for production; Multi-AZ configurable (on in the production example, off for staging); gp3 storage
with an autoscaling ceiling; a parameter group requiring TLS; PostgreSQL 16 (matches CI and development); master credentials generated by RDS and held in
Secrets Manager, never in Terraform source, outputs or example files; the database security group admits only the application group.

**Role bootstrap and migrations:** the repository does **not** implement either for RDS. `shopnest_owner` and `shopnest_app` are created only by the
local Compose init script; migration 003 tolerates the absence of `shopnest_app`; the migration runner takes no database lock. The design can support
the two roles safely only after RDS-01 and RDS-02 are done and verified; the local 62-check privilege verification does not apply to RDS.

#### RDS-01 — The database roles are not bootstrapped, and the migrations would silently skip their grants
- **Severity:** Critical
- **Reference:** `deploy/db/init/01-roles.sh` (local Compose only); `backend/migrations/003_app_role_grants.sql`; `rds.tf`
- **Current behavior:** On RDS nothing creates `shopnest_owner` or `shopnest_app`. Migration 003 is written as a no-op when `shopnest_app` does not exist (so it passes everywhere). The RDS master user is `rds_superuser`, not a superuser, so parts of the init script (for example `ALTER DATABASE ... OWNER TO`, which requires membership of the target role) need verification. The repository does not implement any of this for RDS.
- **Risk / impact:** Migrations can "succeed" while the application role has no privileges, producing permission errors at runtime; or the application could be run with the master or owner credentials, which defeats the least-privilege design (which the local stack verified with 62 checks, none against RDS).
- **Recommended remediation:** Write and test an operator bootstrap for RDS (roles, ownership, revokes, `GRANT shopnest_owner TO <master>` if needed) and a check that fails the deploy when `shopnest_app` is missing; re-run the privilege checks against RDS. Make the migration fail, not skip, on RDS.
- **Blocks deployment:** Yes

#### RDS-02 — No safe channel is defined for the operator who must use the master secret
- **Severity:** Medium
- **Reference:** `rds.tf` (master secret); `iam.tf` (instance role cannot read it); `user_data.sh.tftpl` (`psql` installed)
- **Current behavior:** The database accepts connections only from the application security group, so bootstrap must run from an instance. The instance role deliberately cannot read the master secret, so an operator would have to read it elsewhere and pass it into a session.
- **Risk / impact:** The master password could land in shell history, Session Manager logs or a terminal transcript.
- **Recommended remediation:** Define the procedure: for example an SSM document that takes the secret ARN, runs with a one-time role, and reads the value on the instance without echoing it; log only the outcome.
- **Blocks deployment:** Yes (for the first bootstrap)

#### RDS-03 — Production is not forced to be Multi-AZ
- **Severity:** Medium
- **Reference:** `variables.tf` `rds_multi_az` (default false); `rds.tf` (no precondition); `production.tfvars.example` sets true
- **Current behavior:** Only deletion protection, backup retention and the final snapshot are enforced for production. Multi-AZ is a default-off variable.
- **Risk / impact:** A production apply without the variable file value runs a single-AZ database while the documentation describes production as redundant.
- **Recommended remediation:** Default `rds_multi_az` to true for production (as done for deletion protection) or add a precondition; keep staging single-AZ.
- **Blocks deployment:** No (production)

#### RDS-04 — No database logs, monitoring or alarms
- **Severity:** Medium
- **Reference:** `rds.tf` (`performance_insights_enabled = false`; no log exports, no monitoring role, no alarms)
- **Current behavior:** Nothing exports PostgreSQL logs, and no alarm watches storage, CPU, connections or replica lag.
- **Risk / impact:** A full disk, a connection storm or slow queries go unnoticed; no audit of administrative access.
- **Recommended remediation:** Enable the PostgreSQL log export, basic CloudWatch alarms (free storage, CPU, connections), and consider Performance Insights for production.
- **Blocks deployment:** No (production)

#### RDS-05 — The application database credentials are static
- **Severity:** Medium
- **Reference:** `variables.tf` `db_secret_names`; `iam.tf`
- **Current behavior:** The master secret is RDS-managed; the `db-app` (and optional `db-owner`) secrets are created by hand and never rotated.
- **Risk / impact:** A leaked application password stays valid until someone notices.
- **Recommended remediation:** Define a rotation procedure (a rotation function or a documented manual cycle) and make the backend re-read the secret on authentication failure.
- **Blocks deployment:** No

#### RDS-06 — Engine version, disaster-recovery copies and default keys are unverified or minimal
- **Severity:** Low
- **Reference:** `variables.tf` `rds_engine_version = "16"`; `rds.tf` (default KMS keys; no snapshot copy)
- **Current behavior:** A major-only version is requested and the minor drifts with automatic upgrades; availability of the class and version in the region could not be checked. Default AWS-managed keys cannot share snapshots across accounts or regions; no copy exists outside the region.
- **Risk / impact:** The first apply may be rejected for an unavailable version or class; a regional failure has no database recovery path.
- **Recommended remediation:** Check `describe-db-engine-versions` and instance-class availability before the first apply; decide whether cross-region snapshot copy and a customer key are worth it.
- **Blocks deployment:** No

#### RDS-07 — Behaviour during a Multi-AZ failover has not been tested
- **Severity:** Medium
- **Reference:** `rds.tf` `multi_az`; `backend/src/db.js` (pool error handler, 5 s connect timeout); `backend/src/app.js` (`/health` runs `SELECT 1`)
- **Current behavior:** The backend handles idle-client errors and fails fast, and `/health` reports 503 when the query fails. Nothing has exercised a failover.
- **Risk / impact:** Expect a minute or two of failing database calls and failing health checks (see ALB-02). Whether the pool reconnects cleanly to the new primary is unproven.
- **Recommended remediation:** Rehearse a failover on staging (Multi-AZ temporarily on) and record the result before claiming it.
- **Blocks deployment:** No


## 7. ECR and ALB findings
**ECR:** immutable tags, scan on push, AES-256 or customer-key encryption, a two-rule lifecycle and pull-only access for the instance role are
configured. Tag immutability prevents re-pointing a version tag, but the deployment code does not use digests (ECR-01), so mutable-tag risk is reduced
rather than removed.

#### ECR-01 — Digest-based deployment is possible but not implemented
- **Severity:** Medium
- **Reference:** `ecr.tf` (immutable tags); `deploy/scripts/lib/bluegreen-lib.sh` (`shopnest-backend:<sha>` local tags, label check); `deploy/docker-compose.prod.yml`; `.github/workflows/cd.yml`
- **Current behavior:** ECR tags are immutable, which stops a tag from being re-pointed. The deploy path uses locally loaded images tagged with the commit SHA and verifies an image label; there is no registry digest anywhere.
- **Risk / impact:** Without recording and pulling by digest, the deployed bytes are not tied to what CI built and scanned.
- **Recommended remediation:** CI records the pushed digest; the deploy passes `repository@sha256:...` to SSM; the host pulls by digest and verifies the pulled digest and revision label; keep a digest history for rollback.
- **Blocks deployment:** Yes (for the ECR flow)

#### ECR-02 — Scan on push exists but nothing acts on the result
- **Severity:** Low
- **Reference:** `ecr.tf` `image_scanning_configuration`
- **Current behavior:** Basic scanning runs on push; no gate, no alert.
- **Risk / impact:** A vulnerable image can be deployed without anyone looking.
- **Recommended remediation:** Have the deploy workflow read the scan findings and fail above an agreed severity, or enable enhanced scanning if the cost is acceptable.
- **Blocks deployment:** No

#### ECR-03 — Lifecycle count, host disk and promotion are not aligned
- **Severity:** Low
- **Reference:** `ecr.tf` lifecycle rules, `force_delete = false`; `variables.tf` `ecr_keep_images`
- **Current behavior:** Only the newest 30 (staging) or 50 (production) images are kept; a repository with images cannot be destroyed silently; each environment has its own repository.
- **Risk / impact:** Rollback only reaches kept images; promotion to production needs an image copy; staging teardown needs images deleted first (by design).
- **Recommended remediation:** Document the rollback horizon, add the manifest-copy step to the promotion design, and record the digest of every deployed release.
- **Blocks deployment:** No


**ALB and availability:** listeners are HTTP (forward) or HTTPS (TLS 1.3/1.2 policy) with an HTTP redirect when a certificate is supplied; the target
group health check is `/health` through nginx; draining is 30 s. Staging has one target and no redundancy by design; production registers two instances
in two AZs. Nothing here demonstrates zero downtime (ALB-06).

#### ALB-01 — Production would serve over plain HTTP until a domain and certificate exist
- **Severity:** High
- **Reference:** `variables.tf` `acm_certificate_arn` (empty); `compute.tf` `aws_lb_listener.http_forward`; `backend/migrations/001_init.sql` (customer e-mail and shipping address columns)
- **Current behavior:** With no certificate the ALB listens on 80 and forwards. The HTTP-to-HTTPS redirect and TLS 1.3 policy exist but are inactive.
- **Risk / impact:** Checkout data (name-bearing e-mail and shipping address) would cross the internet unencrypted.
- **Recommended remediation:** Obtain a domain and an ACM certificate in ap-south-1 before production; set `acm_certificate_arn`; treat the HTTP-only configuration as test-data only. (The live-URL question to the instructor is still open.)
- **Blocks deployment:** Yes (production)

#### ALB-02 — The health check couples every target to the database
- **Severity:** Medium
- **Reference:** `compute.tf` `aws_lb_target_group.app` (`/health`); `backend/src/app.js` (`SELECT 1`); `deploy/nginx/nginx.conf` (`/health` proxies to the backend)
- **Current behavior:** A target is healthy only if its backend can query RDS. Both production targets depend on the same database.
- **Risk / impact:** A failover or a brief database problem turns both targets unhealthy at the same time, so the health check cannot protect production from a database outage. Note: as I understand ALB behaviour, when no target is healthy the ALB routes to all targets (fail-open), so users would see the application's own 503 on API calls rather than an ALB error, and static pages could still load; this should be confirmed on staging.
- **Recommended remediation:** Split liveness (process answers) from readiness (database) and point the target group at liveness; keep readiness for the deploy scripts and alarms.
- **Blocks deployment:** No

#### ALB-03 — The health path does not detect a broken frontend
- **Severity:** Low
- **Reference:** `compute.tf` health check path; `docs/evidence/bluegreen-local/attempt4-failure-analysis.md`
- **Current behavior:** The check calls `/health` only. In rehearsal attempt 4 a release without `index.html` returned HTTP 500 on `/` while `/health` stayed healthy.
- **Risk / impact:** An instance serving a broken page would stay in rotation.
- **Recommended remediation:** The deploy scripts now refuse such a release before switching; add a synthetic check of `/` to alarms if broader coverage is wanted.
- **Blocks deployment:** No

#### ALB-04 — A failed instance is not replaced automatically
- **Severity:** Medium
- **Reference:** `compute.tf` `aws_instance.app` (fixed instances; no Auto Scaling group, no recovery alarm)
- **Current behavior:** Production has two instances but nothing recreates a lost one.
- **Risk / impact:** After one failure production runs on a single instance until an operator intervenes, and the redundancy claim no longer holds.
- **Recommended remediation:** Add instance auto-recovery alarms, or move to an Auto Scaling group (minimum 2) with a launch template, which also changes how deploys and patching work.
- **Blocks deployment:** No (production)

#### ALB-05 — Production ALB deletion protection is not enforced
- **Severity:** Low
- **Reference:** `variables.tf` `enable_deletion_protection` (default false); `production.tfvars.example` omits it
- **Current behavior:** RDS has protection by default for production; the ALB does not.
- **Risk / impact:** A mistaken destroy removes the production entry point.
- **Recommended remediation:** Default it to true for production, as done for RDS.
- **Blocks deployment:** No

#### ALB-06 — Zero downtime and rolling updates are unproven on this architecture
- **Severity:** Medium
- **Reference:** `compute.tf` target group (`deregistration_delay = 30`); `deploy/scripts/` (per-host blue/green); `docs/evidence/bluegreen-local/`
- **Current behavior:** Blue/green runs inside each host: nginx switches backends, so the ALB should keep seeing a healthy target. All evidence is from a local Docker rehearsal with a local database; nothing ran on AWS, with two hosts, or through an ALB.
- **Risk / impact:** A claim of zero downtime would be unsupported. Two hosts also need ordering so a bad release does not reach both.
- **Recommended remediation:** Rehearse on staging first, then with two hosts: rolling order, ALB health during the switch, drain timing against the 30 s deregistration delay and the scripts' own 10 s drain. Report the measured failed requests, as was done locally.
- **Blocks deployment:** No (needed before any availability claim)


## 8. Terraform state and CI/CD findings
Remote-state readiness is design-only today. State would hold resource attributes and the (secret-free) boot script, not secret values: the RDS master
secret appears as an ARN only. A recommended S3 design is in ST-02; nothing was created.

#### ST-01 — Terraform state is local, unlocked and unversioned
- **Severity:** High
- **Reference:** `versions.tf` (no backend); `.gitignore`
- **Current behavior:** State, plans and both workspaces would live on one laptop.
- **Risk / impact:** Losing the disk orphans billed resources; a mistaken or concurrent apply has no lock; there is no history to recover from; no collaboration or CI use is possible.
- **Recommended remediation:** Design and approve a remote backend before the first production apply (see ST-02). Until then restrict to staging and back the state file up.
- **Blocks deployment:** Yes (production)

#### ST-02 — The remote state backend is not designed yet
- **Severity:** Medium
- **Reference:** `versions.tf` comment; `README.md`
- **Current behavior:** Only a statement that an S3 backend would need its own approval.
- **Risk / impact:** Ad-hoc creation could expose state (resource identifiers, the boot script) or leave it unlocked.
- **Recommended remediation:** Define: a private S3 bucket with block-public-access, versioning, default encryption (KMS), a TLS-only bucket policy, lifecycle for old versions, native S3 lock-file locking (supported by Terraform 1.17), access through roles only, and a documented bootstrap (the bucket is created before the stack that uses it, outside that stack).
- **Blocks deployment:** No

#### ST-03 — Workspaces keep staging and production state in the same place and under the same permissions
- **Severity:** Medium
- **Reference:** `networking.tf` workspace precondition; `README.md`
- **Current behavior:** The workspace-equals-environment check prevents mismatched variables, but both states would share one backend and one set of credentials.
- **Risk / impact:** Anyone who can apply staging can read or alter production state.
- **Recommended remediation:** Use separate state keys or buckets per environment with separate IAM roles; keep the workspace check as a safety net.
- **Blocks deployment:** No

#### ST-04 — The CI/CD identity does not exist, and its trust claim is unknown
- **Severity:** High
- **Reference:** `iam.tf` (deliberately absent); `docs/OIDC_DESIGN.md` item 2a
- **Current behavior:** No GitHub OIDC provider or deploy role is defined; the repository's real `sub` claim has not been captured. An OIDC provider for GitHub is unique per account, so one may already exist from another project.
- **Risk / impact:** No workflow can authenticate to AWS; creating the provider blindly could fail with "already exists" or alter shared trust.
- **Recommended remediation:** Capture the claim, check for an existing provider (read it with a data source rather than creating a second), then define two narrow roles: CI (ECR push for one repository) and deploy (`ssm:SendCommand` on named instances and one document, status reads). Keep Terraform apply out of CI for now.
- **Blocks deployment:** Yes (for CD)

#### ST-05 — CI does not check the Terraform at all
- **Severity:** Medium
- **Reference:** `.github/workflows/ci.yml` (no Terraform step)
- **Current behavior:** Formatting and validation were run by hand only.
- **Risk / impact:** A later change can break the configuration or reintroduce a CIDR, a wildcard or an open port unnoticed.
- **Recommended remediation:** Add a non-required job: `terraform fmt -check`, `init -backend=false`, `validate`, and a policy scan; keep it free of AWS credentials.
- **Blocks deployment:** No

#### ST-06 — The permissions of the `devops` identity are unknown
- **Severity:** Low
- **Reference:** AWS access was not used in this review
- **Current behavior:** It is not known which actions the apply identity may perform.
- **Risk / impact:** The first apply may stop half-way on a missing permission, leaving partial infrastructure.
- **Recommended remediation:** Prepare the list of required actions (EC2, ELB, RDS, ECR, IAM role and policy, Secrets Manager read, SSM) and confirm before the first apply; avoid permanent administrator access.
- **Blocks deployment:** No


## 9. Cost and reliability assessment
Code-based. **All prices are estimates from general list prices for the region and were not verified against current AWS Mumbai pricing** (no AWS access;
web search returned no Mumbai rates). Only the public-IPv4 charge ($0.005 per address-hour) was confirmed from an AWS-sourced page. Recompute with the AWS
Pricing Calculator before applying. These totals are a dollar or two above the README's because they add Secrets Manager.

| Item (730 h per month) | Staging | Production (single NAT) | Production (NAT per AZ) |
|---|---|---|---|
| Application Load Balancer | $22 to $26 | $22 to $28 | $22 to $28 |
| EC2 `t3.small` | 1 instance, $15 to $18 | 2 instances, $30 to $36 | 2 instances, $30 to $36 |
| EBS gp3 20 GiB each | $2 | $3 to $4 | $3 to $4 |
| RDS PostgreSQL | `db.t4g.micro` single-AZ, $13 to $17 | `db.t4g.small` Multi-AZ, $52 to $67 | $52 to $67 |
| RDS storage and backups | $3 | $15 to $21 | $15 to $21 |
| NAT Gateway(s) plus data processing | $33 to $42 | $35 to $45 | $70 to $88 |
| Public IPv4 addresses ($0.005 per hour each) | $11 (3) | $11 (3) | $14 (4) |
| ECR storage (scan on push, basic) | $1 | $1 to $2 | $1 to $2 |
| Secrets Manager (about 2 secrets per environment; list price per secret per month is an assumption) | $1 | $1 | $1 |
| VPC endpoints | not used, $0 | not used, $0 | not used, $0 |
| CloudWatch (nothing is configured; logs and alarms would add a few dollars) | $0 now | $0 now | $0 now |
| Data transfer, cross-AZ, misc. | $1 to $3 | $3 to $8 | $3 to $8 |
| **Approximate total** | **about $102 to $124** | **about $173 to $223** | **about $211 to $269** |

**Shared infrastructure** does not exist: each stack is self-contained. Later shared items are small: a remote-state S3 bucket and lock (cents),
a Route 53 hosted zone if a domain is used (a fraction of a dollar per month, plus the domain registration), ACM certificates (no charge), and the GitHub
OIDC provider (no charge). The largest drivers are **NAT Gateway, ALB, RDS (especially Multi-AZ) and EC2**; the costs that are not yet budgeted are
CloudWatch logs and alarms (IAM-03, RDS-04), WAF if added, T3 surplus credits (IAM-07) and NAT data for image pulls (NET-02).

**Availability risks (from the code):**

| Failure | Staging | Production |
|---|---|---|
| One instance fails | outage until replaced (no recovery automation, ALB-04) | one target remains; no automatic replacement |
| One AZ fails | outage if it holds the instance | surviving instance serves; if the NAT AZ failed it has no outbound access (NET-01) |
| NAT AZ fails | outbound lost | outbound lost for the other AZ unless `nat_per_az` |
| RDS failover or outage | single-AZ: down until recovery or restore | Multi-AZ failover, then a minute or two of failing database calls; both targets fail `/health` together (ALB-02); not rehearsed (RDS-07) |
| ALB health-check behaviour | one target | two targets; independent hosts but one shared database dependency |
| Region failure | total | total; no cross-region design |

## 10. Existing deployment integration gaps
Compared against the approved architecture (files read on this commit; nothing was modified):

| Area | Existing behaviour | Needed | Finding |
|---|---|---|---|
| Access | `ssh`/`scp` to a host, port-22 rule opened per run, SSH secrets | `aws ssm send-command` on instance IDs, exit-code mapping | INT-01 |
| Delivery | `docker save` bundle uploaded and `docker load`ed, checksum file | push by immutable tag, pull by digest, digest history | INT-03, ECR-01 |
| Reaching private hosts | n/a (host address in a secret) | Systems Manager; scripts and config delivered by an agreed mechanism | INT-05 |
| Backend | one `DATABASE_URL`, no TLS, no AWS SDK | Secrets Manager client, TLS with the RDS CA, host/port/name from configuration | INT-02 |
| Compose and scripts | `db` container, `bg_db_up`, `secrets.env`, offline tests, CI Compose check | remove the container, check RDS reachability, fetch secrets at deploy time, rewrite tests and CI check | INT-04 |
| Migrations and roles | roles by a local init script, no lock, grants skipped when the role is missing | operator bootstrap, owner secret, single execution, advisory lock | RDS-01, RDS-02, INT-06 |
| Production | one host assumed | rolling update across two hosts | INT-06 |
| Rollback | per-host history, images kept locally | digest history, retention aligned with the rollback horizon | INT-07 |
| Health checks | `/health` runs `SELECT 1`; scripts check `/health` and `/version` | liveness/readiness split for the ALB; behaviour tested during a failover | ALB-02, RDS-07 |
| Prerequisites | CD disabled (correct), no Environments, no secrets | Environments with reviewers, OIDC roles | INT-08, ST-04 |
| Documentation | old architecture in several files | update after approval | DOC-01, DOC-02 |

#### INT-01 — The deployment and rollback workflows are SSH-based and cannot reach private instances
- **Severity:** Critical
- **Reference:** `.github/workflows/cd.yml` (both deploy jobs), `.github/workflows/rollback.yml`; `ci.yml` SSH-parity check
- **Current behavior:** cd.yml has 4 `ssh` and 4 `scp` command lines and uses `EC2_HOST`, `EC2_USER`, `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS` and a per-run port-22 security-group rule. rollback.yml uses the same steps. None uses Systems Manager (0 references).
- **Risk / impact:** There is nothing to connect to: the instances have no public address and no SSH path. No release or rollback can run.
- **Recommended remediation:** Rewrite both workflows around `aws ssm send-command` against the instance IDs from the Terraform outputs; map the command result to exit codes 0, 1 and 3; delete the SSH steps, secrets and the CI parity check; redesign the OIDC role (ST-04).
- **Blocks deployment:** Yes

#### INT-02 — The backend cannot retrieve secrets with the AWS SDK or connect to RDS over TLS
- **Severity:** Critical
- **Reference:** `backend/src/config.js` (`DATABASE_URL`); `backend/src/db.js` (`pg.Pool({ connectionString })`); `backend/scripts/migrate.js`, `seed.js`; `backend/package.json` (no AWS SDK)
- **Current behavior:** Configuration is a single connection URL with the password inside it; there is no Secrets Manager client, no TLS option and no CA handling. RDS enforces TLS (`rds.force_ssl`).
- **Risk / impact:** The application cannot start against RDS, and migrations cannot run.
- **Recommended remediation:** Add the Secrets Manager client and build the pool from a secret identifier plus host, port and database name; enable TLS with the RDS CA bundle; keep the local `DATABASE_URL` path; update `migrate.js` and `seed.js`; add tests with a mocked SDK.
- **Blocks deployment:** Yes

#### INT-03 — Packaging is `docker save` plus `scp`; the deploy script loads a tarball
- **Severity:** High
- **Reference:** `.github/workflows/cd.yml` ("Package release", `docker save`); `deploy/scripts/bluegreen-deploy.sh` (`docker load`, `backend-image.tar.gz`, label check)
- **Current behavior:** The image travels in a bundle with a checksum file and is loaded on the host.
- **Risk / impact:** Incompatible with ECR delivery; see ECR-01.
- **Recommended remediation:** Push to ECR by immutable tag, record the digest, pull by digest on the host, verify digest and revision label.
- **Blocks deployment:** Yes

#### INT-04 — The production Compose file, the scripts and CI checks assume a local database container
- **Severity:** High
- **Reference:** `deploy/docker-compose.prod.yml` (`db`, `pgdata`, `db-init`, `@db:5432`); `deploy/scripts/lib/bluegreen-lib.sh` (`bg_db_up`, `secrets.env` and its letters-and-digits rule); `ci.yml` line 170 (`c.services.db`); `deploy/tests/bluegreen-logic.test.sh`
- **Current behavior:** The `db` service, its volume and init mount, `depends_on: db`, a `pg_isready` inside the container and a three-password `secrets.env` are core to the deploy flow. The CI Compose check dereferences `c.services.db` and would throw once it is removed.
- **Risk / impact:** The scripts fail on a host with no database container; CI breaks when the service is removed.
- **Recommended remediation:** Remove the `db` service and its dependencies, replace `bg_db_up` with a reachability check, replace `secrets.env` with secret retrieval, and rewrite the offline tests and the CI check together.
- **Blocks deployment:** Yes

#### INT-05 — How the deploy scripts, nginx config and frontend files reach the instances is undecided
- **Severity:** High
- **Reference:** `.github/workflows/cd.yml` (bundle); `INTEGRATION_GAPS.md` section 2
- **Current behavior:** Today they travel inside the uploaded bundle. With ECR only images move.
- **Risk / impact:** The host has no way to obtain the scripts, `docker-compose.prod.yml` or the frontend files.
- **Recommended remediation:** Decide: bake them into an image, pass them as SSM document parameters, or fetch from the repository at a pinned commit; record the choice and its verification.
- **Blocks deployment:** Yes

#### INT-06 — Two production instances need a rolling deploy, and migrations must run exactly once
- **Severity:** High
- **Reference:** `deploy/scripts/bluegreen-deploy.sh` (single host, lock directory per host); `backend/src/migrate.js` (no advisory lock); deferred finding B6
- **Current behavior:** The scripts assume one host with local state; migrations take no database lock.
- **Risk / impact:** Two hosts could run migrations concurrently or a bad release could reach both at once.
- **Recommended remediation:** Run migrations once from a single place before either host updates; add a database advisory lock; update one host, wait for ALB health, then the other; stop on the first failure.
- **Blocks deployment:** Yes (production)

#### INT-07 — Rollback depends on per-host state and on images that may no longer exist
- **Severity:** Medium
- **Reference:** `deploy/scripts/rollback.sh`; `bluegreen-lib.sh` (state, history, `last_good` on local disk); `ecr.tf` lifecycle
- **Current behavior:** Release history and the active colour live on each host's disk; rollback needs the image and frontend files locally.
- **Risk / impact:** A rebuilt instance loses its history; images older than the lifecycle window cannot be pulled.
- **Recommended remediation:** Keep a digest history outside the host (for example Parameter Store or ECR tags), make rollback pull by digest, and size the retention to the rollback horizon.
- **Blocks deployment:** No

#### INT-08 — GitHub Environments, secrets and the CD switch are prerequisites that do not exist yet
- **Severity:** Medium
- **Reference:** `.github/workflows/cd.yml` gate (`vars.CD_ENABLED`); GitHub settings
- **Current behavior:** CD is correctly disabled (the variable is unset; runs conclude skipped). No Environments or secrets exist.
- **Risk / impact:** Enabling CD first would create an unprotected Environment on a first dispatch.
- **Recommended remediation:** Create `staging` and `production` Environments with required reviewers and a `main`-only branch policy before setting `CD_ENABLED`.
- **Blocks deployment:** Yes (for CD)


#### DOC-01 — Several documents still describe the old architecture
- **Severity:** Medium
- **Reference:** `CLAUDE.md` lines 10, 11, 31; `docs/ARCHITECTURE.md` (one EC2 instance, SSH strategy, Docker Postgres); `docs/OIDC_DESIGN.md` (23 lines mention SSH); `PROJECT_STATUS.md` lines 26, 57, 60, 250; the requirements checklist (Parts E, F, G)
- **Current behavior:** They say PostgreSQL runs in Docker, one instance hosts both environments, and deployment is over SSH with a per-run rule. CLAUDE.md hard rule 12 points at that SSH strategy.
- **Risk / impact:** Reviewers and future sessions could follow the superseded design; rule 12 now conflicts with the approved SSM design.
- **Recommended remediation:** After approval, update these documents and record the superseded 2026-11-17 decisions; update rule 12 to point at the SSM design. Not changed in this review.
- **Blocks deployment:** No

#### DOC-02 — Some statements in my earlier Terraform documentation are inaccurate or unverified
- **Severity:** Medium
- **Reference:** `README.md` (section 3 "ALB serves 503"; prices; "SSM agent preinstalled"; RDS rotation wording); `ARCHITECTURE.md` failure table; `INTEGRATION_GAPS.md` section 7
- **Current behavior:** They say the ALB returns 503 when every target is unhealthy; ALBs route to all targets in that case (see ALB-02). They state that the Ubuntu AMI ships the SSM agent, that `docker-compose-v2` is in the Ubuntu repositories and that RDS-managed secrets rotate, none of which could be checked without AWS or network access. Prices are ranges from general list prices, not verified for Mumbai.
- **Risk / impact:** Readers could rely on claims that have not been verified.
- **Recommended remediation:** Correct the wording and mark each assumption "to verify", then verify during the first staging plan and boot.
- **Blocks deployment:** No


## 11. Risk register
| ID | Severity | Finding | Blocks deployment |
|---|---|---|---|
| RDS-01 | Critical | The database roles are not bootstrapped, and the migrations would silently skip their grants | Yes |
| INT-01 | Critical | The deployment and rollback workflows are SSH-based and cannot reach private instances | Yes |
| INT-02 | Critical | The backend cannot retrieve secrets with the AWS SDK or connect to RDS over TLS | Yes |
| TF-01 | High | Instances can boot before the NAT route exists, so first-boot setup can fail permanently | Yes (first-boot reliability) |
| ALB-01 | High | Production would serve over plain HTTP until a domain and certificate exist | Yes (production) |
| ST-01 | High | Terraform state is local, unlocked and unversioned | Yes (production) |
| ST-04 | High | The CI/CD identity does not exist, and its trust claim is unknown | Yes (for CD) |
| INT-03 | High | Packaging is `docker save` plus `scp`; the deploy script loads a tarball | Yes |
| INT-04 | High | The production Compose file, the scripts and CI checks assume a local database container | Yes |
| INT-05 | High | How the deploy scripts, nginx config and frontend files reach the instances is undecided | Yes |
| INT-06 | High | Two production instances need a rolling deploy, and migrations must run exactly once | Yes (production) |
| TF-02 | Medium | RDS storage autoscaling causes permanent plan drift and a failing apply | No |
| TF-03 | Medium | Nothing prevents applying to the wrong AWS account or with a root identity | No (do before the first plan) |
| NET-01 | Medium | A single NAT Gateway is an outbound single point of failure in both environments | No (needs an explicit decision before production) |
| NET-02 | Medium | All image and layer downloads cross the NAT; Docker Hub is an unmanaged dependency behind one shared address | No (may surface at the first deploy) |
| NET-04 | Medium | No network or request logging, and no WAF | No (production should not go live without logging) |
| IAM-01 | Medium | IMDS hop limit 2 lets any container read the instance role credentials; user data is readable the same way | No (decision needed) |
| IAM-02 | Medium | The AWS-managed SSM instance policy is broad | No |
| IAM-03 | Medium | No logging, CloudWatch permissions, alarms or session audit | No (staging); production should not go live without it |
| IAM-05 | Medium | No operating-system patching process | No (production) |
| IAM-06 | Medium | Docker logs are not rotated and old images accumulate on a 20 GiB disk | No |
| RDS-02 | Medium | No safe channel is defined for the operator who must use the master secret | Yes (for the first bootstrap) |
| RDS-03 | Medium | Production is not forced to be Multi-AZ | No (production) |
| RDS-04 | Medium | No database logs, monitoring or alarms | No (production) |
| RDS-05 | Medium | The application database credentials are static | No |
| RDS-07 | Medium | Behaviour during a Multi-AZ failover has not been tested | No |
| ECR-01 | Medium | Digest-based deployment is possible but not implemented | Yes (for the ECR flow) |
| ALB-02 | Medium | The health check couples every target to the database | No |
| ALB-04 | Medium | A failed instance is not replaced automatically | No (production) |
| ALB-06 | Medium | Zero downtime and rolling updates are unproven on this architecture | No (needed before any availability claim) |
| ST-02 | Medium | The remote state backend is not designed yet | No |
| ST-03 | Medium | Workspaces keep staging and production state in the same place and under the same permissions | No |
| ST-05 | Medium | CI does not check the Terraform at all | No |
| INT-07 | Medium | Rollback depends on per-host state and on images that may no longer exist | No |
| INT-08 | Medium | GitHub Environments, secrets and the CD switch are prerequisites that do not exist yet | Yes (for CD) |
| DOC-01 | Medium | Several documents still describe the old architecture | No |
| DOC-02 | Medium | Some statements in my earlier Terraform documentation are inaccurate or unverified | No |
| TF-04 | Low | Lock file records one platform hash | No |
| TF-05 | Low | Variable validation gaps | No |
| TF-06 | Low | Fixed final-snapshot name collides on a second delete | No |
| NET-03 | Low | Instances may reach any host on 443 and 80 | No |
| IAM-04 | Low | The "deploy" service user is not actually what runs deploys, and docker-group membership is root-equivalent | No |
| IAM-07 | Low | Burstable instances default to unlimited CPU credits | No |
| RDS-06 | Low | Engine version, disaster-recovery copies and default keys are unverified or minimal | No |
| ECR-02 | Low | Scan on push exists but nothing acts on the result | No |
| ECR-03 | Low | Lifecycle count, host disk and promotion are not aligned | No |
| ALB-03 | Low | The health path does not detect a broken frontend | No |
| ALB-05 | Low | Production ALB deletion protection is not enforced | No |
| ST-06 | Low | The permissions of the `devops` identity are unknown | No |

## 12. Recommended remediation plan
Each step needs its own approval. Nothing here has been started.

1. **Safe to do first (no AWS needed):** fix TF-01, TF-02, TF-03 guards, TF-04, TF-05, TF-06; default production to Multi-AZ and ALB deletion protection (RDS-03,
   ALB-05); add the Terraform CI job (ST-05); correct the inaccurate documentation (DOC-02); decide the open design questions in section 14.
2. **Before the first staging plan:** re-authenticate (you), confirm the apply identity's permissions (ST-06), check engine-version and instance-class availability (RDS-06), read the managed SSM policy (IAM-02).
3. **Staging infrastructure:** plan, review, apply staging only; verify first boot (Docker, `deploy` user, CA bundle, SSM registration) and the TF-01 fix.
4. **Application:** backend SDK and TLS (INT-02); Compose and scripts for RDS and ECR (INT-04, INT-03); delivery decision (INT-05); operator bootstrap and migration procedure (RDS-01, RDS-02); offline tests and CI check.
5. **Pipeline:** OIDC roles (ST-04), SSM-based `cd.yml` and `rollback.yml` (INT-01), Environments (INT-08); then `CD_ENABLED` for staging only.
6. **Staging evidence:** deploy, failed release, rollback, a database failover and a restore; record real numbers (ALB-06, RDS-07).
7. **Production prerequisites:** domain and certificate (ALB-01), remote state (ST-01, ST-02, ST-03), logging and alarms (NET-04, IAM-03, RDS-04), patching (IAM-05), rolling deploy (INT-06), NAT decision (NET-01), hop-limit decision (IAM-01).
8. **Then** production, with Multi-AZ RDS and two instances, followed by a rolling-deploy rehearsal.

## 13. Pre-deployment checklist
Staging apply:
- [ ] You have re-authenticated and `aws sts get-caller-identity` shows the `devops` identity (not root); account guard in place (TF-03)
- [ ] Apply identity permissions confirmed (ST-06)
- [ ] TF-01 fixed (instance waits for the NAT route) and TF-02 fixed
- [ ] Untracked `staging.tfvars` contains `vpc_cidr` and `alb_allowed_cidrs` (specific addresses only)
- [ ] RDS engine version and instance class confirmed available in ap-south-1
- [ ] A real `terraform plan` reviewed; resource count and preconditions behave as documented
- [ ] Cost estimate rechecked in the AWS Pricing Calculator; teardown plan agreed (staging `terraform destroy` needs approval, ECR images must be deleted first)

Before the first deploy to staging:
- [ ] Operator bootstrap of `shopnest_owner` and `shopnest_app` written, tested, and the master secret handled without logging (RDS-01, RDS-02)
- [ ] `db-app` (and `db-owner` if migrations run on the instance) secrets created out of band and the secret names match `db_secret_names`
- [ ] Backend reads the secret with the SDK and connects over TLS (INT-02); tests pass
- [ ] Compose, scripts, offline tests and CI check updated for RDS and ECR (INT-04, INT-03)
- [ ] Script delivery mechanism decided (INT-05)
- [ ] OIDC roles created with narrow permissions (ST-04); Environments with reviewers exist (INT-08)
- [ ] SSM-based workflows written and rehearsed on staging (INT-01)

Before production:
- [ ] Domain and ACM certificate; HTTPS listener active (ALB-01)
- [ ] Remote state with locking and versioning, separate per environment (ST-01 to ST-03)
- [ ] Multi-AZ RDS enforced; deletion protection on RDS and the ALB (RDS-03, ALB-05)
- [ ] Logging, alarms, session audit and patching in place (NET-04, IAM-03, IAM-05, RDS-04)
- [ ] Rolling deploy across two hosts rehearsed; migrations run once (INT-06)
- [ ] NAT-per-AZ and hop-limit decisions recorded (NET-01, IAM-01)
- [ ] A database restore and a failover have been rehearsed on staging (RDS-07)
- [ ] Documentation updated to the final design (DOC-01)

## 14. Decisions and approvals needed from you
1. **Fix the safe Terraform findings** (TF-01 to TF-06, RDS-03, ALB-05, ST-05)? These change only `infra/terraform/` and CI.
2. **NAT per AZ for production** (about one more gateway) or accept the outbound single point of failure (NET-01).
3. **IMDS hop limit 2:** accept, or mitigate (block metadata for other containers, or run the backend with host networking) (IAM-01).
4. **Replace the AWS-managed SSM policy** with a custom minimal one (IAM-02)?
5. **Add an S3 gateway endpoint and mirror the nginx image into ECR** (NET-02)? (A supplementary endpoint; NAT stays the internet path.)
6. **Where migrations run** (on the instance, which needs `db-owner` readable, or from a separate step) and the bootstrap procedure (RDS-01, RDS-02).
7. **How scripts and config reach the instances** (image, SSM parameters, or a pinned repository fetch) (INT-05).
8. **Health-check design:** split liveness and readiness (ALB-02)? Auto-recovery alarms or an Auto Scaling group for production (ALB-04)?
9. **Remote state design** (ST-02, ST-03) and when to create it; whether the first apply is staging-only on local state.
10. **Logging and alarm scope and budget** (NET-04, IAM-03, RDS-04) and a patching approach (IAM-05).
11. **Domain and certificate** for production (ALB-01) and the instructor's answer on the live URL.
12. **Whether Systems Manager Run Command satisfies the assignment's "deployment over SSH" wording** (confirm with your instructor).
13. **Documentation updates** (DOC-01, DOC-02), including CLAUDE.md rule 12.
