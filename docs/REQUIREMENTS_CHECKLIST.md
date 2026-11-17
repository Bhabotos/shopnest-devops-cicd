# Requirements Checklist
Source: assignment/GITHUB ACTIONS.docx (100 marks). Last updated: 2026-11-17.

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
| C5 | M | At least one job tests multiple runtime versions (Node 20 and 22) | Not started | Matrix shows both versions | docs/screenshots/matrix (pending) | pending |
| C6 | M | README diagram of workflows, jobs, steps, runners and relations | Not started | Review diagram against actual workflows | README.md (pending) | pending |

## Part D — Secrets and configuration management (10 marks; 0 if any credential in repo/history)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| D1 | M | No credential, key, password or server address in repo or commit history | In progress (guard active, repo public; final scan before submission still required) | gitleaks over full history plus grep for IPs/hostnames, before every push and at the end. Done 2026-11-17: hook ran on every commit; scans of 5 and 6 commits recorded; a 7-commit all-refs scan after publishing was clean but is NOT saved in the evidence file; history grep 0 matches. GitHub secret scanning and push protection verified enabled, 0 alerts | docs/evidence/secret-scan/phase1-history-scan.txt (5- and 6-commit scans); GitHub security settings via `gh api` (no screenshot yet) | eca306c (guard); evidence 0dd2454; repo pushed and PR #1 open |
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
| H1 | M | GitHub Copilot generates at least one workflow file | Not started | User's real Copilot session | docs/copilot/ (pending) | pending |
| H2 | M | Prompts used are included | Not started | Actual prompts recorded verbatim | docs/copilot/ (pending) | pending |
| H3 | M | Changes made to Copilot's output and why | Not started | Diff of Copilot output vs final | docs/copilot/ (pending) | pending |
| H4 | M | At least 3 different kinds of deliberate pipeline failure | Not started | e.g. YAML syntax, test failure, deploy/connection failure | docs/failures/ (pending) | pending |
| H5 | M | Per failure: error seen with screenshot of failed run | Not started | Screenshot per failure | docs/failures/ (pending) | pending |
| H6 | M | Per failure: root-cause method incl. Copilot troubleshooting | Not started | Written analysis | docs/failures/ (pending) | pending |
| H7 | M | Per failure: fix applied with link to commit | Not started | Commit link | docs/failures/ (pending) | pending |

## Part I — Documentation and repository quality (5 marks)
| ID | Type | Requirement | Status | Validation method | Evidence location | Commit / Run |
|---|---|---|---|---|---|---|
| I1 | M | README: overview, architecture diagram, setup instructions, pipeline explanation | Not started | Review against list | README.md (pending) | pending |
| I2 | M | README: screenshots of successful and failed runs | Not started | Images resolve in repo | docs/screenshots/ (pending) | pending |
| I3 | M | Clean, logical folder structure | Not started | Compare with planned layout | repo tree | pending |
| I4 | M | Meaningful commit messages; branching workflow with PRs | In progress (public repo; PR #1 merged with a normal merge commit; PR #2 open; root commit plus 7 Conventional commits on docs/project-foundation and 1 on docs/post-merge-status; CI-gated PR workflow not yet possible because no CI exists) | Review git log and PR list | PR #1 (merged) https://github.com/Bhabotos/shopnest-devops-cicd/pull/1; PR #2 (open) https://github.com/Bhabotos/shopnest-devops-cicd/pull/2; git log | eca306c, 615a338, fda914c, 2054e22, 2fd9fb6, f127deb, 0dd2454, e6e7cbc, merge 668a93e, 9683fdd |
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
