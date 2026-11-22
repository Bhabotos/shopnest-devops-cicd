# Project execution roadmap

Date: 2026-11-21; status update added 2026-11-22 (see "Status update 2026-11-22" below). The task tables and sections 1 to 9 are the 2026-11-21 plan and are kept as history: where a task status there differs from the update, the update wins. Task rows were NOT individually re-graded on 2026-11-22.
Inputs: `docs/PROJECT_COMPLETION_AUDIT.md`, `PROJECT_STATUS.md`, `docs/REQUIREMENTS_CHECKLIST.md`, `assignment/GITHUB ACTIONS.docx` (text re-read),
`CLAUDE.md`, and spot checks of the repository for this review (section 1).
Numbering: roadmap phases are called **RP1-RP10** and tasks **T<phase>.<n>**, to avoid confusion with the older Phase 0-10 numbering in
`PROJECT_STATUS.md` (that table stays authoritative for the status tracker). Priorities: **P0** critical blocker, **P1** core functionality,
**P2** production readiness, **P3** documentation and final evidence. Complexity: Low / Medium / High (relative to this project).

## Status update 2026-11-22 (first read at `main` = `011752c`; updated after PRs #31 and #32 to `main` = `18943e5`)

Coarse state per roadmap phase. "Implemented, not executed" means merged code covered by offline or static checks only; nothing below has run on AWS.

| Phase | State on 2026-11-22 |
|---|---|
| RP1 decisions and housekeeping | T1.1 to T1.3 done. T1.4 (stale design documents) PARTIAL: this reconciliation covers the status documents; `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/OIDC_DESIGN.md` and `docs/GITHUB_SETUP.md` still describe the earlier SSH design (docs/AWS_STAGING_INTEGRATION.md section 16). D1 and D2 wait for the instructor; D5, D6 and D8 are open |
| RP2 README and CI completion | README merged (PR #10); Dependabot configured (PR #11; PRs #12 and #13 open); branch protection documented (PR #14); test PRs #15 to #19 merged (the owner must still adopt them, B4); B5 demonstrated on PR #28 by API observation, no screenshot of the blocked state; screenshots: the 13 Part H images are on `main` (PR #32), two partial; none for the CI triggers, matrix or job graph |
| RP3 application and database | Implemented, not executed against RDS (PR #23): RDS connection, TLS, secret retrieval, bootstrap, advisory lock, connectivity check. Not re-graded task by task |
| RP4 Terraform | Extended (PR #25: OIDC, CodeBuild, SSM documents, gated by `enable_cicd`). Not done: remote state (still local, unlocked), HTTPS (a recorded decision: HTTP only), a fresh plan, the apply. A local plan from 2026-11-21 (54 resources) is stale and must not be applied. AWS gates 1 and 2 are NOT passed |
| RP5 deployment code | Implemented, not executed (PRs #24 and #26): digest-based blue/green, S3 bundle, Systems Manager wrapper, rewritten `cd.yml` and `rollback.yml`; staging only, the production rolling deploy is not implemented |
| RP6 staging deployment | Not started: no Environment, variable or secret, no operator bootstrap, no deployment, no live URL |
| RP7 production gate and deployment | Not started. `cd.yml` has no production job and binds no `production` Environment, so no approval can be shown yet |
| RP8 zero-downtime and rollback on AWS | Not started on AWS; local and offline evidence only |
| RP9 Copilot and failures | Three deliberate failures run and recovered (runs 44884178546 / 44884710861, 44884809417 / 44885032635, 44920064307 / 44920708004; PR #28 stays open); write-ups on `main` (PR #29); the 13 screenshots are on `main` (PR #32). Copilot troubleshooting evidence UNAVAILABLE |
| RP10 final documentation | README merged; the 13 Part H screenshots are on `main`; other screenshots, the final all-history gitleaks scan and the clean-clone dry run pending |

## 1. Review of the audit (what was checked, what was wrong or missing)

Corrections to `docs/PROJECT_COMPLETION_AUDIT.md` found during this review (verified by reading files):

| # | Finding | Effect |
|---|---|---|
| 1 | Audit D3 said "`config/`/`deploy/env` examples only". There is no `config/` directory. Per-environment, non-secret settings DO exist and are tracked: `deploy/env/staging.env` and `deploy/env/production.env` (keys only checked, no values read into this document). `CLAUDE.md` still lists `config/` in the planned layout | D3 is PARTIAL (separate files exist; no GitHub Environments), not NOT IMPLEMENTED. The layout line in `CLAUDE.md` and the folder structure (I3) must be reconciled |
| 2 | Audit section 4 said request-timeout handling "needs a check". Checked: only database timeouts exist (`connectionTimeoutMs`, `statementTimeoutMs`, `shutdownTimeoutMs`); no HTTP request/header timeout is configured | request timeout is confirmed missing (task T3.4) |
| 3 | `PROJECT_STATUS.md` says 25 frontend tests; a count of `it(`/`test(` lines in `frontend/test/` finds 15 (parametrised tests may explain it) | test count is NEEDS VERIFICATION; do not quote a number in the README until a test run output is saved |
| 4 | Audit B3 "DONE" depends on our own interpretation of "build" for the backend (no compile step) | keep DONE only with the instructor-confirmation caveat |
| 5 | The audit did not list that the Terraform remediation log still says Terraform CI "has not run on GitHub" (now false: runs 44785811248, 44786392731) and that `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/OIDC_DESIGN.md`, `docs/GITHUB_SETUP.md` still describe the superseded design (single instance, SSH per-run rule, Docker-hosted PostgreSQL, `CLAUDE.md` rule 12 pointing at the SSH strategy) | stale documents are a marks risk for Part I and a consistency risk; task T1.4 |
| 6 | The audit did not say that the Part H "deployment failure" scenario and the B5 failing-check demonstration need no AWS and can run now; the YAML and test failures are independent of infrastructure | RP2 and RP9 are reordered: Part H work starts early (see sequence) |
| 7 | The audit did not call out the remote-state bootstrap problem: the state bucket and lock cannot be created by the configuration that will use them without a one-time local-state step | risk R7 and task T4.5 |
| 8 | The audit did not propose where the graded zero-downtime proof runs. Production needs two instances and a Multi-AZ database; staging has one instance and the existing on-host blue/green already works | decision D7: run the graded F proof on staging (cheaper, earlier), keep production rolling deploy as a second demonstration |
| 9 | Audit marks the rubric parts but not the submission-critical rules S4/S5 as marks-bearing risks: a missing live URL or a stopped server can zero out the evidence for E, F, G even if everything else is built | called out in section 8 |

No incorrect completion claim was found in the audit; the corrections above are understatements, omissions and one wrong path.
Not re-verified in this review: `terraform validate` results (taken from CI runs), the local rehearsal numbers (taken from the evidence files as cited in the checklist), and the contents of every Terraform file.

## 2. Decisions that gate the plan (owner: you; none decided)

| ID | Decision | Blocks | Recommendation |
|---|---|---|---|
| D1 | SSM Run Command instead of SSH for deployment (assignment says "over SSH") | T5.*, T6.*, all of Part E | ask the instructor in writing; keep SSM; justify in README. Fallback: documented, off-by-default per-run SSH path |
| D2 | Live URL policy (assignment requires it; also forbids server addresses in the repo) | S4, README, T10.* | ask the instructor; until answered no address anywhere in the repo |
| D3 | Domain for ACM/HTTPS, or accept HTTP | T4.6 | decide before the Terraform finish; HTTP-only is a documented trade-off |
| D4 | One `cd.yml` or `cd-staging.yml` + `cd-production.yml` | T5.7 | single `cd.yml` (keeps "production after staging" in one run) |
| D5 | Cost envelope and production topology (3 NATs, 2 ALBs, Multi-AZ RDS vs a reduced production) | T4.*, all AWS | get a priced estimate in T4.8 before any approval |
| D6 | Who writes what: B4 tests, Copilot prompts, screenshots | T2.4, T9.* | you; I prepare scaffolding and review |
| D7 | Where the graded zero-downtime proof runs (staging vs production) | T8.* | staging first |
| D8 | Whether "Deploy scripts and Compose" and the Terraform jobs become required checks | T2.3 | add "Deploy scripts and Compose"; Terraform only after a pass-through job exists |

### Decision status (updated 2026-11-21; recorded in `PROJECT_STATUS.md` decisions log)

| ID | Status | Answer |
|---|---|---|
| D1 | WAITING FOR INSTRUCTOR CONFIRMATION | no instructor reply exists; none assumed |
| D2 | WAITING FOR INSTRUCTOR CONFIRMATION | no instructor reply exists; none assumed; no address in any repository file |
| D3 | DECIDED (user) | HTTP only for now; documented trade-off |
| D4 | DECIDED (user) | single `cd.yml` |
| D5 | DEFERRED (user) | decide after the priced estimate in T4.8 |
| D6 | OPEN | not answered; treated as the working rule (user writes B4 tests, Copilot prompts, screenshots) until the user says otherwise |
| D7 | DECIDED (user) | staging first |
| D8 | OPEN | not answered; needs separate approval before any branch-protection change |

## 3. Sequence and dependency graph

```
RP1 decisions + housekeeping
  ├─> RP2 README skeleton, CI completion, B5 demo        (no AWS)
  ├─> RP9a Part H early: Copilot workflow, YAML + test failures (no AWS)
  └─> RP3 application + DB integration (local, disposable DB)
          └─> RP4 Terraform completion (code only) ─> AWS GATE-1 (auth, plan review) ─> AWS GATE-2 (apply staging)
                  └─> RP5 deployment code (ECR, SSM, RDS, rolling) ─ can be written in parallel with RP4, tested offline
RP6 staging deployment  (needs RP3, RP4 applied, RP5, OIDC role, Environments)
  └─> RP8 zero-downtime + rollback proof on staging
        └─> RP7 production gate + AWS GATE-3 (apply production) + production deploy
RP9b deployment-failure scenario (needs RP6)
RP10 final README, screenshots, evidence index, final history scan, dry run
```
Rules: no AWS work before RP3 code is tested and RP4 Critical/High findings are closed in code; no staging deployment before the OIDC role,
the SSM path and the ECR path exist; no production before staging passes; no rollback evidence before a working deployment.

## 4. Roadmap

### RP1 - Decisions and housekeeping (P0)
| Task | Rubric | Status | Required implementation (files) | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T1.1 | E, S4 | DONE 2026-11-21 (D1 and D2 recorded as waiting for the instructor; D3 and D5 recorded; the instructor question is drafted in `docs/INSTRUCTOR_CLARIFICATION_DRAFT.md` and NOT sent; it is for the user to send) | Obtain answers D1-D8; record in `PROJECT_STATUS.md` decisions log. Draft the instructor question on SSM and live URL (text only) | none | answers recorded with date; instructor reply kept as evidence if received | no server address in the question | D1, D2, D3, D5 answered or marked "waiting" | Low |
| T1.2 | I4 | DONE 2026-11-21 (PR #9 merged with a normal merge commit 75d1d93; post-merge CI run 44859967355 success) | Merge PR #9 (needs your approval; branch is behind `main`, strict protection may demand an update merge, never a rebase) | approval | PR merged, `main` CI green | none | `main` contains docs commit `3470d36` | Low |
| T1.3 | I4 | COMPLETE 2026-11-21: the audit and roadmap were committed through PR #9 (a24e7ca); the README, tracking updates and instructor draft were merged through PR #10 with a normal merge commit e6ed4571c96b8023d7e58a46770294867cb4844b (all five files present on `main`, all six PR checks passed, post-merge CI run 44862444476 success, source branch preserved) | Commit the README, the instructor draft and the tracking updates through a new docs branch and PR | T1.2, approval | PR checks green; gitleaks clean | secret scan before commit | both documents on `main` | Low |
| T1.4 | I1, I3 | PARTIAL | Reconcile stale docs: `CLAUDE.md` (layout, DB, SSH rule 12), `docs/ARCHITECTURE.md`, `docs/OIDC_DESIGN.md`, `docs/GITHUB_SETUP.md`, `infra/terraform/REMEDIATION_LOG.md` (Terraform CI line). `CLAUDE.md` changes need your approval because they are project rules | D1 | grep for "SSH", "single instance", "Docker" in docs; consistency read-through | keep rules 1-11 intact | no document contradicts the chosen design | Medium |

### RP2 - README skeleton and CI completion (P1 for marks, P3 for polish; no AWS)
| Task | Rubric | Status | Required implementation (files) | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T2.1 | A1-A4, C6, D5, F3, I1 | ACCEPTED by independent review 2026-11-21 (README.md; claims compared with workflows, Terraform, scripts, code and GitHub run history; links checked; both Mermaid diagrams rendered locally with mermaid-cli 11.4.2). Caveats: still UNCOMMITTED and not merged; GitHub's own rendering not verified; the reviewer was an AI assistant, so the owner's read-through is still advised | Create `README.md`: overview, stack, Part A section for management, incident-to-feature table, chosen approach, workflow/job/step/runner diagram (Mermaid or SVG checked against the real workflows), secrets/variables table (names and purposes), strategy and trade-offs, local setup, test commands. Sections not yet provable say "pending" | none (live URL stays a placeholder) | link and Markdown check; diagram compared line by line with `ci.yml`; a read-through by a second person | no address, key or ARN-like value; names only | every statement is true today or marked pending | Medium |
| T2.2 | B, C | PARTIAL | `.github/dependabot.yml` for npm (frontend, backend), GitHub Actions, Docker, Terraform | T1.2, approval | Dependabot runs appear; PRs not auto-merged | pinned versions kept | file valid; first PRs reviewed | Low |
| T2.3 | B5, C2 | PARTIAL | Document the required checks in the README; decide D8. Add a pass-through job to `terraform-ci.yml` so its checks can be required (branch-protection change needs your approval) | D8, approval | protection read-back via `gh api` | do not weaken admin enforcement | read-back matches README table | Medium |
| T2.4 | B4 | PARTIAL | You write the tests from `docs/PHASE2_TEST_SPECS.md`; I review | D6 | test run output saved under `docs/evidence/` | none | tests you can explain; CI green | Medium |
| T2.5 | B5 | PARTIAL | Demonstration PR on a throwaway branch with a deliberately failing required check; keep the failed run; show merge blocked | T2.3 | screenshot of the blocked merge, run URL; doubles as Part H test-failure scenario (T9.3) | throwaway branch only; never edit `main` | merge button blocked while the check fails; run kept | Low |
| T2.6 | B1-B3, C3, C5 | DONE (no screenshots) | Collect screenshots: triggers, frontend and backend steps, job graph, matrix, parallel timing | none | files in `docs/screenshots/` referenced by README | no secrets or account IDs visible | images resolve in the README | Low |

Gate RP2: README exists with no false statement; required checks documented and read back; B5 demo run kept; screenshots committed; all PR checks green.

### RP3 - Application and database integration (P0 for deployment; local, disposable DB only)
| Task | Rubric | Status | Required implementation (files) | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T3.1 | G1, E3 | NOT IMPLEMENTED | `/health/live` (process only) and `/health/ready` (database reachable, migrations applied); keep `/health` and `/version` compatible. `backend/src/app.js`, tests | none | unit and DB integration tests incl. "DB down: live 200, ready 503"; CI | no secrets or hostnames in responses | tests pass in CI on Node 22 and 24 | Low |
| T3.2 | E3, D2 | NOT IMPLEMENTED | Secrets Manager retrieval at start-up (AWS SDK v3, instance role), pool built from host/port/db/user/password, TLS with the RDS CA bundle (`rejectUnauthorized` on), retry with back-off; `DATABASE_URL` path kept for local use. `backend/src/db.js`, `config.js`, `server.js`, `migrate.js`, `seed.js`, `package.json` | none | tests with the SDK mocked; failure tests (secret missing, TLS error, timeout); local disposable Postgres run | never log secret values or full connection strings; no default password; dependency audit | app starts locally unchanged; AWS path proven only by mocks until RP6 (stated) | High |
| T3.3 | E8 | PARTIAL | Idempotent database bootstrap script for `shopnest_owner` / `shopnest_app` and a dedicated migration entrypoint with an advisory lock (deferred finding B6). `deploy/db/`, `backend/src/migrate.js` | T3.2 | run twice on a disposable local DB; per-role privilege checks (extend `verify-stack.sh`) | least privilege; no DELETE/TRUNCATE for the app role; no destructive migration against a non-disposable DB | second run is a no-op; checks pass | High |
| T3.4 | G | PARTIAL | HTTP request/header timeouts, shutdown draining check, structured log fields incl. release SHA | none | tests; graceful-shutdown test | none | requests over the limit time out cleanly | Low |
| T3.5 | B3 | PARTIAL | Extend CI so the new code paths run (mocked SDK tests, bootstrap idempotency job if it can run on a service container) | T3.1-T3.3 | CI green | none | new jobs green on PR | Medium |

Gate RP3: local tests and CI green; bootstrap twice-run proof; no secret in logs (existing "no secret in any log" test extended); security review of the diff; `docs/` updated. **Not** evidence for RDS until RP6.

### RP4 - Terraform completion and AWS gates (P0)
| Task | Rubric | Status | Required implementation (files) | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T4.1 | E1 | PARTIAL | Close Critical INT-01, INT-02, RDS-01 and High ALB-01, ST-01, ST-04, INT-03..06 from `ARCHITECTURE_SECURITY_REVIEW.md`; update `REMEDIATION_LOG.md` honestly (fixed in code vs verified) | D1, D3 | `terraform fmt`, `init -backend=false`, `validate`, Terraform CI; manual review per finding | least-privilege IAM, no wildcard, IMDS hop-limit decision (open decision 3) | each finding has status "fixed in code" with the diff, or "accepted risk" with your sign-off | High |
| T4.2 | D6, E | NOT IMPLEMENTED | GitHub OIDC provider and roles per environment (staging, production) with `sub` conditions bound to the repository, environment and branch; permissions: ECR push/pull, S3 artifact write, `ssm:SendCommand` on named instances and one document, `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation`. `infra/terraform/iam.tf` (or `oidc.tf`), `docs/OIDC_DESIGN.md` | T4.1 | policy review; IAM simulator only after authentication (approval) | no wildcards; no long-lived keys; trust policy pinned to this repo and environment | design doc matches code | High |
| T4.3 | E | PARTIAL | ECR repositories with immutable tags, scan on push, lifecycle sized so rollback targets survive | T4.1 | validate | immutable tags | digest recorded per release | Medium |
| T4.4 | G4 | NOT IMPLEMENTED | CloudWatch log groups, alarms, ALB 5xx and target-health alarms; retention set | T4.1 | validate | log groups encrypted if feasible; no secrets in logs | log retention and alarms defined | Medium |
| T4.5 | E | NOT IMPLEMENTED | Remote state: S3 (encrypted, versioned, blocked public access) with locking, bootstrapped by a one-time documented step; per-environment state | T4.1, approval to authenticate | documented bootstrap; `terraform init` against the backend (AWS gate) | state may contain sensitive values: bucket policy, encryption, access limited | backend works; lock tested | High |
| T4.6 | E, S4 | NOT IMPLEMENTED | ACM certificate and HTTPS listener if D3 gives a domain; otherwise document HTTP-only | D3 | validate; later a certificate-status check | TLS 1.2+ policy | HTTPS works or the trade-off is documented | Medium |
| T4.7 | E1 | PARTIAL | Make `allowed_account_ids` and the root-identity guard part of the documented workflow; example variable files stay free of real IDs | T4.1 | `terraform validate`; plan-time check (AWS gate) | no account IDs in the repo | untracked variable files documented | Low |
| T4.8 | E1 | NOT IMPLEMENTED | **AWS GATE-1 briefing** (no AWS action): resource list, priced estimate, security impact, destructive changes, teardown plan; then, with your approval, authenticate with profile `devops` (never `lab`, never root) and run `terraform plan` for staging; review it with you | T4.1-T4.7, D5 | plan output saved only after redaction review; reviewed together | no credentials in output; redact account IDs | plan reviewed, zero unexpected changes | Medium |
| T4.9 | E1 | NOT IMPLEMENTED | **AWS GATE-2**: separate approval to apply staging; post-apply read-only checks (RDS private, no 0.0.0.0/0 except ALB, SSM online) | T4.8, approval | `docs/evidence/infra/` real outputs | verify DB has no public route | staging resources exist and match the plan | High |

Gate RP4 (code part): validate and Terraform CI green, every Critical/High finding closed or signed off, cost estimate approved. Gate RP4 (AWS part): reviewed plan, applied only after explicit approval.

### RP5 - Deployment code for SSM, ECR and RDS (P1; written and tested offline)
| Task | Rubric | Status | Required implementation (files) | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T5.1 | E3 | NOT IMPLEMENTED | `deploy/docker-compose.prod.yml` without `db`/`pgdata`/`db-init`; RDS host from configuration; RDS CA bundle mounted | T3.2 | `docker compose config` in CI; the CI compose check rewritten | no password in compose; non-root containers kept | compose validates; offline suite updated | Medium |
| T5.2 | E6 | NOT IMPLEMENTED | ECR publishing: build once, tag with the commit SHA, push, record the digest, verify the digest and revision label on the host. `bluegreen-deploy.sh`, `bluegreen-lib.sh` | T4.2, T4.3 | offline tests; a real push only at RP6 | immutable tags; verify digest not tag | deploy refuses an unverified image | High |
| T5.3 | E, G4 | NOT IMPLEMENTED | S3 artifact path for `deploy/` scripts, nginx config and frontend files: publish with checksums, instance-side fetch and verification | T4.2 | offline tests | SSE, TLS-only, checksum verified before use | tampered artifact rejected in a test | Medium |
| T5.4 | E2, G | NOT IMPLEMENTED | SSM execution wrapper: send command, wait, map `ResponseCode` to exit codes 0/1/3, collect output as an artifact | D1 | shellcheck and offline tests with stubbed `aws` | no secret in command text or logs | exit codes preserved | High |
| T5.5 | F1 | PARTIAL | Staging: keep on-host blue/green. Production: rolling deploy across two instances behind the ALB (deregister, update, wait healthy, next); stop on first failure | T3.1, T5.4 | offline logic suite extended; ALB behaviour proven only at RP7 | previous release stays serving | logic suite covers success, first-instance failure, recovery failure | High |
| T5.6 | G2, G3 | PARTIAL | Rollback by SHA via ECR digest history (state in S3 or per instance), reason recorded; never reverse migrations automatically | T5.2, T5.4 | offline tests | verify digest before restoring | rollback selects only known-good recorded releases | Medium |
| T5.7 | C1, E2, E5, E6, G | PARTIAL | Rewrite `cd.yml` and `rollback.yml` (OIDC, ECR, S3, SSM; no SSH, no SCP; gate on successful CI for the exact SHA; environment per job; deployment history; per-job `permissions`; pinned actions). Update the `ci.yml` check that diffs the SSH steps | T5.1-T5.6, D4 | `actionlint`, YAML parse, dry-run with `CD_ENABLED` unset (job skipped) | `id-token: write` only on deploy jobs; no secrets in logs | workflows lint clean and stay disabled until RP6 | High |

Gate RP5: offline suites and CI green; `actionlint` clean; no SSH/SCP strings left in workflows; documentation of required variables and secrets (names only).

### RP6 - Staging deployment (P1)
| Task | Rubric | Status | Required implementation | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T6.1 | D2, D3 | NOT IMPLEMENTED | Create GitHub Environments `staging`, `production` and the variables (names planned in README); set `CD_ENABLED` last (all need your approval) | T4.9, T5.7 | read-back via `gh api` | no AWS keys in secrets; variables reviewed against rule 1 | environments exist with separate values | Low |
| T6.2 | E3, E8 | NOT IMPLEMENTED | Operator bootstrap of database roles and the `db-app` secret (out-of-band, no secret in any log) | T3.3, T4.9 | role/privilege queries (saved without secrets) | master secret handled by you or by Secrets Manager only | roles exist; app role privileges verified | High |
| T6.3 | E2, E5, E6 | NOT IMPLEMENTED | First staging deployment from `main` after CI; verify readiness, frontend, API, DB connectivity, SHA | T6.1, T6.2 | CD run URL, logs, `/version` equals the commit SHA | none | green run; same SHA in image tag, `/version`, log | High |
| T6.4 | E4 | NOT IMPLEMENTED | External port 5432 test and security-group read-back | T6.3 | outputs and screenshot | verify from outside the VPC | connection refused/timeouts; no DB rule from the internet | Low |
| T6.5 | E5 | NOT IMPLEMENTED | Show CD does not start when CI fails | T6.3 | skipped CD run URL | none | no deployment on failed CI | Low |

### RP7 - Production approval gate and production deployment (P2)
| Task | Rubric | Status | Required implementation | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T7.1 | D4 | NOT IMPLEMENTED | `production` Environment with required reviewers (your approval) | T6.3 | screenshot of the paused run | reviewer is you, not the bot | job waits; nothing deploys before approval | Low |
| T7.2 | E | NOT IMPLEMENTED | **AWS GATE-3**: production plan (2 instances, NAT per AZ, Multi-AZ RDS) priced and reviewed; separate approval to apply | T4.8, D5 | reviewed plan; post-apply checks | same as GATE-2 | production matches plan | High |
| T7.3 | E, F | NOT IMPLEMENTED | Production deployment: exact commit and image digest recorded; rolling deploy | T7.1, T7.2, T5.5 | run URL, deploy log | digest pinned | both instances serve the new release | High |

### RP8 - Zero-downtime and rollback proof on AWS (P1 marks)
| Task | Rubric | Status | Required implementation | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T8.1 | F2 | PARTIAL (local only) | Request loop run from outside against the real endpoint during a staging deployment (total, success, failed, 5xx, duration, recovery) | T6.3 | raw log kept, counts computed from the log | the loop sends only GET to public endpoints | counts reported exactly; if any request fails, say so and explain | Medium |
| T8.2 | G2, G5 | PARTIAL (local only) | Deliberately broken release through the real pipeline: A good, B broken, validation fails, automatic recovery; measure duration | T6.3 | run URL, logs, release history, request loop | broken release is a test image on staging only | recovery without manual action | Medium |
| T8.3 | G3 | PARTIAL (local only) | Manual rollback via `rollback.yml` to a named older SHA; verify digest and `/version` | T6.3, T5.6 | run URL, logs | environment protection applies | `/version` equals the chosen SHA | Medium |
| T8.4 | F, G | NOT IMPLEMENTED | Repeat T8.1-T8.3 on production if budget allows | T7.3 | same | same | optional; claim only what was run | Medium |
| T8.5 | F1 | PARTIAL | Address the known ~20 s post-switch failure window (ALB health-based draining) or document it as a limit | T5.5 | measured before and after | none | claim matches the measurement | Medium |

### RP9 - Copilot and failure scenarios (P1 for 10 marks; start early)
| Task | Rubric | Status | Required implementation | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T9.1 | H1-H3 | NOT IMPLEMENTED | You use GitHub Copilot to generate a workflow (for example a small, isolated demonstration workflow, or a new workflow file); commit Copilot's unedited output first, then each edit with its reason | D6 | prompts verbatim, transcript or screenshots, commit links in `docs/copilot/` | never paste secrets into Copilot; the file must be your real session | unedited commit exists before any edit | Medium |
| T9.2 | H4-H7 (YAML) | NOT IMPLEMENTED | YAML syntax failure on a throwaway branch; keep the failed run; troubleshoot with Copilot; fix | T9.1 | `docs/failures/01-yaml/` with run URL, screenshot, root cause, Copilot prompt and answer, fix commit | never on `main` or the CD workflow | failed run exists and is kept | Low |
| T9.3 | H4-H7 (test) | NOT IMPLEMENTED | Test failure; may reuse T2.5 | T2.5 | `docs/failures/02-test/` | same | same | Low |
| T9.4 | H4-H7 (deploy) | NOT IMPLEMENTED | Deployment/connection failure in an isolated demonstration workflow or on staging (for example a wrong target tag) | T6.3 | `docs/failures/03-deploy/` | staging only | same | Medium |

### RP10 - Final documentation and submission evidence (P3)
| Task | Rubric | Status | Required implementation | Depends | Validation and evidence | Security | Acceptance | Cx |
|---|---|---|---|---|---|---|---|---|
| T10.1 | I1, I2, I5, S3 | NOT IMPLEMENTED | Complete the README: architecture, CD diagram, AWS architecture, Terraform and secure deployment setup, variables and secrets, deployment, approval, blue/green and rollback instructions, failures, troubleshooting, screenshots, run links, live URL if D2 allows | all | link check; every statement traced to evidence | names only; no addresses unless D2 resolved | a reader can reproduce from the README | Medium |
| T10.2 | I | PARTIAL | Update `PROJECT_STATUS.md`, `docs/REQUIREMENTS_CHECKLIST.md`, architecture, deployment, security docs, add `docs/EVIDENCE_INDEX.md` (rubric requirement, implementation file, test or workflow, evidence location, result) | all | each row has real evidence or says pending | none | no row marked done without evidence | Medium |
| T10.3 | D1 | NEEDS VERIFICATION | Final gitleaks over the full history of all refs plus a grep for addresses; keep the output | all | `docs/evidence/secret-scan/` | repo is public: any hit is 0 marks for D | clean | Low |
| T10.4 | I5 | NOT IMPLEMENTED | Clean-clone dry run following only the README | T10.1 | notes of every gap found and fixed | no personal paths or secrets in notes | dry run succeeds | Medium |
| T10.5 | S1, S2, S5, S6 | NEEDS VERIFICATION | Public repo opened logged out; Actions history intact (no run deleted); server up through grading; the work is yours | all | checklist ticked with dates | none | all submission rules checked | Low |

## 5. Completion gates (per phase, objective)

A phase closes only when **all** apply: (1) static validation clean (`lint`, `terraform fmt/validate`, `actionlint`, `shellcheck`, YAML parse where relevant);
(2) relevant automated tests pass locally **and** in GitHub Actions on a PR; (3) security check: `gitleaks` on the working tree, the staged diff and the
added lines, plus a review of IAM, network and logging changes; (4) integration test where the phase touches a service (disposable DB for RP3, real
staging for RP6/RP8); (5) the checklist and `PROJECT_STATUS.md` updated with real evidence locations and run numbers; (6) a phase report in the
format you asked for (objective, files inspected/modified, details, tests, results, security, outstanding issues, acceptance, approvals).
Code that only passes validation is reported as "implemented in configuration", never as deployed.

## 6. Approval boundaries (nothing below is done without your explicit approval for that action)

| Action | Where it first arises |
|---|---|
| Git staging and commits (exact paths only) | every phase; first: T1.3 (audit and roadmap files are currently uncommitted) |
| Git push and PR creation | T1.3 onward |
| Merging a PR (including PR #9) | T1.2 |
| Updating a branch with `main` (merge commit, never rebase) | T1.2 if required |
| GitHub settings: branch protection, required checks | T2.3 |
| GitHub Environments, variables, secrets, `CD_ENABLED`, reviewers | T6.1, T7.1 |
| Enabling Dependabot (new workflow-like config; PR required) | T2.2 |
| Changing `CLAUDE.md` project rules | T1.4 |
| AWS authentication (profile `devops` only) | T4.5, T4.8 |
| `terraform plan` | T4.8 |
| `terraform apply` (staging, then production, separately) | T4.9, T7.2 |
| Terraform `destroy`, `import`, state commands | never without a dedicated approval |
| AWS resource creation or change by any other route | never; Terraform only |
| Operator bootstrap on RDS, secret creation in AWS | T6.2 |
| Deployment, rollback runs, deliberately broken releases | T6.3, T8.*, T9.4 |
| Docker or database operations that remove data (volumes, databases) | never without a dedicated approval; disposable-project use for tests is stated per task |
| Contacting the instructor | T1.1 (you send it) |

## 7. Risks and sources of lost marks

| ID | Risk | Marks at risk | Mitigation |
|---|---|---|---|
| R1 | SSM rejected as "not SSH" | up to 15 (E) plus parts of G | D1 early; keep a documented SSH fallback |
| R2 | A credential or server address in history or README | all 10 of D | gitleaks on every push, final all-refs scan, no address until D2 |
| R3 | README missing (today; resolved 2026-11-21 by PR #10) | A 5, C6 part of 10, D5 part of 10, F3, I 5 | RP2 first |
| R4 | Evidence is local-only for F and G | most of F 15 and G 15 | RP6, RP8 on real AWS; never claim zero downtime without it |
| R5 | No failed runs yet (resolved 2026-11-21 and 2026-11-22: five failed runs exist, none may be deleted) | H4-H7, S2 | RP9 early |
| R6 | Terraform never planned; unknown provider or IAM errors; `rds_superuser` grant limits | schedule, E | staging plan first; rehearsal on staging |
| R7 | Remote-state bootstrap ordering | E schedule | one-time documented bootstrap, separate approval |
| R8 | Cost (3 NATs, ALBs, Multi-AZ RDS, running until grading) | S5, budget | priced estimate at T4.8; teardown plan; reduced production if needed |
| R9 | Backend AWS path tested only with mocks until RP6 | E3 | state it plainly; test on staging early |
| R10 | Plagiarism rule and AI-written tests/prompts | whole assignment (S6), B4, H | you write B4 tests and Copilot prompts; keep authorship honest |
| R11 | HTTPS needs a domain | S4 quality | D3 |
| R12 | Branch behind `main` under strict protection | process | update by merge, with approval |
| R13 | Single CD workflow gate runs on `workflow_run` of CI for `main` only | E5 clarity | document; test with a failing CI |

Estimated marks at risk (planning estimate, not a grade; assumes today's repository): A 5/5 at risk; B about 3-5 of 15 (B4 own tests, B5 demo, screenshots);
C about 4-5 of 10 (CD never runs, no diagram, no screenshots); D about 6-8 of 10 (no Environments, approval gate, README list; and all 10 if anything leaks);
E about 12-15 of 15; F about 10-15 of 15 (local evidence only); G about 10-14 of 15; H 10/10 at risk; I about 4-5 of 5. Roughly 60-80 of 100 marks are
currently unproven. These bands are judgement, not measurements.

## 8. Critical blockers (as of 2026-11-21; items 1, 3, 5 and 6 are resolved or changed, see section 8a)

1. No README (A, C6, D5, F3, I).
2. SSM vs SSH and live-URL questions unanswered (D1, D2).
3. Backend cannot run against RDS (no Secrets Manager, no TLS, no ready/live endpoints).
4. Terraform has never been planned; Critical/High review findings open; no OIDC role, no remote state, no CloudWatch, no HTTPS.
5. Deployment workflows are SSH-based, disabled and never run; no Environments, secrets or variables exist.
6. No failed runs and no Copilot evidence.
7. Cost and topology not approved.

## 8a. Current blockers (2026-11-22)

1. Instructor answers pending: SSM instead of the assignment's "over SSH" wording (D1) and the live-URL policy (D2). Neither is assumed.
2. GitHub is unconfigured: 0 Environments, 0 variables, 0 secrets, `CD_ENABLED` unset; no `production` Environment, and `cd.yml` has no production job, so Part D's approval gate cannot be shown.
3. The real GitHub OIDC `sub` claim was never captured and whether an OIDC provider already exists in the AWS account is unknown, so the OIDC resources cannot be applied.
4. A fresh `terraform plan` is required (the 2026-11-21 plan is stale), then explicit approval for the apply; the cost envelope (D5) and budget are not decided.
5. Operator steps not done: the `db-app` and `db-owner` secrets, the host settings file, the database bootstrap. The first deploy is expected to stop at the migrator by design.
6. How staging gets a demo catalogue is undecided (the seed policy refuses staging).
7. Copilot troubleshooting evidence is unavailable and cannot be reconstructed; B4 test ownership is the owner's; screenshots are mostly missing.
8. Production is not implemented (no rolling deploy, no production Terraform plan or approval).

## 9. Exact next task

Update 2026-11-22: T1.1 to T1.3 and T2.1 are done. PRs #31 (status reconciliation) and #32 (Part H screenshots) are merged; follow docs/SUBMISSION_READINESS.md section 7 for the remaining steps. The text below is the 2026-11-21 plan, kept for history.

**T1.1 then T2.1.** Concretely, after your answers to D1-D8 (at minimum "waiting on the instructor" for D1/D2) and your approval to commit the audit and roadmap
(T1.3) and merge PR #9 (T1.2), implement **T2.1: create `README.md`** on a new `docs/` branch. It needs no AWS, carries the largest unproven mark total per hour
(Parts A, C6, D5, F3, I), and every later phase will extend it. T2.1 does not start until you approve.
