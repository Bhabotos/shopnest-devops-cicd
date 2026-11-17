# PROJECT STATUS — ShopNest DevOps CI/CD

Last updated: 2026-11-17 | Current phase: Phase 1 published; PR #1 open and awaiting review/merge
Detailed per-requirement tracking (status, validation, evidence, commit/run): docs/REQUIREMENTS_CHECKLIST.md

## Part tracker
| Part | Topic | Marks | Status | Evidence | Notes |
|---|---|---|---|---|---|
| A | CI/CD concepts | 5 | Not started | – | README section |
| B | CI pipeline | 15 | Not started | – | Needs branch protection |
| C | Workflow architecture | 10 | Not started | – | Diagram + Node 20/22 matrix + artifacts |
| D | Secrets & config | 10 | Not started | – | 0 if any secret in history |
| E | EC2 deployment | 15 | Not started | – | DB must be non-public |
| F | Zero downtime | 15 | Not started | – | Needs request-loop proof |
| G | Monitoring & rollback | 15 | Not started | – | Auto + manual + staging broken-release demo |
| H | Debugging & Copilot | 10 | Not started | – | User's real Copilot prompts |
| I | Docs & repo quality | 5 | Not started | – | README reproducible |

## Roadmap
| Phase | Scope | Status |
|---|---|---|
| 0 | Docs, .gitignore, checklist, architecture | Done (awaiting review) |
| 1 | git init, gitleaks pre-commit hook, GitHub repo + push protection | Done except merge: public repo created, both branches pushed, secret scanning and push protection enabled, PR #1 open (not merged). Branch protection deliberately not configured until CI exists (Phase 3) |
| 2 | App code (frontend, backend, tests) | Pending |
| 3 | CI workflow + branch protection (B, C) | Pending |
| 4 | Terraform: plan review, apply only on explicit approval; SSH strategy setup (E) | Pending |
| 5 | Docker/Compose/Nginx + CD staging over SSH (E) | Pending |
| 6 | Production environment approval gate (D) | Pending |
| 7 | Blue-green + zero-downtime proof (F) | Pending |
| 8 | Health check, auto/manual rollback, logs, staging broken-release test (G) | Pending |
| 9 | Copilot workflow + 3+ failure scenarios (H) | Pending |
| 10 | README, screenshots, final history secret scan (A, C, I) | Pending |

## Decisions log
- 2026-11-17: Stack React+Vite / Express / PostgreSQL.
- 2026-11-17: AWS ap-south-1, CLI profile `devops`, one EC2 instance to start.
- 2026-11-17: Terraform (our choice, not mandated). No apply/destroy without approval.
- 2026-11-17: Docker Compose, Nginx, blue-green, health checks, auto rollback.
- 2026-11-17: Staging and production share the single instance as isolated Compose projects.
- 2026-11-17: No root credentials, no permanent AWS keys.
- 2026-11-17: Node matrix is 20 and 22 (not 18).
- 2026-11-17: SSH strategy = port 22 closed by default, opened per run (see ARCHITECTURE.md).
- 2026-11-17: Rollback demo = controlled staging test with failed post-deploy validation.
- 2026-11-17: Live URL pending; no IP/DNS/URL in any repo file.
- 2026-11-17: Proposed (not deployed): sweeper every 5 min, temporary SSH rule expiry 15 min, deploy job timeout <= 10 min, EventBridge rule plus CloudWatch alarms for cleanup failures (docs/OIDC_DESIGN.md).
- 2026-11-17: IAM cannot enforce port or CIDR for security group rules (no documented condition key); the workflow enforces tcp/22 and the runner /32, the sweeper detects violations.

## GitHub state (verified with `gh` on 2026-11-17)
| Item | Value |
|---|---|
| Repository | https://github.com/Bhabotos/shopnest-devops-cicd |
| Visibility | Public |
| Default branch | main |
| Remote | `origin` (HTTPS), fetch and push |
| Pull request | #1 https://github.com/Bhabotos/shopnest-devops-cicd/pull/1 |
| PR state | OPEN, not draft, base `main`, head `docs/project-foundation`, mergeable, merge state clean |
| PR title | docs: establish ShopNest project foundation |
| Remote `main` | eca306c17c924f6ac49b52d4e8834998cd494c09 |
| Remote `docs/project-foundation` | 0dd2454e62eed6eb8f37df2d51bb070f4e5572f5 (at verification time; the PR status-update commit follows it) |
| Secret scanning | enabled |
| Push protection | enabled |
| Secret-scanning alerts | 0 |
| Branch protection / rulesets on main | None configured (deliberate, until CI exists) |
| Actions workflows / runs / secrets | 0 / 0 / 0 |
| AWS resources, Terraform apply, deployment | None have occurred |

## Commits
| Commit | Branch | Message |
|---|---|---|
| eca306c | main | chore: add secret-scanning guard and ignore rules |
| 615a338 | docs/project-foundation | docs: add project rules and requirements checklist |
| fda914c | docs/project-foundation | docs: add architecture and GitHub OIDC design |
| 2054e22 | docs/project-foundation | docs: add GitHub repository setup instructions |
| 2fd9fb6 | docs/project-foundation | docs: add project status tracker |
| f127deb | docs/project-foundation | docs: record Phase 1 commits and secret-scan results |
| 0dd2454 | docs/project-foundation | docs: add final pre-publication secret scan result |
| (next) | docs/project-foundation | docs: update GitHub repository and PR status (this update; see `git log`) |

## Secret-scan validation
- Pre-commit hook ran on every commit (no leaks).
- Gitleaks full-history scans (all refs): 5 commits clean and 6 commits clean, both recorded in docs/evidence/secret-scan/phase1-history-scan.txt.
- 7-commit scan (all refs, 2026-11-17, after publishing, includes `origin/*` refs): no leaks found. **Evidence limitation:** this 7-commit result was only observed in the terminal during the session and is NOT saved in the evidence file, which contains the 5- and 6-commit scans only. A final scan must be saved before submission.
- History grep for IPs, key material, AWS key ids, EC2 hostnames and secret-like file names: 0 matches.
- The assignment DOCX is not tracked and is ignored.

Note: `.gitattributes` was added to the root commit (not in the original file list) to keep the hook LF on Windows checkouts.

## Open questions
1. Live URL vs. no server address in repo — pending instructor clarification.
2. SSH strategy: OIDC design documented with a verification log (docs/OIDC_DESIGN.md); creation of AWS resources still needs explicit approval in Phase 4.
   2a. New repos (created after 2026-07-15) may use immutable `sub` claims containing owner/repo IDs; the real `sub` must be captured before writing the trust policy.
   2b. Unverified items listed in OIDC_DESIGN.md rows 8, 9, 11, 12, 14, 20, 23, 24 and the EC2 policy-examples page (returned no content).
   2c. EventBridge/CloudTrail/CloudWatch/SNS resources for alerts need approval and add cost.
3. Terraform state: decided local and git-ignored (revisit only if needed).
4. (Resolved 2026-11-17) Verified noreply email provided and configured for this repository only.

## Manual actions log
- 2026-11-17: Gitleaks 8.30.1 installed via winget (user-approved).
- 2026-11-17: User provided the verified GitHub noreply email; set as local repo config only (global config unchanged).
- 2026-11-17: Assistant ran git init, created commits and the history scan locally.
- 2026-11-17: With the user's approval, assistant created the public repository, pushed `main` and `docs/project-foundation`, and opened PR #1 (not merged). No other GitHub settings were changed; secret scanning and push protection were already enabled.

## Risks / limitations
- Scheduled sweeper is best-effort: GitHub can delay or drop runs and disables them after 60 days of public-repo inactivity; nominal orphan exposure is about 20 minutes, not bounded.
- IAM cannot restrict SSH rule port/CIDR; a compromised deploy job in an allowed environment could open other ports on the SSH group (mitigations in OIDC_DESIGN.md).
- Single instance: staging/prod are not infrastructure-isolated (document in README).
- GitHub-hosted runner IPs are not fixed; hence per-run port 22 opening strategy.
