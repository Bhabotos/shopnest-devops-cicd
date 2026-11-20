# Phase 4.2 remediation log

Records what was changed for the findings approved from [`ARCHITECTURE_SECURITY_REVIEW.md`](ARCHITECTURE_SECURITY_REVIEW.md), plus the other Phase 4.2
items. **Status here means "changed in the repository and checked statically".** Nothing has been planned, applied or exercised against AWS, so a finding
marked *fixed in code* is not proven fixed in a running environment. The review file itself is left unchanged as the record of the original review.

## Approved findings
| ID | Finding (from the review) | Change | Files | Status |
|---|---|---|---|---|
| TF-01 | Instances can boot before the NAT route exists, so first-boot setup can fail permanently | `depends_on` the NAT Gateways, the application route-table associations and the SSM policy attachment; the boot script retries its network calls (up to about five minutes for the first `apt-get update`), writes `/var/lib/shopnest/bootstrap-complete` on success or `bootstrap-failed` with the failing line on failure; recovery documented | `compute.tf` (`aws_instance.app`), `user_data.sh.tftpl`, `README.md` section 4 | Fixed in code. Boot behaviour not exercised (no instance created). Existing instances ignore boot-script changes by design |
| TF-02 | RDS storage autoscaling causes permanent plan drift and a failing apply | `allocated_storage` added to `ignore_changes`; `rds_max_allocated_storage_gb` must be greater than the allocation (or null) | `rds.tf`, `variables.tf` | Fixed in code |
| TF-03 | Nothing prevents applying to the wrong AWS account or with a root identity | required `allowed_account_ids` (no default, validated as 12-digit IDs, supplied only through an untracked variable file) wired to the provider; precondition on `aws_vpc` that the caller ARN does not end in `:root` | `variables.tf`, `provider.tf`, `networking.tf` | Fixed in code. Both guards run at plan time, which has not been done |
| TF-04 | Lock file records one platform hash | `terraform providers lock` for `windows_amd64`, `linux_amd64`, `darwin_arm64` (provider unchanged at 6.73.0; now three `h1` hashes) | `.terraform.lock.hcl` | Fixed. The CI job's `-lockfile=readonly` init checks it on Linux (not yet run on GitHub) |
| TF-05 | Variable validation gaps | `alb_allowed_cidrs`: IPv4 CIDR syntax only (IPv6, empty and malformed values rejected); `app_port`: 1 to 65535 and not 22 or 5432; `instance_type`: shape check; `rds_storage_type`: `io1` removed (no IOPS setting exists); storage ceiling compared with the allocation | `variables.tf` | Fixed in code |
| TF-06 | Fixed final-snapshot name collides on a second delete | name is `<project>-<environment>-final-<suffix>` with a validated `rds_final_snapshot_suffix` variable (default `1`); bump it before deleting and recreating a database. A timestamp was deliberately not used because it would show a change on every plan | `variables.tf`, `rds.tf`, both examples | Fixed in code |
| RDS-03 | Production is not forced to be Multi-AZ | `rds_multi_az` defaults to on for production (null means production true, staging false) and a precondition refuses production without it | `variables.tf`, `rds.tf` | Fixed in code |
| ALB-05 | Production ALB deletion protection is not enforced | `enable_deletion_protection` defaults to on for production (null means production true, staging false). No precondition, so production can be decommissioned by setting it to false first | `variables.tf`, `compute.tf` | Fixed in code (a default, not an enforcement) |

## Other approved Phase 4.2 items
| Item | Change | Status |
|---|---|---|
| Production NAT per AZ | `nat_per_az` defaults to on for production; one gateway and Elastic IP per AZ; each AZ's application subnet routes through the gateway in its own AZ (`nat_az_for_az`), so there is no cross-AZ NAT routing in production; a precondition refuses production without it; per-AZ route tables are tagged with the NAT AZ; outputs `nat_gateway_ids` and `app_subnet_nat_az`. Staging keeps one gateway (cost optimisation and an outbound single point of failure, documented as such) | In code. Extra cost about $37 to $45 a month (estimate) |
| Encrypted S3 deployment artifact bucket | `artifacts.tf`: public access fully blocked, ACLs disabled, SSE (AES-256 or a supplied KMS key), versioning, TLS 1.2+ enforced by a Deny-only bucket policy, lifecycle (noncurrent versions, multipart, delete markers), `force_destroy = false`; `iam.tf`: instance role read-only on one prefix | In code. Not created, nothing uploaded, no workflow uses it |
| Terraform CI workflow | `.github/workflows/terraform-ci.yml`: fmt, init without a backend (`-lockfile=readonly`), validate, secret scan; pinned action and tool versions; `contents: read` only; no AWS access. `ci.yml` untouched | Written and checked locally (YAML, actionlint, the Terraform steps). Has not run on GitHub |
| Documentation | README, ARCHITECTURE and INTEGRATION_GAPS (Terraform-specific files only) updated; this log added | Done |

## Remaining blockers and assumptions
- **No AWS evidence.** Preconditions, dependency ordering, IAM policies, the bucket policy and provider-side acceptance of every argument (for example
  `allowed_account_ids`, the lifecycle `newer_noncurrent_versions` setting, the engine version) are checked only by `terraform validate`, which does not prove AWS will accept them.
- **`allowed_account_ids` is now required.** A plan fails until you supply it in an untracked variable file (by design).
- **Still-open Critical and High findings** from the review: INT-01, INT-02, RDS-01 (Critical); ALB-01, ST-01, ST-04, INT-03, INT-04, INT-05, INT-06 (High). They belong to
  Phase 4.3 or 4.4 (below) or need decisions. TF-01 (High) is fixed in code.
- **Assumptions to verify at first boot or plan:** the SSM agent is preinstalled on the Ubuntu AMI; `docker-compose-v2` is in the Ubuntu repositories; RDS accepts a
  major-only engine version; the contents of the AWS-managed SSM policy (IAM-02); the generated S3 bucket name is available.
- **The artifact bucket has no publisher and no consumer yet.** Until Phase 4.3 nothing writes to it, and the instance-side fetch tool is undecided.
- **The Terraform CI job names cannot become required checks yet** (path-filtered workflow), see README section 14.
- **Interpretations made:** ALB deletion protection is a default, not a precondition (so production can be decommissioned); Multi-AZ RDS and NAT per AZ are preconditions for
  production (consistent with the other production guardrails); the artifact bucket is one per environment; the instance role gets read-only access to the bucket prefix only.

## Deferred (not implemented in Phase 4.2)
**Phase 4.3:** backend AWS SDK secret retrieval and RDS TLS in the application; the `shopnest_owner` and `shopnest_app` bootstrap and a one-time migration operation through
SSM; ECR push by immutable digest; SSM-based deployment and rollback workflows; two-instance rolling deployment; application liveness and readiness endpoints;
deployment script delivery and execution (including the artifact publisher identity).

**Phase 4.4:** S3 remote state creation and migration; CloudWatch log groups and alarms; VPC Flow Logs; SSM session audit; Systems Manager Patch Manager;
production domain and ACM certificate.

---

## Addendum (Phase 4.2.1 and 4.2.2): TF-06 final snapshot name validation
Append-only entry, dated 2026-11-20. The historical TF-06 row in "Approved findings" above is left exactly as written. This addendum records a defect found afterwards, what was
changed, and what has and has not been verified. It does not mark any AWS-dependent finding as resolved.

### Reconciliation with the historical entry
The table above lists TF-06 as "Fixed in code" with "a validated `rds_final_snapshot_suffix` variable". The Phase 4.2 final verification found that this was only partly true:
the validation accepted a suffix such as `a--b`, which produces a snapshot name with two consecutive hyphens, and RDS rejects that. **The historical status is therefore superseded
by this addendum: TF-06 is fixed in code and validated locally, and is not yet validated against AWS.** The files named in the historical row (`variables.tf`, `rds.tf`, both
examples) are still the right ones; the examples did not need to change in this follow-up. The statement that a timestamp was deliberately not used remains correct.

### What was wrong
- The previous pattern, `^[A-Za-z0-9]([A-Za-z0-9-]{0,18}[A-Za-z0-9])?$`, allowed consecutive hyphens inside the suffix.
- It imposed an arbitrary 20-character limit on the suffix. That limit is not an AWS rule.
- It looked at the suffix alone, not at the complete generated name `<project>-<environment>-final-<suffix>`, so the 255-character RDS limit and the first-character rule were not checked
  on the name that RDS actually receives.

### What changed (`variables.tf`, `rds.tf`)
The rules come from the AWS RDS API reference for `FinalDBSnapshotIdentifier` (DeleteDBInstance): 1 to 255 characters; letters, digits and hyphens; the first character a letter;
no trailing hyphen; no two consecutive hyphens.

| Item | Change |
|---|---|
| Suffix pattern | `^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$`: letters and digits, with single hyphens only between groups. Rejects an empty value, a leading or trailing hyphen, two hyphens in a row and every other character |
| Complete-length check | a second validation on the variable: `length("<project>-<environment>-final-<suffix>") <= 255`, the RDS maximum for the complete identifier |
| Arbitrary limit | the 20-character cap on the suffix is removed; the only length limit is now the AWS one, applied to the complete name |
| Resource-level precondition | `aws_db_instance.main` checks the complete identifier (skipped when `rds_skip_final_snapshot` is true): at most 255 characters, starts with a letter, letters, digits and single hyphens only, no trailing hyphen. It exists because a variable cannot check the first character of the complete name or an unusual `project` value, and so that a bad name fails at plan time and not when the database is deleted |
| Local value | `final_snapshot_identifier` is defined once in `rds.tf` and used by the resource and the precondition |
| Default | unchanged: `shopnest-production-final-1` (suffix `1`) |

### Local verification
No AWS involvement. The variable validation and the precondition expression were evaluated with `terraform console` in an isolated scratch directory that contained a copy of the real
`variables.tf`. Re-run on 2026-11-20 for this entry.

| Check | Result |
|---|---|
| Valid suffixes (`1`, `2`, `final2`, `2026-11`, `a-b-c`, `A1`, `20261120`, `x`) | 8 of 8 accepted |
| Invalid suffixes (`a--b`, `-x`, `x-`, `-`, `x_y`, `x.y`, `x y`, `é1`, empty) | 9 of 9 rejected |
| Boundary, production (prefix `shopnest-production-final-` is 26 characters) | longest suffix 229: total 255 accepted; 230: total 256 rejected |
| Boundary, staging (prefix is 23 characters) | longest suffix 232: total 255 accepted; 233: total 256 rejected |
| Long project name (200 characters) | a 40-character suffix (total 258) rejected; the default suffix `1` accepted, so the complete-length limit counts the project name |
| Whole-identifier condition (the precondition's expression, tested on strings) | `shopnest-production-final-1` true; a name starting with a digit, containing an underscore, ending with a hyphen or containing two hyphens in a row, false; 255 characters true, 256 false |
| `terraform fmt -check -recursive` | exit 0 |
| `terraform init -backend=false -input=false -lockfile=readonly` | initialized successfully, exit 0 |
| `terraform validate` | "Success! The configuration is valid." |
| gitleaks 8.30.1 (repository rules) | no leaks found in `infra/`, the working tree, the tracked diff and the full history across all refs. Run before this addendum was appended; it is repeated after the append and reported in the verification report |

### Related documentation
The Terraform README gained a "Production RDS Decommission Procedure" section (Phase 4.2.1). It is documentation only: deletion protection was not changed, no production variable was
changed, and `terraform destroy` was not run.

### Still not verified, and still pending
- **AWS staging validation is pending.** AWS has not accepted a snapshot identifier produced by this configuration. The precondition has not been exercised by a real `terraform plan`,
  and Terraform's behaviour for preconditions in a destroy-only plan has not been tested.
- **Hyphen behaviour needs a staging rehearsal.** The AWS wording says "letters or numbers" while its other rules imply hyphens inside the name are allowed; the naming convention relies on that.
- **No AWS operation took place.** No authentication, plan, apply, destroy, import or resource operation was performed for this change.
- **No Git operation took place.** Nothing was staged, committed or pushed.
- The "Remaining blockers and assumptions" and "Deferred" sections above are unchanged by this addendum: the open Critical and High findings are still open.
