# Project completion audit (Phase 0, read-only)

Audit date: 2026-11-21. Source of requirements: `assignment/GITHUB ACTIONS.docx` (Parts A-I, 100 marks; text re-read for this audit).
Method: git, `gh` read-only queries, and reading files. Nothing was run against AWS, Terraform, Docker or a database. No application,
infrastructure or workflow file was modified. This document is the only file created by the audit.

Classes: **DONE** (real evidence exists), **PARTIAL**, **NOT IMPLEMENTED**, **BLOCKED** (cannot proceed without a decision or an earlier item),
**NEEDS VERIFICATION** (probably true, not re-proved). "Config only" means written, never deployed. A passing static check is not a deployment.

## 1. Verified repository and GitHub state

| Item | Verified fact (2026-11-21) |
|---|---|
| Local branch / HEAD | `docs/update-terraform-phase-status` at `3470d36`, working tree clean before this file |
| `origin/main` | `2ed1f58` (merge of PR #8); the docs branch is one commit behind it, GitHub reports PR #9 `CLEAN` |
| PRs | #1-#8 merged with normal merge commits; **#9 open** (docs only, commit `3470d36`); no other open PR |
| PR #9 checks | all six CI jobs pass (Frontend 22/24, Backend 22/24, Backend Docker image, Deploy scripts and Compose), run 44858849602. Terraform CI did not run (path-filtered, no Terraform change) |
| Latest `main` runs | CI 44786392818 success; Terraform CI 44786392731 success; CD 44786557196 **skipped** (`CD_ENABLED` unset) |
| Failed runs | **None exist in the repository.** Part H (three kept failed runs) and S2 have no failed-run evidence yet |
| Branch protection (`main`) | 5 required checks (Frontend 22/24, Backend 22/24, Backend Docker image), strict up-to-date, enforced for admins. "Deploy scripts and Compose" and all Terraform CI jobs are NOT required |
| GitHub Environments | **none** (staging, production not created) |
| Actions secrets / variables | **0 secrets, 0 variables** (so `CD_ENABLED` is unset) |
| Dependabot | not configured (`.github/dependabot.yml` absent) |
| README.md | **does not exist** |
| `docs/screenshots/`, `docs/failures/`, `docs/copilot/` | **do not exist** |
| Workflows | `ci.yml` (201 lines), `cd.yml` (441, disabled draft, SSH-based), `rollback.yml` (222, never run, SSH-based), `terraform-ci.yml` (106) |
| AWS | no resource, no authentication, no plan or apply (per status documents; not contradicted by anything found) |

Observation on the instruction "fix the outstanding B5 failing check": no check is failing. B5 is open because nobody has yet shown a pull
request with a failing required check being blocked. It needs a deliberate demonstration (planned with Part H), not a fix.

## 2. Contradictions and decisions needed before work starts

These need your answer. Nothing below has been decided by the audit.

1. **SSM vs "over SSH" (Part E).** The assignment says a merge "deploys automatically to the EC2 server over SSH". Your master instruction and the
   Terraform design forbid port 22 and require SSM Run Command. A grader reading Part E literally may not accept SSM. Options: (a) ask the
   instructor in writing and keep the answer as evidence; (b) keep SSM and justify it in the README; (c) support a documented, off-by-default
   per-run SSH path (the earlier design in `docs/OIDC_DESIGN.md`). Recommendation: (a), then (b) unless the instructor refuses. Up to 15 marks depend on it.
2. **Live URL vs "no server address in the repository" (S4 vs D1).** The assignment requires the live URL in the README and also forbids any
   server address in the repo. `CLAUDE.md` rule 11 keeps the URL out until the instructor clarifies. Still pending; blocks S4. A stable DNS name
   or ALB hostname in the README may be exactly what the assignment wants, but it is a risk for Part D if the grader reads it as a "server address".
3. **HTTPS with ACM needs a domain.** ACM public certificates require a domain you control and validate. No domain is known. Without one the ALB
   can only serve HTTP (or a self-signed certificate that browsers reject). Decide: buy/use a domain, or accept HTTP and document it.
4. **Workflow layout.** You asked for `cd-staging.yml`, `cd-production.yml`, `rollback.yml`. The assignment needs only "separate workflows for CI and
   CD", and the existing `cd.yml` already chains staging then production. Splitting is possible but makes "production only after staging succeeded"
   harder (needs `workflow_run` chaining or reusable workflows). Recommendation: keep one `cd.yml` rewritten for SSM/ECR, unless you want the split.
5. **Cost.** The target is 3 EC2 instances, 3 NAT Gateways (2 production AZs plus 1 staging), an ALB per environment, Multi-AZ RDS in production,
   plus ECR, S3, CloudWatch. NAT Gateways and Multi-AZ RDS dominate; the Terraform log estimated about $37-45 a month just for the extra production NAT.
   The server must keep running until grading ends (S5). A real cost estimate is needed before any approval; consider whether the assignment
   needs production Multi-AZ, or whether a smaller production topology (documented as a trade-off) is acceptable.
6. **Evidence authorship.** Copilot prompts and screenshots (Part H) must be yours and real (`CLAUDE.md` rules 8, 9). I can prepare the scaffolding
   and failure branches; you must run Copilot, take the screenshots and supply the prompts and answers.
7. **B4 ownership.** The 64 existing tests were AI-assisted. The assignment asks for tests "you write yourself". `docs/PHASE2_TEST_SPECS.md` lists the
   tests you are to write; they are not done.
8. **Instructor confirmations outstanding:** live URL; SSM vs SSH; the meaning of "build" for a backend with no compile step (our interpretation: image build plus startup validation).

## 3. Requirement-by-requirement audit

Evidence paths are relative to the repository. "Local" = Docker Desktop on the development machine only.

### Part A - concepts (5)
| ID | Class | Current state | Missing |
|---|---|---|---|
| A1-A3 | NOT IMPLEMENTED | no README exists | README section for management: CI vs Delivery vs Deployment; fix for each of three incidents; chosen approach and why |
| A4 (R) | NOT IMPLEMENTED | secret guard and scans exist (`docs/evidence/secret-scan/`, `docs/evidence/phase2/`) | mention the 4th incident |

### Part B - CI (15)
| ID | Class | Current state | Missing |
|---|---|---|---|
| B1 | DONE | `ci.yml` on push to main and pull_request; many green runs (e.g. 44858849602, 44786392818) | screenshot |
| B2 | DONE | frontend install, lint, test, build on Node 22 and 24 | screenshot |
| B3 | DONE (interpretation) | backend install, lint, 39 tests against a PostgreSQL service on Node 22 and 24, plus an image build job | instructor confirmation of "build"; screenshot |
| B4 | PARTIAL | 64 tests exist, AI-assisted | the tests you write (`docs/PHASE2_TEST_SPECS.md`) |
| B5 | PARTIAL | protection applied and read back live today (5 contexts, strict, admins) | a PR whose required check fails and is blocked; screenshot |

### Part C - workflow architecture (10)
| ID | Class | Current state | Missing |
|---|---|---|---|
| C1 | PARTIAL | `ci.yml` and `cd.yml` exist; CD only ever `skipped` | an enabled CD that actually runs |
| C2 | PARTIAL | CI `needs` chain; CD graph (gate, package, staging, production, report) never past the gate | CD graph evidence |
| C3 | DONE | matrix jobs ran concurrently (run 44714705352) | screenshot |
| C4 | PARTIAL | CI uploads `frontend-dist-node22/24`; CD download unexercised | CD artifact hand-off (will change with ECR/S3 delivery) |
| C5 | DONE | Node 22 and 24, frontend and backend | screenshot |
| C6 | NOT IMPLEMENTED | - | README diagram of workflows, jobs, steps, runners |

### Part D - secrets and configuration (10; 0 if any credential in history)
| ID | Class | Current state | Missing |
|---|---|---|---|
| D1 | NEEDS VERIFICATION | gitleaks scans clean 2026-11-20; GitHub secret scanning and push protection enabled; today's staged and `origin/main..HEAD` scans clean | final full-history scan before submission; the personal email in commit `668a93e` metadata is a known non-credential risk |
| D2 | NOT IMPLEMENTED | 0 secrets, 0 variables; nothing uses any | decide the final secret/variable set (OIDC removes AWS keys; see section 6) |
| D3 | NOT IMPLEMENTED | `config/`/`deploy/env` examples only; no GitHub Environments | `staging` and `production` Environments with separate variables (needs your approval) |
| D4 | NOT IMPLEMENTED | `cd.yml` references a production environment; none exists | environment with required reviewers (needs your approval) |
| D5 | NOT IMPLEMENTED | - | README table of every secret and variable by name and purpose |
| D6 (R) | PARTIAL | design only (`docs/OIDC_DESIGN.md`); instance role in Terraform | OIDC provider and deploy roles; the design still assumes SSH and must be redesigned for SSM/ECR |

### Part E - EC2 deployment (15)
| ID | Class | Current state | Missing |
|---|---|---|---|
| E1 | PARTIAL | Terraform merged (PR #8); fmt/validate/secret scan green; **no plan, no apply, no resource** | AWS authentication (your approval), real plan, review, approved apply; closing Critical INT-01, INT-02, RDS-01 and High ALB-01, ST-01, ST-04, INT-03..06 |
| E2 | BLOCKED | `cd.yml` is SSH-based, disabled | decision 1; rewrite for SSM; infrastructure and OIDC role first |
| E3 | NOT IMPLEMENTED | frontend/backend/DB reachable only in local Compose | prod compose for RDS (no `db` service), backend RDS TLS and Secrets Manager retrieval, DB role bootstrap, migrations on RDS |
| E4 | PARTIAL | RDS `publicly_accessible = false`, DB security group admits the backend group only (read in `rds.tf`, `security.tf`) | an external port 5432 test after deployment |
| E5 | PARTIAL | `cd.yml` triggers via `workflow_run` on CI success with a gate job; never exercised past the gate | a real run, and a failing-CI case showing no deploy |
| E6 | PARTIAL | `/version` and image-label verification exist in scripts; CD never ran | SHA visible in image tag, `/version`, deploy log on a real deployment |
| E7 (R) | PARTIAL | Terraform has no inbound SSH; workflows still open port 22 | superseded by SSM migration (decision 1) |
| E8 (R) | PARTIAL | two PostgreSQL roles verified in local Compose (62/62) | bootstrap on RDS (rds_superuser limits unverified) |

### Part F - zero downtime (15)
| ID | Class | Current state | Missing |
|---|---|---|---|
| F1 | PARTIAL (local only) | blue/green with nginx rehearsed locally (attempts 3-5) | redesign for ALB and two instances (rolling), not just one host |
| F2 | PARTIAL (local only) | 238/238, 107/107, 161/161 requests OK locally; a post-switch fault still cost 79 of 171 requests | a request loop against AWS during a real deployment; the post-switch window (about 20 s) is an unresolved weakness |
| F3 | NOT IMPLEMENTED | - | README strategy and trade-offs |

### Part G - monitoring and rollback (15)
| ID | Class | Current state | Missing |
|---|---|---|---|
| G1 | PARTIAL (local only) | `/health` and `/version` checks in scripts | run in CD; new `/health/live`, `/health/ready` |
| G2 | PARTIAL (local only) | pre-switch rejection and post-switch rollback verified in local Docker; exit code 3 offline only | AWS/staging run |
| G3 | PARTIAL (local only) | `rollback.sh` verified locally; `rollback.yml` **never run** | SSM-based workflow, a real run |
| G4 | PARTIAL | logs written per release and captured locally | logs as workflow artifacts from a real run |
| G5 | PARTIAL (local only) | local deliberate-break rehearsals | staging demonstration through CD |
| G6 (R) | PARTIAL (local only) | local request loop and history | staging |

### Part H - Copilot and failures (10)
| ID | Class | Current state | Missing |
|---|---|---|---|
| H1-H3 | NOT IMPLEMENTED | `docs/copilot/` absent | your real Copilot session: prompts, unedited output committed first, diff and reasons |
| H4-H7 | NOT IMPLEMENTED | no failed run exists | three kinds of failure (YAML syntax, test failure, deployment/connection failure) on a throwaway branch, screenshots, root cause, Copilot troubleshooting, fix commits |

### Part I - documentation (5)
| ID | Class | Current state | Missing |
|---|---|---|---|
| I1, I2, I5 | NOT IMPLEMENTED | no README, no screenshots | whole README; screenshots; a clean-machine dry run |
| I3 | NEEDS VERIFICATION | layout follows the plan | final tree review |
| I4 | PARTIAL (good) | 9 PRs, Conventional commits | keep the discipline; one CI-failing PR planned for B5 |

### Submission rules
| ID | Class | Note |
|---|---|---|
| S1 | NEEDS VERIFICATION | repo is public; open it logged out at the end |
| S2 | PARTIAL | no run has ever been deleted (none failed yet); failed runs will be created for Part H |
| S3 | NOT IMPLEMENTED | no screenshots exist |
| S4 | BLOCKED | decision 2 |
| S5 | BLOCKED | needs deployed infrastructure and a cost decision |
| S6 | NEEDS VERIFICATION | depends on your own prompts and understanding of every file |

## 4. Gaps in the application against your Phase 3 list (read from `backend/src`)

- **Health:** only `GET /health` (does `SELECT 1`) and `GET /version`. `/health/live` and `/health/ready` do not exist. Today a database outage makes the ALB mark every target unhealthy (documented in INTEGRATION_GAPS section 7).
- **Database config:** `DATABASE_URL` only; no TLS, no AWS SDK, no Secrets Manager. Pool timeouts and graceful shutdown already exist (Phase 2 remediation).
- **Migrations and roles:** migrations exist; `deploy/db/init/01-roles.sh` runs only on an empty local Postgres directory. On RDS the bootstrap must be an operator step using the master secret; whether every grant works under `rds_superuser` is unverified.
- **Request timeouts, structured logs, release SHA:** structured logger and `/version` exist; request-timeout handling needs a check.

## 5. Recommended implementation sequence

Each step is its own approval. AWS operations are separate approvals and are listed explicitly.

| Step | Scope | Needs from you | Rough effort (my work) |
|---|---|---|---|
| 0 | Merge PR #9 (needs your approval; branch is behind `main`, may need an update merge) | approval | minutes |
| 1 | **README skeleton**, Part A, C6 diagram, D5 table, F3 text, I1 - written against the real current state, "pending" where unproven | answers to section 2 | 2-4 h |
| 2 | **CI completion**: add Dependabot, document required checks, decide whether "Deploy scripts and Compose" becomes required; B5 demo branch; Terraform CI path filter fix so it can be required | approvals for branch protection and any PR | 2-3 h + your screenshots |
| 3 | **Application**: `/health/live`, `/health/ready`, Secrets Manager + RDS TLS code path (local `DATABASE_URL` path preserved), request timeout, tests with the AWS SDK mocked, verified on a disposable local Postgres | none for code; Docker use is local and non-destructive | 6-10 h |
| 4 | **Terraform finish**: close the Critical/High findings in code, remote state (S3 + locking), CloudWatch, GitHub OIDC provider and roles, ECR; `terraform fmt/validate` only | decision 3 (domain), decision 5 (cost) | 8-14 h |
| 5 | **Deployment code for SSM/ECR/RDS**: rewrite prod compose, bluegreen scripts, rolling production deploy, offline test suite | decision 1 | 10-16 h |
| 6 | **CD/rollback workflows** (SSM Run Command, ECR digests, S3 artifacts, deployment history); still disabled | decision 4 | 8-12 h |
| 7 | **AWS gate**: cost and security briefing, then your approval for authentication, `terraform plan` (review), then separate approval for apply (staging first) | explicit approvals | - |
| 8 | **Staging deployment** and evidence; DB bootstrap by an operator step | approvals for GitHub secrets/variables/Environments and `CD_ENABLED` | 4-8 h |
| 9 | **Production gate**, rolling deploy, request-loop measurements on AWS, rollback demonstrations | approvals; reviewer set up on the Environment | 6-10 h |
| 10 | **Part H**: Copilot session and three failures on throwaway branches | you run Copilot, take screenshots | mostly yours; I draft scaffolding |
| 11 | **Final docs**: evidence index, screenshots wiring, final history scan, clean-machine README dry run | live URL decision | 3-5 h |

Critical path: decisions 1-3 and 5, then steps 3-6 in code (no AWS), then the AWS gate. Steps 1-3 can start now without any AWS contact.

## 6. Secrets and variables (names only, planned; none exist today)

With GitHub OIDC and SSM there should be **no AWS access keys and no SSH key** in GitHub. Likely set: variables for the AWS region, the
OIDC role ARNs per environment (ARNs are identifiers, but review against rule 1 before committing any), the instance IDs or tags, and `CD_ENABLED`;
possibly zero secrets. The final list is decided in step 4 and recorded in the README (D5). The existing `cd.yml` secrets (`SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `EC2_HOST`, `EC2_USER`) become obsolete.

## 7. Risks and dependencies

| Risk | Impact | Mitigation |
|---|---|---|
| SSM not accepted for "over SSH" | up to 15 marks (E) | instructor confirmation in writing |
| Live URL policy unresolved | S4, possibly D | instructor confirmation |
| Unproven Terraform (never planned) | surprises at first plan (provider acceptance, IAM, `rds_superuser` limits, account guards need `allowed_account_ids`) | staging first; review plan before approval |
| Cost of three NATs, Multi-AZ RDS, ALBs for weeks | budget | estimate before approval; destroy-with-approval plan; consider reduced production topology |
| RDS bootstrap under `rds_superuser` | roles or grants may fail | rehearse on staging; keep migrations backward compatible |
| Post-switch failure still costs about 20 s of errors | weakens F "no request failed" | use ALB health-based rolling deploy; measure on AWS; never claim zero downtime without the real test |
| No failed runs exist | H4, S2 | create on throwaway branches, never delete runs |
| History secret scan | D = 0 marks if anything leaks | scan before every push (already enforced), final all-history scan; personal email in `668a93e` is metadata only |
| Branch is behind `main` | PR #9 may need an update merge under strict protection | merge (not rebase) with your approval |
| Scope vs time | large | phase gates and approvals as set out here |

## 8. Acceptance criteria (evidence needed per rubric part)

| Part | Accepted when |
|---|---|
| A | README section covers all three points and maps each incident to a concrete workflow feature |
| B | PR and push runs green with all four steps for both tiers; one PR shown blocked by a failing required check; screenshots in `docs/screenshots/` |
| C | CI and CD are separate and CD has actually run; job graph, parallel matrix and an artifact/image hand-off shown; README diagram matches the real workflows |
| D | full-history gitleaks clean; secrets only in GitHub; staging and production Environments with separate config; production run paused for manual approval (screenshot); README lists every name |
| E | merge to `main` triggers CD only after CI; app reachable; port 5432 test from outside fails; `/version`, image tag and log show the same SHA |
| F | request-loop log from a real AWS deployment, with counts and zero failed requests, or an honest statement of what failed; strategy and trade-offs in README |
| G | health check inside the pipeline; broken release recovers by itself (logs); manual rollback to a chosen earlier SHA via the workflow; logs kept as artifacts |
| H | your Copilot session evidence; three different failed runs kept, each with screenshot, root cause, Copilot troubleshooting and fix commit |
| I | README complete; a reader can reproduce from it alone (dry run); clean tree; screenshots linked |

## 9. Evidence matrix (current result)

| Rubric part | Implementation file(s) | Test or workflow | Evidence location | Current result |
|---|---|---|---|---|
| A | README.md (missing) | review | - | NOT IMPLEMENTED |
| B | `.github/workflows/ci.yml`, `backend/`, `frontend/` | CI runs | Actions runs 44714705352, 44786392818, 44858849602; `docs/evidence/phase2/` | mostly DONE; B4, B5 PARTIAL |
| C | `ci.yml`, `cd.yml` | CI runs; CD skipped | run 44786557196 (skipped) | PARTIAL |
| D | `.gitignore`, hook, scan evidence | gitleaks | `docs/evidence/secret-scan/`, `docs/evidence/phase2/secret-scan-*` | NEEDS VERIFICATION |
| E | `infra/terraform/`, `cd.yml` | Terraform CI (static only) | runs 44785811248, 44786392731 | PARTIAL, not deployed |
| F | `deploy/scripts/`, `deploy/nginx/` | local rehearsal | `docs/evidence/bluegreen-local/` | PARTIAL, local only |
| G | `deploy/scripts/`, `rollback.yml` | local rehearsal, offline suite | `docs/evidence/bluegreen-local/` | PARTIAL, local only; workflow never run |
| H | - | - | - | NOT IMPLEMENTED |
| I | PROJECT_STATUS.md, checklist | - | PRs #1-#9 | PARTIAL |

## 10. Stop point

Phase 0 is complete. Nothing is staged or committed, and no GitHub or AWS state was changed. Next action needs your answers to section 2 and
your approval of the next step in section 5.
