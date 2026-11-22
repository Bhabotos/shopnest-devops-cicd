# GitHub OIDC Design (SUPERSEDED SSH access design, kept for its verification log)

> **SUPERSEDED (2026-11-22, `main` at `7d88e9b`).** The design below opens a temporary port-22 rule for one runner and deploys over SSH.
> **The implementation does not do this.** It has no inbound SSH rule and no SSH key. GitHub OIDC is still used, but only to obtain short-lived
> credentials for a deploy role that can push the image to ECR, upload the release bundle (PutObject only), start the CodeBuild migrator, and send
> exactly two Systems Manager documents (deploy, rollback) to exactly one instance. See `infra/terraform/github_oidc.tf`, `.github/workflows/cd.yml`
> and `rollback.yml`, and `docs/AWS_STAGING_INTEGRATION.md` section 3.3.
>
> What still applies from this file: the OIDC trust idea and the verification log rows about OIDC claims. The real `sub` claim must be captured from a
> workflow run, not guessed (a newer repository may use ID-based claims); the trust policy lists exact subjects with `StringEquals` and the `sts.amazonaws.com` audience.
> A job bound to a GitHub Environment has a different subject from a branch-only job, so capture it from the real `deploy-staging` job.
> What does NOT apply: the security-group rules, the sweeper, the `SSH_*` names, the host-key section and the SSH risk table.
> Whether SSH versus Systems Manager satisfies the assignment wording ("over SSH") is **pending instructor confirmation**.

Status of the original design: DESIGN ONLY. No AWS resource has been created or applied. Terraform will define these in
Phase 4 and nothing is applied without explicit approval. All identifiers below are placeholders.
No server IP, DNS name or URL appears in this document.

Convention: every factual claim about AWS or GitHub is marked
**[Verified]** (read in the official documentation, source listed in "Verification log"),
**[Not verified]** (could not be confirmed from the documentation; treated as an assumption), or
**[Design]** (our proposal, not a platform fact).
Documentation was read on 2026-11-17. AWS and GitHub change; re-check before Phase 4.

## Goal (superseded design; see the banner above)
This design assumed Part E requires deployment over SSH. Port 22 stays closed. A deploy job obtains short-lived AWS
credentials through GitHub OIDC, opens SSH for exactly one runner address for the duration of
the run, deploys over SSH, and closes the rule again. No permanent AWS access keys exist anywhere.

## Verification log
| # | Claim | Status | Source |
|---|---|---|---|
| 1 | AuthorizeSecurityGroupIngress and RevokeSecurityGroupIngress support resource-level permissions on the `security-group` resource type, whose ARN is `arn:${Partition}:ec2:${Region}:${Account}:security-group/${SecurityGroupId}` | Verified | AWS Service Authorization Reference, Amazon EC2 (1) |
| 2 | `security-group` is the required resource type for both actions | Verified | (1) |
| 3 | For Authorize, `security-group-rule` is listed but not required, and per the page "policies using the security-group-rule resource-level permission are only enforced when the API request includes TagSpecifications" | Verified | (1) |
| 4 | For Revoke, `security-group-rule` is NOT listed as a resource type (only `security-group`) | Verified | (1) |
| 5 | Condition keys listed for the security-group resource on these actions: `aws:ResourceTag/${TagKey}`, `ec2:Region`, `ec2:ResourceTag/${TagKey}`, `ec2:SecurityGroupID`, `ec2:Vpc`. Authorize also lists `aws:RequestTag/${TagKey}`, `aws:TagKeys`, `ec2:Region` on `security-group-rule`. No action-level condition keys | Verified | (1) |
| 6 | NO condition key exists for port, protocol, CIDR or rule description on these actions (searched the full condition key table) | Verified | (1) |
| 7 | Describe actions (DescribeSecurityGroups, DescribeSecurityGroupRules) list no resource type and only the `ec2:Region` condition key | Verified | (1) |
| 8 | The page does not literally say Describe actions "require `*`" | Not verified (inferred from the empty resource-type column) | (1) |
| 9 | Authorize "maps to ec2:CreateTags" when tagging; whether the role needs an explicit `ec2:CreateTags` allow | Not verified | (1) |
| 10 | RevokeSecurityGroupIngress accepts rule IDs: "You can specify rules using either rule IDs or security group rule properties." Parameter name is `SecurityGroupRuleId.N`; CLI flag `--security-group-rule-ids` exists | Verified (API page and offline `aws ec2 revoke-security-group-ingress help`) | EC2 API Reference RevokeSecurityGroupIngress (2); local CLI help |
| 11 | Whether `SecurityGroupRuleId.N` may be combined with `GroupId` and whether `GroupId` is required alongside it | Not verified (page silent). Page states non-default-VPC groups must be addressed by group ID | (2) |
| 12 | Authorize returns `securityGroupRuleSet` ("Information about the inbound (ingress) security group rules that were added") | Verified. That each item carries a rule ID field is Not verified on this page text | EC2 API Reference AuthorizeSecurityGroupIngress (3) |
| 13 | Rules can be tagged at creation via `TagSpecification.N` | Verified | (3) |
| 14 | Rule description is set per range (`IpPermissions.N.IpRanges.N.Description`); allowed characters and maximum length | Not verified (not stated). Mitigation: use only letters, digits and hyphens | (3) |
| 15 | GitHub: "you must define at least one condition" in the cloud trust so untrusted repositories cannot request tokens; AWS recommends evaluating `token.actions.githubusercontent.com:sub`; `aud` is `sts.amazonaws.com` with the official action | Verified | GitHub Docs, OIDC in AWS (4) |
| 16 | Subject format for a job using an environment: `repo:ORG/REPO:environment:ENV` | Verified, with the caveat in row 17 | (4) |
| 17 | "For repositories created after July 15, 2026, or that have opted in to immutable subject claims, the `sub` claim includes immutable owner and repository IDs" (example form `repo:ORG@<id>/REPO@<id>:ref:refs/heads/branch`). Our repo will be created after that date, so the real `sub` likely differs from the simple form | Verified (statement); exact format for environments Not verified. MUST be checked against a real token in Phase 4 | (4) |
| 18 | "Support for custom claims for OIDC is unavailable in AWS." A `job_workflow_ref` condition key for IAM trust policies is not documented on the pages read | Verified (custom claims unavailable). So no workflow-file pin is used | (4) |
| 19 | AWS verifies the OIDC provider's TLS certificate with its trusted root CAs and falls back to thumbprints only if needed; a provider can have 1 to 5 thumbprints. Whether GitHub's provider needs a thumbprint configured | Verified (general rule); GitHub-specific need Not verified | AWS IAM User Guide, OIDC providers (5) |
| 20 | Minimum session duration for AssumeRoleWithWebIdentity / `role-duration-seconds` | Not verified (not stated on the pages read) | (5), (4) |
| 21 | GitHub scheduled workflows: shortest interval 5 minutes; can be delayed at high load and "some queued jobs may be dropped"; run only on the default branch; auto-disabled in public repos after 60 days with no repository activity | Verified | GitHub Docs, events that trigger workflows: schedule (6) |
| 22 | CloudTrail events reach EventBridge with `detail-type` "AWS API Call via CloudTrail", `source` `aws.ec2`, `detail.eventName`; a CloudTrail trail with logging must be enabled for them | Verified | EventBridge User Guide, CloudTrail events (7) |
| 23 | Authorize/Revoke SecurityGroupIngress are matched as write management events by default rules; field paths for the SG ID, port and CIDR inside `detail.requestParameters` | Not verified (event names not on the page; paths must be taken from a real event in Phase 4) | (7) |
| 24 | EventBridge rule must be in the same region as the API call; SNS as a rule target and its topic policy; CloudWatch metrics for rule invocations | Not verified (pages not obtained) | – |
| 25 | EventBridge scheduled rules have one-minute minimum precision, are described as a legacy feature, and EventBridge Scheduler is recommended | Verified | EventBridge User Guide, scheduled rules (8) |
| 26 | GitHub concurrency groups: "only a single job or workflow using the same concurrency group will run at a time" | Verified | GitHub Docs, concurrency (9) |

Sources:
(1) https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html
(2) https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_RevokeSecurityGroupIngress.html
(3) https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_AuthorizeSecurityGroupIngress.html
(4) https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
(5) https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
(6) https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule
(7) https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail.html
(8) https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-rule-schedule.html
(9) https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/using-concurrency
The EC2 identity-based policy examples page could not be retrieved, so no official example policy
was compared against this design (see Open items).

## Flow [Design]
1. Job in `staging` or `production` environment requests an OIDC token (`id-token: write`).
2. `aws-actions/configure-aws-credentials` (pinned) assumes the deploy role with a short session.
3. The workflow determines the runner's public IPv4 address, validates it, and builds the rule
   itself from fixed values: protocol `tcp`, port 22 to 22, CIDR `<validated runner IP>/32`
   (see "Workflow-side enforcement"). Only then does it call AuthorizeSecurityGroupIngress on the
   dedicated SSH security group, with a description `gha-<run_id>-exp-<epoch>` (letters, digits,
   hyphens only, see row 14).
4. The job reads the created rule back and checks it matches what was requested; the rule ID
   returned in the response is saved for cleanup (row 12: confirm the field in Phase 4).
5. Deploy over SSH with strict host key verification. The job has a timeout shorter than the rule
   expiry (see Sweeper).
6. Cleanup step (`if: always()`) revokes that exact rule ID.
7. Sweeper removes anything that survived.

## Trust policy (restricts who can assume the role) [Design, using rows 15-19]
Placeholders: `<ACCOUNT_ID>`, `<SUB_PREFIX>`.
```
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": [
          "<SUB_PREFIX>:environment:staging",
          "<SUB_PREFIX>:environment:production"
        ]
      }
    }
  }]
}
```
- `<SUB_PREFIX>` is either `repo:<owner>/shopnest-devops-cicd` or, if the repository uses
  immutable subject claims (row 17), the form that includes owner and repository IDs. It must be
  copied from a real token's `sub` in Phase 4, not assumed. The `sub` value is an identifier, not a
  secret, but it is still only recorded in Terraform variables, not guessed.
- Exact `StringEquals`, no wildcards: only this repository and only these two environments.
- Both environments allow deployments from `main` only (GitHub environment branch rule), so
  feature branches and fork PRs cannot obtain a token.
- No workflow-file pin: custom claims are unavailable in AWS (row 18).
- Provider thumbprint: follow the current AWS/Terraform provider guidance in Phase 4 (row 19).

## Permissions policy (least privilege) [Design, using rows 1-8]
Create a dedicated security group `<SSH_SG_ID>` attached to the instance that holds ONLY the
transient port 22 rules and no other ingress rule, ever. Web (80/443) rules live in a separate
group the role cannot touch.
```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageSshIngressOnOneSecurityGroup",
      "Effect": "Allow",
      "Action": ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"],
      "Resource": "arn:aws:ec2:ap-south-1:<ACCOUNT_ID>:security-group/<SSH_SG_ID>"
    },
    {
      "Sid": "ReadOnlyDescribe",
      "Effect": "Allow",
      "Action": ["ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules"],
      "Resource": "*"
    }
  ]
}
```
The `Resource` of the first statement is the security group ARN, in the documented form (row 1).

Validity assessment against the documentation:
- Valid as designed: both write actions support the `security-group` resource type and it is the
  only required one (rows 1, 2), so one SG ARN is the correct resource-level scope. This also
  pins the region through the ARN.
- Revoke by rule ID needs only the `security-group` resource type; `security-group-rule` is not
  listed for Revoke (row 4). No second Resource entry is expected for Revoke.
- Authorize: `security-group-rule` is optional and its policies apply only when TagSpecifications
  are sent (row 3). This design does NOT send tags (it encodes run id and expiry in the
  description), so no tag permission or tag condition is needed and none is relied on.
- Describe: no resource type is listed, so the policy uses `Resource: "*"` for read-only actions
  (row 7/8). Confirm with the IAM policy simulator before apply.
- Optional documented conditions that could be added without changing behavior: `ec2:Region`,
  `ec2:SecurityGroupID`, `ec2:Vpc` (row 5). They add nothing the ARN does not already enforce, so
  they are omitted to keep the policy simple.
- Not possible with IAM: restricting port, protocol, CIDR or description (row 6).
No instance, IAM, S3 or other permissions.

### What IAM does and does not enforce here
- Enforced by IAM [Verified, rows 1-2]: the role can change ingress only on the one security group.
- NOT enforceable by IAM [Verified, row 6]: the TCP port (22) and the source CIDR (/32). No
  documented condition key covers them. These properties are enforced by the workflow (next
  section) and detected by the sweeper and the alarms.

### Workflow-side enforcement (before and after the AWS call) [Design]
Before calling AWS:
1. Protocol, from port and to port are hard-coded constants in the workflow (`tcp`, 22, 22),
   never taken from inputs, variables or secrets.
2. Get the runner's public IPv4 once, from one fixed lookup, and require it to match a strict
   IPv4 pattern. Reject empty, malformed, IPv6, private, loopback or multi-value results.
3. Build the CIDR as `<ip>/32` itself. A prefix other than /32 is never constructed.
4. If any check fails, the job stops before any AWS call.
After the call:
5. Describe the created rule by its returned ID and assert protocol `tcp`, port 22 to 22, CIDR
   exactly the expected /32 and the expected description. On mismatch, revoke the rule by ID and
   fail the job.
6. Describe the whole group and fail the job if it holds any rule other than the ones this run
   created and the known live-run rules (unexpected ingress on the SSH group is an incident).

### Residual risk and mitigations
Because IAM cannot enforce port or CIDR, a compromised job in an allowed environment could
call Authorize with other values; the workflow checks would not stop code that bypasses them.
Mitigations (defence in depth, none a guarantee):
- Trust limited to two environments on `main`; production needs a human approval.
- The workflow files are protected by branch protection and PR review on `main`.
- PostgreSQL has no published host port, so opening 5432 would still reach nothing.
- The sweeper revokes and reports any rule on that group that is not tcp/22/32.
- The EventBridge rule and alarms below notify on suspicious changes.

## Short-lived sessions
- `role-duration-seconds` is set explicitly and kept short, but the permitted minimum and maximum
  were not verified (row 20). Value to be chosen in Phase 4 after reading the documented range for
  AssumeRoleWithWebIdentity. The deploy job timeout must be below the session length it needs.
- No credentials are stored in GitHub. `id-token: write` is granted only to deploy jobs.
- Local Terraform uses the existing `devops` CLI profile only; no permanent keys are created.

## GitHub Environment secrets and variables (names only, values never recorded)
Scoped per Environment (`staging`, `production`) so each has separate values.
| Name | Kind | Purpose |
|---|---|---|
| `AWS_ROLE_ARN` | variable | Role to assume through OIDC |
| `AWS_REGION` | variable | Region (ap-south-1) |
| `SSH_SG_ID` | variable | Dedicated SSH security group to open/close |
| `EC2_HOST` | secret | Server address (kept out of the repository) |
| `EC2_USER` | secret | Unprivileged deploy user |
| `SSH_PRIVATE_KEY` | secret | Dedicated deploy key for that environment |
| `SSH_KNOWN_HOSTS` | secret | Pinned host key line for strict verification |
Final names are confirmed in Phase 6 and listed in the README.

## SSH host key verification [Design]
1. After the instance first boots, obtain the host key fingerprint out-of-band (EC2 console output
   or a trusted local session), never through the workflow.
2. Store the full known_hosts line as the `SSH_KNOWN_HOSTS` secret.
3. Workflow writes it to a temporary file and connects with `StrictHostKeyChecking=yes` and
   `UserKnownHostsFile` pointing at it. No `ssh-keyscan` during the run (that would trust whatever answers).
4. The private key is written to a temp file with mode 600 and deleted in the cleanup step.
   Secrets are never echoed; no `set -x` around them.
5. Server side: key-only auth, no root login, no password auth, dedicated deploy user.
6. Key rotation: replace the key and the secret together; host key changes require updating the secret.

## Ingress cleanup, sweeper and alarms [Design: proposed values, nothing deployed]

### Proposed parameters
| Parameter | Proposed value | Notes |
|---|---|---|
| Temporary SSH rule expiry | 15 minutes | Encoded in the rule description as `gha-<run_id>-exp-<epoch>` |
| Sweeper interval | 5 minutes | Equals GitHub's documented shortest schedule interval (row 21); delays and dropped runs are possible |
| Deploy job timeout | 10 minutes or less | Must be shorter than the expiry so the sweeper never revokes a live deploy's rule |
| Sweeper workflow | scheduled `cron`, default branch only | Row 21: scheduled workflows only run on the default branch |
| Concurrency | one deploy per environment | Row 26 |

Nominal exposure after a hard kill: up to 15 minutes (expiry) plus up to 5 minutes (next sweep)
= about 20 minutes. It is NOT bounded: GitHub can delay or drop scheduled runs (row 21) and
disables them after 60 days of repository inactivity.

### Layers
1. Normal path: `if: always()` revoke step using the saved rule ID (also on failure and cancel).
2. Sweeper (GitHub scheduled workflow) assumes a second, narrower role that is limited to the
   same SG ARN for Revoke plus the Describe actions. Its trust `sub` is for the default-branch
   run (exact format to be confirmed from a real scheduled-run token, as in row 17).
   It revokes rules whose expiry has passed and any rule that is not tcp/22/32. Revocation is by
   rule ID, never by CIDR (rows 10-11: confirm the call form in Phase 4).
3. EventBridge rule (AWS-side, event-driven) on the default bus: `source` `aws.ec2`,
   `detail-type` `AWS API Call via CloudTrail`, `detail.eventName` in
   `AuthorizeSecurityGroupIngress` and `RevokeSecurityGroupIngress` (shape verified, row 22).
   It sends a notification when the SSH group is changed by anything other than the deploy and
   sweeper roles, or with other than tcp/22/32. The exact `requestParameters` field paths and the
   principal filter must be taken from a real CloudTrail event (row 23). Requires a CloudTrail
   trail with logging enabled (row 22), which is an extra resource to approve in Phase 4.
   Region placement, SNS target setup and the topic's resource policy are not verified (row 24).
4. Cleanup-failure alarm: after each sweep the sweeper reports metrics to CloudWatch
   (`ExpiredRulesFound`, `RevokeFailures`, and a `Heartbeat`). Alarms notify through SNS when
   `RevokeFailures` is above 0, when a rule older than its expiry remains after a sweep, or when
   the heartbeat is missing for more than 15 minutes (this also covers a sweeper disabled by
   GitHub's 60 day rule or dropped runs). This needs `cloudwatch:PutMetricData` on the sweeper role;
   how tightly that permission can be scoped is Not verified.
   The alarm is on the CloudWatch side; EventBridge is the event source for layer 3 only.
5. Fallback if this proves fragile: SSH over SSM Session Manager (port 22 never opened).

### Recovery procedure for expired or orphaned SSH rules
Run locally with the `devops` profile (no new keys); record each incident in PROJECT_STATUS.md.
1. Confirm the alert or the failed/missing sweeper run. Check whether a deploy is actually in
   progress (Actions tab) before touching any rule.
2. List the rules on the SSH group:
   `aws ec2 describe-security-group-rules --filters Name=group-id,Values=<SSH_SG_ID> --region ap-south-1 --profile devops`
   (the `--filters` form is shown in the CLI help; field names to be confirmed from real output).
3. Identify rules that are expired (past the epoch in the description), orphaned (no matching
   running workflow) or unexpected (not tcp/22/32). Treat an unexpected rule as a security incident:
   review the CloudTrail event before removing it.
4. Revoke by rule ID:
   `aws ec2 revoke-security-group-ingress --group-id <SSH_SG_ID> --security-group-rule-ids <rule-id> --region ap-south-1 --profile devops`
   (the `--security-group-rule-ids` flag exists, confirmed from local CLI help).
5. Re-list and confirm the group is empty of temporary rules.
6. Find why cleanup failed (runner loss, role or network error, sweeper disabled) and fix it; if
   the sweeper was disabled, re-enable it and add repository activity or a heartbeat commit.
7. Final check before submission (Phase 10): the SSH group has no ingress rules.

### Limitations of cleanup and recovery
- Hard kill, runner loss or an outage can skip the `if: always()` step; the rule stays open until
  the sweeper succeeds. Nominal bound about 20 minutes, no hard guarantee (row 21).
- The sweeper and the alarms depend on GitHub scheduling, the same OIDC trust and AWS
  availability; the heartbeat alarm detects, but does not repair, a dead sweeper.
- The expiry in the rule description is plain text; AWS does not enforce it. Only the sweeper
  acts on it. The description's allowed characters and length are Not verified (row 14).
- Rules for two runners sharing an IP are distinct by rule ID; cleanup uses the saved rule ID.
- A rule open for minutes still requires the private key and the pinned host key to be used, but
  it is exposure; it is reduced, not eliminated.
- If the workflow itself is compromised, the workflow-side checks are not a security boundary.
- The alarms and the CloudTrail trail add AWS resources and a small cost; each needs approval.

## Open items for Phase 4 (nothing is created now)
- Approve creating the OIDC provider, the deploy and sweeper roles and the SSH security group via Terraform.
- Obtain a real OIDC `sub` (deploy job and scheduled run) to fix `<SUB_PREFIX>` (row 17).
- Settle rows 9, 11, 12, 14, 20, 23, 24 from documentation or the IAM policy simulator before apply.
- Retrieve the official EC2 identity-based policy examples (the page returned no content) and
  compare them with the policy above.
- Decide on the CloudTrail trail, EventBridge rule, CloudWatch alarms and SNS topic.
- Terraform state stays local and git-ignored.
