# PROJECT STATUS — ShopNest DevOps CI/CD

Last updated: 2026-11-19 | Current phase: Phase 1 complete (PR #1 merged); next: Phase 2 awaiting approval. PR #2 (documentation correction) is open.
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
| 0 | Docs, .gitignore, checklist, architecture | Done (merged to main in PR #1) |
| 1 | git init, gitleaks pre-commit hook, GitHub repo + push protection | Done: public repo, branches pushed, secret scanning and push protection enabled, PR #1 merged. Branch protection deliberately not configured until CI exists (Phase 3) |
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

## GitHub state (verified with `gh` on 2026-11-17; rows marked 2026-11-19 were checked again)
| Item | Value |
|---|---|
| Repository | https://github.com/Bhabotos/shopnest-devops-cicd |
| Visibility | Public |
| Default branch | main |
| Remote | `origin` (HTTPS), fetch and push |
| Pull request | #1 https://github.com/Bhabotos/shopnest-devops-cicd/pull/1 |
| PR state | MERGED 2026-11-17T17:24:31Z by Bhabotos with a normal merge commit (no squash or rebase); base `main`, head `docs/project-foundation` |
| PR title | docs: establish ShopNest project foundation |
| Remote `main` | 668a93e82f72b0ea804367714e34b64c6412306f (merge commit of PR #1; parents eca306c and e6e7cbc) |
| Remote `docs/project-foundation` | e6e7cbcd04a32fa89438dc02d1b916422e57490b (branch kept after merge, as requested) |
| Pull request #2 | https://github.com/Bhabotos/shopnest-devops-cicd/pull/2 (CLI-verified 2026-11-19): OPEN, not draft, base `main`, head `docs/post-merge-status` at c971105, 3 commits (9683fdd, 5f054ac, c971105), 3 documentation files changed, MERGEABLE, merge state CLEAN, no status checks, no review decision |
| Secret scanning | enabled (re-verified 2026-11-19) |
| Push protection | enabled (re-verified 2026-11-19) |
| Secret-scanning alerts | 0 (re-verified 2026-11-19) |
| Email privacy | USER-REPORTED: "Keep my email addresses private" and "Block command line pushes that expose my email" are enabled in the GitHub web UI. CLI-VERIFIED 2026-11-19: `gh api user/public_emails` returns `[]`. UNKNOWN: the state of the block-pushes toggle (reading it needs the `user` token scope, which was not requested). No screenshot of these settings exists in the repository (CLI-verified: 0 image files). |
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
| e6e7cbc | docs/project-foundation | docs: update GitHub repository and PR status |
| 668a93e | main | Merge pull request #1 from Bhabotos/docs/project-foundation |
| 9683fdd | docs/post-merge-status | docs: update project status after PR #1 merge |
| 5f054ac | docs/post-merge-status | docs: mark PR #1 as merged in checklist row I4 |
| c971105 | docs/post-merge-status | docs: save post-merge gitleaks scan as evidence |

## Secret-scan validation
Labels: SAVED = text recorded in docs/evidence/secret-scan/phase1-history-scan.txt; TERMINAL-ONLY = reported in earlier status notes as seen in a terminal, with no record, so it cannot be verified; CLI-VERIFIED = checked with read-only `git` or `gh` on the stated date; USER-REPORTED = stated by the user, not independently verified; UNKNOWN = not recorded and not verifiable.

- Pre-commit hook: `.githooks/pre-commit` (gitleaks 8.30.1, staged files) is tracked and `core.hooksPath` is set to `.githooks` (CLI-VERIFIED 2026-11-19). That it ran on each commit was reported in earlier sessions; the hook output was not saved, so this is UNKNOWN.
- SAVED: gitleaks 8.30.1 runs with `--log-opts=--all` and `.gitleaks.toml` on 2026-11-17 printed "5 commits scanned" (scope line: history through 2fd9fb6) and "6 commits scanned" (scope line: history through f127deb), with "no leaks found" and exit code 0. CLI-VERIFIED 2026-11-19 with `git`: 5 commits are reachable from 2fd9fb6 and 6 from f127deb. The saved output lists only counts, so which commits each run scanned is UNKNOWN, and complete coverage of the history is not verified.
- TERMINAL-ONLY (not evidence): three post-publication scans on 2026-11-17 (7 commits, 8 commits after the PR status commit, and after the merge) are reported to have shown no leaks. No record exists and none is reconstructed here.
- SAVED: the 2026-11-18 post-merge run. Recorded scope: "all refs (local and origin/*), branch docs/post-merge-status at 5f054ac; 11 commits reachable". Recorded output: "10 commits scanned", "no leaks found", exit code 0. CLI-VERIFIED 2026-11-19 with `git`: 11 commits are reachable from 5f054ac, one of them merge commit 668a93e. UNKNOWN: which commits were scanned and how the merge commit was handled, so whether 668a93e was among the 10 is not known. Commits after 5f054ac were not covered by that run. A final saved scan is still required before submission.
- "No leaks found" means no match against the gitleaks default ruleset plus this repository's IPv4 and EC2-hostname rules. It does not show that the repository contains no secret.
- SAVED: supplementary history grep (IPs, key material, AWS key ids, secret-like file names, as described in the evidence file): 0 matches, recorded for the 5- and 6-commit runs only. It was not run for the 2026-11-18 run.
- The assignment DOCX is not tracked and is ignored (CLI-VERIFIED 2026-11-19).

Note: `.gitattributes` was added to the root commit (not in the original file list) to keep the hook LF on Windows checkouts.

## Open questions
1. Live URL vs. no server address in repo — pending instructor clarification.
2. SSH strategy: OIDC design documented with a verification log (docs/OIDC_DESIGN.md); creation of AWS resources still needs explicit approval in Phase 4.
   2a. New repos (created after 2026-07-15) may use immutable `sub` claims containing owner/repo IDs; the real `sub` must be captured before writing the trust policy.
   2b. Unverified items listed in OIDC_DESIGN.md rows 8, 9, 11, 12, 14, 20, 23, 24 and the EC2 policy-examples page (returned no content).
   2c. EventBridge/CloudTrail/CloudWatch/SNS resources for alerts need approval and add cost.
3. Terraform state: decided local and git-ignored (revisit only if needed).
4. (Resolved 2026-11-17) Verified noreply email provided and configured for this repository only.
5. (Partly resolved) Merge-commit email exposure (see Risks). USER-REPORTED: "Keep my email addresses private" and "Block command line pushes that expose my email" are enabled in the GitHub web UI (no screenshot in the repository). CLI-VERIFIED 2026-11-19: `gh api user/public_emails` returns `[]`, so the primary email is not publicly listed; the global and the repository-local Git `user.email` are both the GitHub noreply address. UNKNOWN: the state of the block-pushes toggle (needs the `user` token scope, which was not requested). Still open: leave commit 668a93e as is (recommended) or rewrite `main`; no rewrite has been approved.

## Manual actions log
- 2026-11-17: Gitleaks 8.30.1 installed via winget (user-approved).
- 2026-11-17: User provided the verified GitHub noreply email; set as local repo config only (global config unchanged).
- 2026-11-17: Assistant ran git init, created commits and the history scan locally.
- 2026-11-17: With the user's approval, assistant created the public repository, pushed `main` and `docs/project-foundation`, and opened PR #1. No other GitHub settings were changed; secret scanning and push protection were already enabled.
- 2026-11-17: With the user's approval, assistant merged PR #1 with a normal merge commit (668a93e), kept the feature branch, and pulled `main` locally.
- 2026-11-19: USER-REPORTED: the GitHub email privacy settings were enabled in the web UI. The assistant only checked that `gh api user/public_emails` returns `[]` (read-only; no extra token scopes requested; authentication not refreshed).
- 2026-11-19: With the user's approval, the assistant set the global Git `user.email` to the GitHub noreply address. The global `user.name` and the repository-local email were not changed.

## Risks / limitations
- Privacy (personal data, NOT a credential): merge commit 668a93e on `main` (PR #1, merged 2026-11-17T17:24:31Z, parents eca306c and e6e7cbc; CLI-verified with `git` and `gh` on 2026-11-19) has the account's primary, non-noreply email address and the account's name as author, and GitHub as committer. The author email address is therefore public in commit metadata. It is not a credential, key, password or server address; whether the instructor treats it as relevant to Part D is UNKNOWN. All other commits use the GitHub noreply address as author and committer (CLI-verified 2026-11-19). The email privacy settings were USER-REPORTED as enabled afterwards (see Open question 5); that does not change existing history. Commit 668a93e is unchanged and still public. No history rewrite has been performed or approved. Options: leave as is (recommended), or rewrite `main` with a force push, which may not remove the commit from GitHub's pull-request refs or from existing clones or forks.
- Scheduled sweeper is best-effort: GitHub can delay or drop runs and disables them after 60 days of public-repo inactivity; nominal orphan exposure is about 20 minutes, not bounded.
- IAM cannot restrict SSH rule port/CIDR; a compromised deploy job in an allowed environment could open other ports on the SSH group (mitigations in OIDC_DESIGN.md).
- Single instance: staging/prod are not infrastructure-isolated (document in README).
- GitHub-hosted runner IPs are not fixed; hence per-run port 22 opening strategy.
