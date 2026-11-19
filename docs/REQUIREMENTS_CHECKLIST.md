# Requirements Checklist
Source: assignment/GITHUB ACTIONS.docx (100 marks). Last updated: 2026-11-19.

Legend. Type: M = mandatory (from the document), R = our recommendation (not required).
Status: Not started / In progress / Implemented / Validated. Only mark Validated with real evidence.
Evidence and Commit/Run stay "pending" until they exist. Never fabricate them.
Evidence root: `docs/` (screenshots in `docs/screenshots/`, failures in `docs/failures/`).

## Part A — CI/CD concepts (5 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| A1 | M | README explains CI, Continuous Delivery, Continuous Deployment and how they differ | Not started | Instructor/self review of README section | README.md (section pending) | pending |
| A2 | M | README shows how the pipeline fixes each of the 3 incidents (untested build, ~10 min downtime, 2h rollback) | Not started | Map each incident to a workflow feature | README.md (pending) | pending |
| A3 | M | README states which approach was chosen for ShopNest and why | Not started | Review | README.md (pending) | pending |
| A4 | R | Also address the 4th incident (committed secrets) | Not started | Review | README.md (pending) | pending |

## Part B — Continuous Integration pipeline (15 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| B1 | M | CI runs on push and on PR against main | Not started | Trigger both; check Actions tab | docs/screenshots/ci-triggers (pending) | pending |
| B2 | M | Frontend: install deps, lint, test, build | Not started | Green run with all 4 steps | docs/screenshots/ci-frontend (pending) | pending |
| B3 | M | Backend: install deps, lint, test, build | Not started | Green run with all 4 steps | docs/screenshots/ci-backend (pending) | pending |
| B4 | M | At least a few meaningful tests written by me | Not started | Test output listing named tests | docs/screenshots/tests (pending) | pending |
| B5 | M | PR not mergeable unless CI passes | Not started | Open PR with failing CI; merge button blocked | docs/screenshots/branch-protection (pending) | pending |

## Part C — Workflow architecture (10 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| C1 | M | Separate workflows for CI and CD | Not started | Files ci.yml and cd.yml exist and run separately | .github/workflows/ | pending |
| C2 | M | Several jobs with correct dependencies | Not started | `needs` graph in run view | docs/screenshots/job-graph (pending) | pending |
| C3 | M | Parallel execution of independent jobs | Not started | Frontend/backend jobs run concurrently in run view | docs/screenshots/job-graph (pending) | pending |
| C4 | M | Build outputs passed between jobs | Not started | Artifact upload in CI, download in CD | Run artifacts (pending) | pending |
| C5 | M | At least one job tests multiple runtime versions (planned by us: Node 22 and 24, backend and frontend) | Not started | Matrix shows both versions | docs/screenshots/matrix (pending) | pending |
| C6 | M | README diagram of workflows, jobs, steps, runners and relations | Not started | Review diagram against actual workflows | README.md (pending) | pending |

## Part D — Secrets and configuration management (10 marks; 0 if any credential in repo/history)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| D1 | M | No credential, key, password or server address in repo or commit history | In progress (guard active, repo public; final saved scan before submission still required; the repository is not shown to be free of secrets) | gitleaks runs with `--log-opts=--all` plus grep for IPs/hostnames, before every push and at the end. The saved runs report commit counts only: exact commit coverage is UNKNOWN, and three earlier scans are TERMINAL-ONLY and cannot be verified (details and labels: PROJECT_STATUS.md, Secret-scan validation). GitHub secret scanning and push protection enabled, 0 alerts (CLI-verified 2026-11-19). Personal email in the metadata of commit 668a93e: see PROJECT_STATUS.md Risks; it is not a credential. | docs/evidence/secret-scan/phase1-history-scan.txt (5-, 6- and 10-commit runs); GitHub security settings via `gh api` (no screenshot yet) | eca306c (guard); evidence 0dd2454, c971105; repo pushed; PR #1 merged (668a93e); PR #2 open |
| D2 | M | Sensitive values stored and used securely | Not started | Values only in GitHub Secrets; masked in logs | docs/screenshots/secrets-settings (names only) (pending) | pending |
| D3 | M | Separate configuration for staging and production | Not started | Separate GitHub Environments and config files | docs/screenshots/environments (pending) | pending |
| D4 | M | Production deployment requires manual approval | Not started | Run pauses at approval gate | docs/screenshots/prod-approval (pending) | pending |
| D5 | M | README lists every secret and variable (name and purpose, never value) | Not started | Cross-check README list against workflow references | README.md (pending) | pending |
| D6 | R | No permanent AWS keys; temporary credentials only | In progress (design only; no AWS resources, 0 GitHub Actions secrets verified on 2026-11-17) | Review IAM/OIDC setup after Phase 4 | docs/OIDC_DESIGN.md (design); implementation evidence pending | fda914c (design doc) |

## Part E — Automated deployment to EC2 (15 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| E1 | M | AWS EC2 environment set up for the three-tier app | Not started | Terraform plan reviewed, then user-approved apply (R: Terraform) | docs/evidence/infra (pending) | pending |
| E2 | M | Merge to main deploys automatically over SSH | Not started | Merge a PR, observe CD run | docs/screenshots/cd-run (pending) | pending |
| E3 | M | Frontend, backend and database reachable in correct roles | Not started | Frontend loads; API responds; backend reaches DB | docs/evidence/roles (pending) | pending |
| E4 | M | Database not reachable from public internet | Not started | Port 5432 test from outside fails; SG has no DB rule | docs/screenshots/db-private (pending) | pending |
| E5 | M | Deployment runs only after CI succeeds | Not started | Failing CI does not trigger CD | docs/screenshots/cd-gating (pending) | pending |
| E6 | M | Every deployment traceable to exact commit | Not started | /version, image tag and log show same SHA | docs/evidence/traceability (pending) | pending |
| E7 | R | SSH not exposed unnecessarily (per-run opening, see ARCHITECTURE.md) | In progress (design only, nothing created) | SG shows 22 closed after run; sweeper/alarm tests in Phase 4-8 | docs/OIDC_DESIGN.md (design); screenshots pending | fda914c (design doc) |

## Part F — Zero-downtime deployment (15 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| F1 | M | Strategy keeps app available throughout release (R: blue-green via Nginx) | Not started | Request loop during deploy | docs/evidence/zero-downtime (pending) | pending |
| F2 | M | Proof: continuous requests during a deploy with evidence none failed | Not started | Loop log shows 100% success and status codes | docs/evidence/zero-downtime (pending) | pending |
| F3 | M | README explains strategy and trade-offs | Not started | Review | README.md (pending) | pending |

## Part G — Monitoring, health checks and rollback (15 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| G1 | M | Automatic post-deploy health check | Not started | Step in CD run | docs/screenshots/healthcheck (pending) | pending |
| G2 | M | Automatic rollback to last known good on failed check | Not started | Broken release recovers by itself | docs/evidence/auto-rollback (pending) | pending |
| G3 | M | Manual rollback to any specific earlier version | Not started | Run rollback.yml with an earlier SHA; /version matches | docs/screenshots/manual-rollback (pending) | pending |
| G4 | M | Clear deployment logs, kept for later review | Not started | Logs uploaded as artifacts and readable | docs/evidence/logs (pending) | pending |
| G5 | M | Demonstrate automatic rollback with a deliberately broken release | Not started | Controlled staging test in ARCHITECTURE.md (A good, B broken, validation fails, recovery to A) | docs/evidence/auto-rollback (pending) | pending |
| G6 | R | Staging test also shows request loop continuity and release history marking B failed | Not started | Loop output plus release history | docs/evidence/auto-rollback (pending) | pending |

## Part H — Debugging and Copilot-assisted development (10 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| H1 | M | GitHub Copilot generates at least one workflow file | Not started | User's real Copilot session. Required evidence: a screenshot or exported transcript of that session, and Copilot's unedited output committed before any manual edit (the first CI workflow, created with Copilot when it is first written) | docs/copilot/ (pending) | pending |
| H2 | M | Prompts used are included | Not started | Actual prompts recorded verbatim. Required evidence: every prompt copied verbatim from the user's own session | docs/copilot/ (pending) | pending |
| H3 | M | Changes made to Copilot's output and why | Not started | Diff of Copilot output vs final. Required evidence: commit links for the unedited output and for each later edit, with a written reason for each change | docs/copilot/ (pending) | pending |
| H4 | M | At least 3 different kinds of deliberate pipeline failure | Not started | e.g. YAML syntax, test failure, deploy/connection failure. Required evidence: three different kinds, each shown by a failed Actions run that is kept and never deleted | docs/failures/ (pending) | pending |
| H5 | M | Per failure: error seen with screenshot of failed run | Not started | Screenshot per failure. Required evidence: one screenshot of each failed run showing the error | docs/failures/ (pending) | pending |
| H6 | M | Per failure: root-cause method incl. Copilot troubleshooting | Not started | Written analysis. Required evidence per failure: the error text, how the root cause was found, and the Copilot troubleshooting prompt and answer from the user's own session | docs/failures/ (pending) | pending |
| H7 | M | Per failure: fix applied with link to commit | Not started | Commit link. Required evidence per failure: the link to the fix commit | docs/failures/ (pending) | pending |

## Part I — Documentation and repository quality (5 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| I1 | M | README: overview, architecture diagram, setup instructions, pipeline explanation | Not started | Review against list | README.md (pending) | pending |
| I2 | M | README: screenshots of successful and failed runs | Not started | Images resolve in repo | docs/screenshots/ (pending) | pending |
| I3 | M | Clean, logical folder structure | Not started | Compare with planned layout | repo tree | pending |
| I4 | M | Meaningful commit messages; branching workflow with PRs | In progress (public repo; PR #1 and PR #2 merged with normal merge commits; root commit plus 7 Conventional commits on docs/project-foundation and 4 on docs/post-merge-status; CI-gated PR workflow not yet possible because no CI exists) | Review git log and PR list | PR #1 (merged) https://github.com/Bhabotos/shopnest-devops-cicd/pull/1; PR #2 (merged) https://github.com/Bhabotos/shopnest-devops-cicd/pull/2; git log | eca306c, 615a338, fda914c, 2054e22, 2fd9fb6, f127deb, 0dd2454, e6e7cbc, merge 668a93e, 9683fdd, 5f054ac, c971105, 90825d7, merge 4d8f304 |
| I5 | M | Anyone can reproduce the setup from the README alone | Not started | Dry-run read-through of README steps | README.md (pending) | pending |

## Submission rules
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| S1 | M | One public GitHub repository link | Not started | Open link logged out | pending | pending |
| S2 | M | Actions tab shows history of successful and failed runs; none deleted | Not started | Review Actions tab | pending | pending |
| S3 | M | All screenshots inside repo and referenced from README | Not started | Link check | docs/screenshots/ | pending |
| S4 | M | Live URL in README | PENDING instructor clarification | Do not add any address until resolved | n/a | n/a |
| S5 | M | Server running until grading finishes | Not started | Manual check | n/a | n/a |
| S6 | M | Original work only (plagiarism = 0 for whole assignment) | Not started | Own work, own Copilot prompts | n/a | n/a |
