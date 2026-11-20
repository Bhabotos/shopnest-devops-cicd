# PROJECT STATUS — ShopNest DevOps CI/CD

Last updated: 2026-11-20 | Current phase: application code, CI and a disabled CD draft are merged to `main` (PR #3, PR #4); branch protection is applied. Two PRs are OPEN and NOT merged: PR #5 `feature/phase2-docker-compose-leftovers` into `main` (f0f55ce: frontend Dockerfile, dev/test Compose, verify scripts, Phase 2 evidence) and PR #6 `feature/bluegreen-deploy-scripts` into the PR #5 branch (blue/green scripts, offline suite, rollback.yml, a new CI job, evidence; stacked, so its base must be changed to `main` after PR #5 merges with a normal merge commit). The blue/green scripts were exercised offline (125 checks) and in local Docker Desktop rehearsals (attempts 3, 4 and 5); nothing is deployed, no AWS resource exists, and CD stays disabled (`CD_ENABLED` unset).
Detailed per-requirement tracking (status, validation, evidence, commit/run): docs/REQUIREMENTS_CHECKLIST.md

## Part tracker
| Part | Topic | Marks | Status | Evidence | Notes |
|---|---|---|---|---|---|
| A | CI/CD concepts | 5 | Not started | – | README section |
| B | CI pipeline | 15 | In progress | see checklist | CI green on GitHub (runs 44714705352, 44720737504, 44726873391); protection applied; failing-check merge block and screenshots pending |
| C | Workflow architecture | 10 | In progress | see checklist | ci.yml and cd.yml on main; matrix, parallel jobs and artifacts verified on GitHub; CD never deployed |
| D | Secrets & config | 10 | Not started | – | 0 if any secret in history |
| E | EC2 deployment | 15 | Not started | – | DB must be non-public |
| F | Zero downtime | 15 | In progress (local evidence only) | see checklist | local real-Docker rehearsal attempt 3 passed (request loops 238/238, 107/107, 161/161 HTTP 200); attempt 2 found and led to a fix for a database-restart defect; attempt 4: a frontend without index.html cost 83 of 181 requests to `/` (root cause found and fixed: the frontend was never validated before the switch); attempt 5: that case is now refused before anything changes (0 failed of 105 and 108), but a fault that appears only after the switch still costs about 20 s of errors (79 of 171); nothing on AWS yet |
| G | Monitoring & rollback | 15 | In progress (local evidence only) | see checklist | broken release rejected, manual rollback and post-switch automatic rollback verified in LOCAL real Docker (attempts 3-5); exit code 3 (deploy and recovery both failed) covered OFFLINE only; `rollback.yml` written but never run; no AWS or staging run; staging demo pending |
| H | Debugging & Copilot | 10 | Not started | – | User's real Copilot prompts |
| I | Docs & repo quality | 5 | Not started | – | README reproducible |

## Roadmap
| Phase | Scope | Status |
|---|---|---|
| 0 | Docs, .gitignore, checklist, architecture | Done (merged to main in PR #1) |
| 1 | git init, gitleaks pre-commit hook, GitHub repo + push protection | Done: public repo, branches pushed, secret scanning and push protection enabled, PR #1 merged. Branch protection deliberately not configured until CI exists (Phase 3) |
| 2 | App code (frontend, backend, tests), PostgreSQL schema and migrations, frontend and backend Dockerfiles, local development Docker Compose, `.env.example` placeholder files | Implementation and the approved remediation (13 decisions, 2026-11-20) written on `feature/phase2-app-code`; verified locally (see "Phase 2 remediation and verification"). Merged to `main` in PR #3 (application, tests, backend Dockerfile, CI); the remaining Docker foundation (frontend Dockerfile, dev/test Compose, verify scripts, evidence) is committed locally as f0f55ce on `feature/phase2-docker-compose-leftovers` (not pushed, no PR). Remaining before completion: user-written tests (docs/PHASE2_TEST_SPECS.md), the Git steps in "Git strategy", the user's review |
| 3 | CI workflow + branch protection (B, C) | Pending |
| 4 | Terraform: plan review, apply only on explicit approval; SSH strategy setup (E) | Pending |
| 5 | Docker/Compose/Nginx + CD staging over SSH (E) | Pending |
| 6 | Production environment approval gate (D) | Pending |
| 7 | Blue-green + zero-downtime proof (F) | Pending |
| 8 | Health check, auto/manual rollback, logs, staging broken-release test (G) | Pending |
| 9 | Copilot workflow + 3+ failure scenarios (H) | Pending |
| 10 | README, screenshots, final history secret scan (A, C, I) | Pending |

Mapping to the Phase 0-10 sequence used in planning conversations. This table's numbering stays authoritative and no status changes:

| Planning-sequence phase | Name | Repository phase above |
|---|---|---|
| 0 | Repository and security foundation | 1 |
| 1 | Documentation and architecture | 0 |
| 2 | Three-tier application development | 2 |
| 3 | Frontend and backend CI | 3 (CI part) |
| 4 | GitHub Actions architecture and artifact management | 3 (architecture and artifacts part) |
| 5 | Secrets and environment management | 6 |
| 6 | AWS EC2 infrastructure and deployment | 4 and 5 |
| 7 | Zero-downtime deployment | 7 |
| 8 | Health checks, monitoring and rollback | 8 |
| 9 | Failure simulation and Copilot debugging evidence | 9 |
| 10 | Final README, screenshots and assignment validation | 10 |

Because the two numberings differ for Phases 0 to 6, an approval must name the phase by repository number and by name, for example "Phase 4 (Terraform, SSH strategy)".

## Decisions log
- 2026-11-17: Stack React+Vite / Express / PostgreSQL.
- 2026-11-17: AWS ap-south-1, CLI profile `devops`, one EC2 instance to start.
- 2026-11-17: Terraform (our choice, not mandated). No apply/destroy without approval.
- 2026-11-17: Docker Compose, Nginx, blue-green, health checks, auto rollback.
- 2026-11-17: Staging and production share the single instance as isolated Compose projects.
- 2026-11-17: No root credentials, no permanent AWS keys.
- 2026-11-17: Node matrix is 20 and 22 (not 18). (Superseded by the 2026-11-19 runtime entry below.)
- 2026-11-17: SSH strategy = port 22 closed by default, opened per run (see ARCHITECTURE.md).
- 2026-11-17: Rollback demo = controlled staging test with failed post-deploy validation.
- 2026-11-17: Live URL pending; no IP/DNS/URL in any repo file.
- 2026-11-17: Proposed (not deployed): sweeper every 5 min, temporary SSH rule expiry 15 min, deploy job timeout <= 10 min, EventBridge rule plus CloudWatch alarms for cleanup failures (docs/OIDC_DESIGN.md).
- 2026-11-17: IAM cannot enforce port or CIDR for security group rules (no documented condition key); the workflow enforces tcp/22 and the runner /32, the sweeper detects violations.
- 2026-11-19: Phase 2 planning direction approved by the user (planning only; NOT implemented; implementation not yet approved): React + Vite frontend; Node.js + Express 5 backend with Zod and pg (`/health`, `/version`, `/api/*`, guest checkout, graceful shutdown); PostgreSQL 16 schema and additive migrations; automated tests; frontend and backend Dockerfiles; local development Docker Compose with the database on an internal network, a named volume and no published port; `.env.example` files with placeholders only. Phase 2 stays separate from CI/CD, AWS and production deployment. These are our design choices (R); the assignment itself requires a frontend, a backend REST API, a relational database and meaningful tests.
- 2026-11-19: Runtime direction approved as planning direction (not implemented): Node.js 22 and 24 for both backend and frontend, local development on Node.js 24. The Node 22 patch used must satisfy every selected dependency: per npm registry `engines` metadata read on 2026-11-19, jsdom 31.0.1 needs Node 22.22.2 or newer on the 22 line, vitest 5.0.5 needs 22.12 or newer and eslint 10.15.0 needs 22.13 or newer. Actual compatibility is to be verified before any dependency installation. The 2026-11-17 entry above is marked superseded, and CLAUDE.md, docs/ARCHITECTURE.md, docs/GITHUB_SETUP.md, checklist row C5 and the Part C tracker note were aligned with this entry in the same documentation update.
- 2026-11-19: Phase 2 application decisions approved as planning direction (not implemented): small custom structured JSON logger with no logging dependency; Vitest for frontend and backend tests, with Supertest and React Testing Library; no React Router initially (simple view state, kept extensible); BDT as the initial demo currency, held in one central application constant and formatted with proper currency formatting; optional local-development backend loopback binding at 127.0.0.1:3100 (configurable; changed from 3000 because 3000 was in use on the development host) and the PostgreSQL port never published; about 45 meaningful tests (no artificial tests added to reach a number) across unit, API, database integration and frontend; about 8 fictional seed products with locally maintained placeholder SVG images and no copyrighted images.

- 2026-11-20: User approved Phase 2 implementation ("Phase 2 (App code, tests, Dockerfiles)"). Implemented as planned, with these deviations or additions: the local Compose file is `deploy/docker-compose.dev.yml` with `deploy/.env.example`; the frontend container's Nginx proxies `/api/` to `backend:3000`; the vitest version resolved to 5.1.1 (the 2026-11-19 note said 5.0.5), engines unchanged. The test count ended above the "about 45" planned (64 after the remediation: 39 backend, 25 frontend).
- 2026-11-20: User approved 13 remediation decisions after the Phase 2 review: (1) PR strategy Option 1, a separate documentation PR first, nothing merged by the assistant; (2) pool/query timeouts and id-range validation; (3) dedicated test database plus per-run schema; (4) quantity clamped to a minimum of 1, removal only by the Remove button; (5) two PostgreSQL roles with explicit per-table grants; (6) pinned images with exact versions and digests, Docker Dependabot planned for Phase 3; (7) production seeding explicit, manual or workflow-dispatch, idempotent, never automatic in a production deployment; (8) drop the database currency default, expose the currency through the API, `en-IN` formatting after a compatibility check, BDT stays the demo currency; (9) the backend build is a Docker image build plus Node import and startup validation, recorded as R; (10) pair approach for tests (the user writes them, the assistant drafts specs and reviews); (11) LF rules for shell-sensitive files only; (12) genuine outputs saved in docs/evidence/phase2/; (13) deferred findings recorded here. Implementation notes: decision 8 was implemented through the existing product and order payloads (no new `/api/config` endpoint), pending the user's confirmation; `en-IN` resolves natively on Node 24.15.0 (ICU 78.2) and Node 22 was not checked.
- 2026-11-20: User approved eight follow-up decisions after the Phase 1 audit and preparation report: (1) F-2 option C, sanitize evidence for the public repository and keep the originals outside it; (2) the narrow `.gitignore` exception `!docs/evidence/**/*.log`; (3) `rollback.yml` from current main tooling with a dynamic GitHub Environment, keeping SSH logic maintainable without unnecessarily modifying `cd.yml` (implemented as identical steps guarded by a CI diff check, not a refactor); (4) correct the `cd.yml` comments and replace `cp -r deploy` with an explicit file list; (5) add the CI job "Deploy scripts and Compose", NOT a required branch-protection check; (6) script hardening so `BG_ALLOW_LOOSE_SECRETS` cannot apply to staging or production; (7) a real-Docker attempt 4 on local Docker Desktop only; (8) correct the stale Node 22 status without claiming more than was validated. Interpretations to confirm: the guard accepts the bypass only when `SHOPNEST_PROJECT_PREFIX` is not `shopnest` and `HTTP_BIND=127.0.0.1`, and only for the exact value `1`; the distinct exit code for "failed and not restored" that was offered as optional was NOT implemented.
- 2026-11-20: User approved pushing the two branches and opening PR #5 (against `main`) and PR #6 (against the PR #5 branch), no squash, no merge without separate approval, plus: an investigation of the 83 failed requests of attempt 4 before any change (docs/evidence/bluegreen-local/attempt4-failure-analysis.md), a minimal root-cause fix with a new real-Docker rehearsal (attempt 5), and a distinct exit code when a deploy fails and its automatic rollback also fails (3; 1 = failed with the previous release serving). `LIVE_ATTEMPTS` was NOT changed. Open decision: whether to shorten the post-switch failure window (about 20 s; see the analysis).

## Phase 2 remediation and verification (2026-11-20)
Evidence folder: `docs/evidence/phase2/`. Every file there is a genuine captured output (secrets redacted; none were printed). SAVED = in that folder. A failed first run of two checks is kept next to the passing rerun on purpose.

### What was implemented (approved decisions 1-13)
| # | Decision | Implemented as |
|---|---|---|
| 2 | Pool/query timeouts, id-range validation | `backend/src/db.js` (`connectionTimeoutMillis`, `statement_timeout`, pool `error` listener, idle timeout), `config.js` (`DB_*` variables), `validation.js` (`INT4_MAX`, digits-only path ids) |
| 3 | Test database isolation | `backend/test/helpers/test-db.js`: name must end `_test`, loopback host unless `ALLOW_REMOTE_TEST_DATABASE=true`, server-reported name re-checked, each run works in its own `test_<random>` schema; nothing drops `public`. `deploy/docker-compose.test.yml` provides a tmpfs database. The migrations support per-run schemas |
| 4 | Quantity | `QuantityInput.jsx` (draft vs committed value), reducer clamps to 1..min(stock, 20); only the Remove button removes a line |
| 5 | Two roles, explicit grants | `deploy/db/init/01-roles.sh` creates `shopnest_owner` (migrations, seed) and `shopnest_app` (API); bootstrap superuser `shopnest_admin` only for init and the health check; migration `003_app_role_grants.sql` grants per table (products SELECT plus UPDATE on the `stock` column only (column-level grant, because the API's only write to products is the stock decrement); orders and order_items SELECT/INSERT; one sequence USAGE; no DELETE, no DDL, no `schema_migrations`) |
| 6 | Image pinning | exact version plus digest in both Dockerfiles and both Compose files: `node:24.22.3-alpine3.24`, `postgres:16.16-alpine3.24`, `nginxinc/nginx-unprivileged:1.29.8-alpine3.23` (digests looked up read-only with `docker buildx imagetools inspect` on 2026-11-20; the node and nginx digests equal what the moving tags resolved to). Dependabot for Docker is PLANNED for Phase 3, not created |
| 7 | Production seed | `assertSeedAllowed` (allow-list `development`/`test`; otherwise needs `ALLOW_PRODUCTION_SEED=true`); seeding is its own dev-only `seed` Compose service, `migrate` only migrates; the image sets `NODE_ENV=production` so the image refuses to seed by default. How staging/production get a catalogue (manual or workflow-dispatch with the flag) is decided in Phase 5 |
| 8 | Currency | migration 002 drops the `products.currency` default; orders take their currency from the products and reject a mix (`mixed_currency`); the frontend no longer holds a currency constant (it formats the currency in each API payload; locale `en-IN`, in `src/config/locale.js`). Interpretation to confirm: no separate `/api/config` endpoint was added, because products and orders already carry the currency |
| 9 | Backend build | recorded as R (see checklist row B3a); `deploy/scripts/verify-backend-build.sh` |
| 11 | LF rules | `.gitattributes`: `*.sh`, `Dockerfile`, `.dockerignore`, `nginx.conf`, `deploy/db/init/*`; Markdown is not listed |
| 12 | Evidence | this folder |
| 10 | Test ownership | specs in `docs/PHASE2_TEST_SPECS.md`; the new tests are NOT written (yours). Only four existing tests were adjusted, listed in section C of that file |
| 1 | PR strategy | see "Git strategy" below; nothing pushed or opened |

### Saved evidence (results)
| File | Result |
|---|---|
| `backend-lint.txt`, `frontend-lint.txt` | both clean (exit 0) |
| `backend-tests-no-db.txt` | 28 passed, 11 skipped (database tests need `TEST_DATABASE_URL`) |
| `backend-tests-with-db.txt` | 39 passed against disposable PostgreSQL 16.16, per-run schema |
| `frontend-tests-run1-failed-nbsp.txt` | FAILED run, 3 of 25: my expectation used a normal space where `Intl` emits U+00A0 (a test bug, not a formatter bug) |
| `frontend-tests.txt` | 25 passed (rerun after fixing the expectation) |
| `frontend-build.txt` | `vite build` succeeded |
| `adhoc-backend-validation-run1-script-id-artifact.txt` | 3 of 44 checks failed: the scratch script's own failed INSERT burned product id 1 (script bug) |
| `adhoc-backend-validation.txt` | 44 of 44 checks passed: guard, schema isolation, migrations 002/003, pool error handling, timeouts, id ranges, product detail, currency, seed guard. It is a scratchpad script, not a test suite and not committed |
| `adhoc-frontend-quantity-validation.txt` (+ two earlier runs kept) | 10 of 10 passed in jsdom (not a browser): clearing the box does not remove the line; retyping commits; clamp to stock and to 20 with the hint; typing 0 clamps to 1 and keeps the line; fractional input is not committed and blur restores the value; only Remove removes; currency comes from the API data; the reducer ignores non-integers. The two earlier runs failed only because of errors in the temporary spec (an `<output>` element with the status role, per-character typing of 1.5, USD rendered as `$`, a regex mangled by string replacement). The temporary spec was deleted after the run and is not in the repository |
| `backend-build-validation.txt` | 6 checks passed: image builds, modules import with production dependencies only, entrypoint refuses to start without `DATABASE_URL`, non-root, no tests in the image, `NODE_ENV=production` |
| `stack-verification.txt` (+ `stack-verification-run1-table-level-update.txt`, the earlier passing run of 28 checks against the table-level grant) | 38 checks passed in the throwaway project `shopnest-verify`: db, backend and frontend reach healthy (frontend healthy after 3 s, and 6 s after a restart); no published db port; internal network; roles not superuser; app role denied CREATE/DROP/ALTER/DELETE/UPDATE orders/`schema_migrations`, can update only `products.stock` and gets `permission denied` for price_minor, name, currency, sku, description, image_url and INSERT INTO products; the server's own session list shows the running API connected only as `shopnest_app` and `schema_migrations` owned by `shopnest_owner`; order via the proxy; data and stock survive a stop/start without deleting the volume; the idempotent seed neither duplicates nor resets |
| `stack-verification-run3-staged-guard.txt` | **62 of 62 checks passed, exit 0** (captured 2026-11-20T04:39:52Z, `bash deploy/scripts/verify-stack.sh` from the repository root, script sha1 starting d6b8dc0f63f4), in the throwaway project `shopnest-verify`. Docker safety preflight passed (`DOCKER_HOST` unset; active context `desktop-linux`; endpoint `npipe:////./pipe/dockerDesktopLinuxEngine`, local). Staged start with **four successful database guard checks** (db container created but not started; db healthy; and both again on the restart), each before `migrate`, `seed` or any other write. **G1 DELETE 6/6** and **G2 TRUNCATE 6/6** (per table for products, orders, order_items: no privilege in the catalog, and the attempt gets `permission denied`; DELETE uses `WHERE false`, TRUNCATE runs inside `BEGIN ... ROLLBACK`). **G3 ownership 4/4** (products, orders, order_items, schema_migrations owned by `shopnest_owner`). The running API connected as **`shopnest_app`** only; migrations and seed ran as `shopnest_owner`. All earlier checks passed again (column-level `UPDATE (stock)`; denied price_minor, name, currency, sku, description, image_url and INSERT INTO products; persistence across a stop/start). Afterwards 0 `shopnest-verify` containers, volumes or networks remained; a before/after snapshot of every container, volume and network was identical, and only the four `shopnest-verify-*` images were rebuilt. `shopnest-dev` had no resources before or after. The 38-check file and the 28-check run-1 file are unchanged |
| ORIGINAL scans (3): `secret-scan-2026-11-20-working-tree.txt`, `secret-scan-2026-11-20-history.txt`, `secret-scan-2026-11-20-added-lines.txt` | gitleaks 8.30.1, all three exit 0, "no leaks found": working tree about 486 KB with Git-ignored paths excluded; history 13 commits, committed content only; added lines 96 files and about 10,729 added lines. Scopes and commands in "Secret scans" below. The earlier undated `secret-scan-*.txt` (captured 04:08Z) are kept as an earlier run |
| POST-DOCUMENTATION confirmatory rescans (2): `secret-scan-2026-11-20-post-docs-working-tree.txt`, `secret-scan-2026-11-20-post-docs-added-lines.txt` | run after the `PROJECT_STATUS.md` and `docs/REQUIREMENTS_CHECKLIST.md` update; both exit 0, "no leaks found": working tree about 497 KB with Git-ignored paths again excluded; added lines 98 files and about 10,770 added lines. They rescan two of the three scopes only (no history rescan) and do not replace the original three |

Test totals (declared and run): backend 39 (3 config, 11 database integration, 4 logger, 9 validation, 12 API), frontend 25 (4 api, 8 cart, 3 format, 10 app). Total 64; it was 65 before the tautological BDT-constant test was removed together with the constant.

### Not verified (do not claim)
- Node 22 INSIDE A CONTAINER, and Node 22 on the development host: not tested (images run `node:24.22.3`). CORRECTION 2026-11-20: the earlier wording "Node 22 at any layer" was stale after CI ran. GitHub Actions run 44726873391 (push to `main`, commit 56cb0e8) shows Frontend (Node 22), Frontend (Node 24), Backend (Node 22), Backend (Node 24) and Backend Docker image all `success`; the lint, test (including the 39 backend tests, none skipped, and the `en-IN` formatting tests) and build steps therefore ran on Node 22 in CI. That is CI evidence for the runner, not for containers or the host. The `engines` field is not evidence.
- Browser behaviour: no browser test, no screenshots. Frontend results are jsdom tests, a Vite build and HTTP checks.
- GitHub Actions CI: no workflow has run.
- The 62/62 verification covers the local development Compose stack only. It is not evidence for AWS or EC2, Node 22 in containers, or a real browser (GitHub Actions CI results are recorded in the checklist, rows B2, B3 and C5).
- Remaining security gaps G4-G10 in the verification script (see the deferred table) are not implemented, so the permission checks are not exhaustive.
- `en-IN` formatting was checked on Node 24.15.0 (ICU 78.2) only. In the browser it uses the browser's own ICU.
- The new tests in `docs/PHASE2_TEST_SPECS.md` do not exist yet.

### Git strategy (decision 1, Option 1; SUPERSEDED 2026-11-20: PRs #2 to #4 were merged and the work is now on the two local branches listed in the header and the Commits table)
- Facts (CLI-verified 2026-11-20): `feature/phase2-app-code` is at `dec31e1`, whose only parent is `4d8f304` (= `origin/main`). `main..HEAD` is exactly `dec31e1` (5 documentation files). `dec31e1` exists only locally: `origin` has no `docs/complete-planning-documentation` or feature branch.
- Plan: push `docs/complete-planning-documentation`, open a documentation-only PR into `main`, merge it with a NORMAL merge commit (never a squash, or `dec31e1` would reappear in the Phase 2 diff), then open the Phase 2 PR. The feature branch must be brought up to date after that merge, which is a separate Git operation needing its own approval. No history is rewritten.
- Pending: nothing has been staged, committed, pushed or opened. The uncommitted documentation edits (this file and the checklist) build on `dec31e1`.

## Secret scans (Phase 2 working tree)
Three ORIGINAL scans were run on 2026-11-20 with gitleaks 8.30.1: the default ruleset (`useDefault = true`) plus this repository's custom rules `shopnest-ipv4-address` and `shopnest-ec2-hostname` in `.gitleaks.toml`; the lockfiles are allowlisted. All three exited 0 with "no leaks found". The scopes differ:
- Original scan 1 of 3, working tree: `docs/evidence/phase2/secret-scan-2026-11-20-working-tree.txt`; `gitleaks dir . --config .gitleaks.toml --no-banner --redact`. Files on disk that Git does not ignore (tracked, modified and untracked), about 486 KB. **Git-ignored paths were NOT scanned**: `assignment/`, `backend/node_modules/`, `frontend/node_modules/` and `frontend/dist/` (measured: Git sees about 483 KB of non-ignored files, matching what gitleaks reported); no ignored `.env`, key or state file exists on disk. The header of that evidence file was corrected after this was measured and says so.
- Original scan 2 of 3, history: `docs/evidence/phase2/secret-scan-2026-11-20-history.txt`; `gitleaks git . --config .gitleaks.toml --no-banner --redact --log-opts=--all`. 13 commits reachable from all refs. Committed content only, so none of the uncommitted Phase 2 files.
- Original scan 3 of 3, added lines: `docs/evidence/phase2/secret-scan-2026-11-20-added-lines.txt`; the diff of the working tree against `main` (which includes the local-only commit `dec31e1`) plus every untracked file, 96 files and about 10729 added lines, fed to `gitleaks stdin`; built without staging anything.
The earlier undated files `secret-scan-working-tree.txt`, `secret-scan-history.txt` and `secret-scan-added-lines.txt` (captured 2026-11-20T04:08Z, before the latest edits) are kept unchanged.
Two POST-DOCUMENTATION confirmatory rescans were then run after the `PROJECT_STATUS.md` and `docs/REQUIREMENTS_CHECKLIST.md` update, to cover the updated text:
- Confirmatory rescan A, working tree: `docs/evidence/phase2/secret-scan-2026-11-20-post-docs-working-tree.txt`; the same command and the same exclusion of Git-ignored paths as original scan 1; about 497 KB; exit 0, "no leaks found".
- Confirmatory rescan B, added lines: `docs/evidence/phase2/secret-scan-2026-11-20-post-docs-added-lines.txt`; the same method as original scan 3; 98 files and about 10,770 added lines (including the updated docs and the original scan evidence files); exit 0, "no leaks found".
All five scans are preserved. The three original scans ran before the documentation update and the two rescans after it. There was no history rescan, since nothing was committed in between. "No leaks found" means no match against the rules above; it is not proof that the repository contains no secret. The pre-commit hook will scan the staged files again at commit time.

## Deferred findings and test gaps (decision 13)
Severity is the reviewer's estimate. Status: Open = not started, Deferred = accepted for the stated phase, Partial = partly addressed.
| ID | Severity | Description | Target phase | Status |
|---|---|---|---|---|
| B4 | Low-Med | `/health` is liveness and readiness at once and stays "ok" while draining | 7 and 8 | Deferred |
| B5 | Low | No `uncaughtException`/`unhandledRejection` handlers; `db.close()` in shutdown is not guarded | 8 | Deferred |
| B6 | Low | Migrations take no advisory lock; two instances migrating at once could race | 5 (before blue-green) | Deferred |
| B8 | Low | No rate limiting; no security headers (helmet or Nginx headers) | 5 and 10 | Deferred |
| N1 | Low | `orders.total_minor` is an int4: a future high-priced catalogue could overflow it | later | Deferred |
| F3 | Low | The cart keeps a price snapshot; the server total can differ from the displayed one | 10 | Deferred |
| F4 | Low | Accessibility: no `aria-invalid`/`aria-describedby` on checkout errors, no focus management on view changes, no automated a11y check, contrast not measured | 10 | Deferred |
| F5 | Low | No fetch timeout or abort handling in the API client | 10 | Deferred |
| D7 | Low | LF/CRLF: shell-sensitive files are pinned to LF; other files still follow `core.autocrlf` | – | Partial |
| N2 | Low | Compose passes passwords inside `DATABASE_URL` (visible to `docker inspect`); acceptable for local development only | 5 and 6 | Deferred |
| N3 | Low | Migration 003 hard-codes the role name `shopnest_app` and is a no-op where the role is missing (a missing role in production would surface as "permission denied" at runtime); role creation runs only on an empty data volume | 5 | Deferred |
| N4 | Info | Dev Compose seeds automatically (development only by design); the production catalogue mechanism is undecided | 5 | Open |
| N5 | Info | Images run Node 24 only; the Node 22 matrix covers lint, tests and build on the CI runner, not the container | 3 | Open |
| N6 | Low-Med | Node 22 compatibility: verified on the CI runner for lint, tests and build (run 44726873391, 2026-11-20); NOT verified in a container or on the development host | 3 | Partial |
| N7 | Medium | No browser test or screenshots | 10 | Open |
| T1 | Medium | New tests specified in `docs/PHASE2_TEST_SPECS.md` are unwritten (B4 ownership) | before B4 is claimed | Open (user) |
| T2 | Low | Test gaps: graceful shutdown (manual only), migration rollback, opposite-order concurrency, logger redaction, `validateCustomer` edge cases, integration tests hard-code seed values, duplicated `/health` assertion, a shallow `config.test.js` | with T1 | Open (user) |
| G4 | Low-Med | `deploy/scripts/verify-stack.sh`: the older `expect_denied` checks (CREATE TABLE, DROP TABLE products, ALTER TABLE products, DELETE FROM products, UPDATE orders, read schema_migrations) accept any failure, so a SQL typo would pass | 3 | Open |
| G5 | Low-Med | The `products.id` and `products.created_at` columns are not tested as non-updatable by `shopnest_app` | 3 | Open |
| G6 | Low-Med | No mixed-column test (an UPDATE of stock plus a forbidden column must be denied as a whole) | 3 | Open |
| G7 | Low | `schema_migrations` is only SELECT-tested; INSERT, UPDATE and DELETE are not | 3 | Open |
| G8 | Low | `UPDATE order_items` is not tested (only `UPDATE orders`) | 3 | Open |
| G9 | Low | Other DDL variants are untested: CREATE INDEX, CREATE SCHEMA, CREATE VIEW/FUNCTION, DROP TABLE orders, temporary tables, GRANT, SET ROLE | 3 | Open |
| G10 | Low | Only `rolsuper` is asserted; CREATEDB, CREATEROLE, REPLICATION and BYPASSRLS are not | 3 | Open |
| N8 | Low | `shopnest_app` has table-level SELECT on `orders`, which includes `customer_email` and `shipping_address`; the API reads only id, status, total_minor, currency and created_at (noted in review, outside the G list) | 5 | Open |
| N9 | Low-Med | The working-tree gitleaks scan does not cover Git-ignored paths (`assignment/`, `node_modules`, `dist`, and any future `.env` file); the committed history and the diff are covered separately | 3 and 10 | Open |
| P1 | Info | Dependabot (docker, npm, github-actions) to be added so pinned digests do not go stale | 3 | Planned |
| P2 | Info | Frontend has no product detail view; confirm whether the assignment needs one | 10 | Open |
| P3 | Low-Med | A fault that appears only AFTER traffic moves still causes about 20 s of errors before the automatic rollback (attempt 5, step 6: 79 of 171 requests to `/`); options: fewer or cheaper live-check attempts, or a candidate check before the switch | 8 | Open (decision) |
| P4 | Info | Exit code 3 (deploy and recovery both failed) is tested offline only | 8 | Open |
Fixed in this remediation (evidence above): pool error handler (B1), pool and statement timeouts (B2), out-of-range ids (B3), currency ignored by order creation (B7), integration tests dropping `public`, quantity clearing removing the line (F1), `en-BD` locale silently falling back (F2), floating image tags (D2), least-privilege role (D1), index and currency default (D6), unguarded production seeding (D5). Volume persistence (D3) and frontend health (D4) are verified in `stack-verification.txt`.

## Phase 2 open items for the user
1. B4 requires tests "written by me": write the tests in `docs/PHASE2_TEST_SPECS.md` yourself and understand them; Claude reviews.
2. Confirm the currency interpretation (decision 8): no `/api/config` endpoint; currency flows through product and order payloads.
3. Approve the Git steps (push the docs branch, open the docs PR, merge, update the feature branch) separately; none has happened.
4. Optional: Part B3 backend "build" is our interpretation (R); confirm it with the instructor if you want certainty.
5. Decide whether to harden G4-G10 in `verify-stack.sh` now or in Phase 3 (when CI can run it); any change to the script needs a fresh Docker verification and new evidence.

## GitHub state (verified with `gh` on 2026-11-17; rows marked 2026-11-19 or 2026-11-20 were checked again)
| Item | Value |
|---|---|
| Repository | https://github.com/Bhabotos/shopnest-devops-cicd |
| Visibility | Public |
| Default branch | main |
| Remote | `origin` (HTTPS), fetch and push |
| Pull request | #1 https://github.com/Bhabotos/shopnest-devops-cicd/pull/1 |
| PR state | MERGED 2026-11-17T17:24:31Z by Bhabotos with a normal merge commit (no squash or rebase); base `main`, head `docs/project-foundation` |
| PR title | docs: establish ShopNest project foundation |
| Remote `main` | 56cb0e84811362507cd7f26234e9a42af819bb86 (gh-verified 2026-11-20; merge commit of PR #4; parents d72695b961f368894258af2ec3919738774cd6e9, the merge commit of PR #3, and 5252243a3d8141fddbe962a7ec7b904deaf5acea) |
| Pull requests #3 and #4 | #3 https://github.com/Bhabotos/shopnest-devops-cicd/pull/3 (application code, tests, Dockerfiles, CI) MERGED 2026-11-20T10:36:53Z, merge commit d72695b961f368894258af2ec3919738774cd6e9. #4 https://github.com/Bhabotos/shopnest-devops-cicd/pull/4 (disabled draft `cd.yml`) MERGED 2026-11-20T11:20:58Z, merge commit 56cb0e84811362507cd7f26234e9a42af819bb86. Both normal merge commits; the feature branches were kept |
| Pull requests #5 and #6 | #5 https://github.com/Bhabotos/shopnest-devops-cicd/pull/5 (base `main`, head `feature/phase2-docker-compose-leftovers`, the Docker foundation) and #6 https://github.com/Bhabotos/shopnest-devops-cicd/pull/6 (base `feature/phase2-docker-compose-leftovers`, head `feature/bluegreen-deploy-scripts`, stacked on #5). Both OPEN, not merged. CI does not run on #6 while its base is not `main` (the CI workflow triggers on pull requests into `main`), so #6 needs its base changed to `main` after #5 merges (normal merge commit, no squash) |
| Remote `docs/project-foundation` | e6e7cbcd04a32fa89438dc02d1b916422e57490b (branch kept after merge, as requested) |
| Pull request #2 | https://github.com/Bhabotos/shopnest-devops-cicd/pull/2 (gh-verified 2026-11-20): MERGED 2026-11-19T16:34:45Z with a normal merge commit 4d8f3049070a7ea59c583f360e209ba47059617d (parents 668a93e82f72b0ea804367714e34b64c6412306f and 90825d71c1677eeabe7ef08832dd434bd62e63af); base `main`, head `docs/post-merge-status` at 90825d7, 4 commits (9683fdd, 5f054ac, c971105, 90825d7) |
| Local-only commit | `dec31e1` (docs: record approved Phase 2 planning direction and align runtime documentation) exists only in the local clone, on `docs/complete-planning-documentation` and `feature/phase2-app-code`. `origin` has neither branch (git ls-remote, 2026-11-20). It is the only commit on the feature branch beyond `main` (`4d8f304`) |
| Secret scanning | enabled (re-verified 2026-11-19) |
| Push protection | enabled (re-verified 2026-11-19) |
| Secret-scanning alerts | 0 (re-verified 2026-11-19) |
| Email privacy | USER-REPORTED: "Keep my email addresses private" and "Block command line pushes that expose my email" are enabled in the GitHub web UI. CLI-VERIFIED 2026-11-19: `gh api user/public_emails` returns `[]`. UNKNOWN: the state of the block-pushes toggle (reading it needs the `user` token scope, which was not requested). No screenshot of these settings exists in the repository (CLI-verified: 0 image files). |
| Branch protection on main | APPLIED 2026-11-20 and read back (`all_ok: true`): pull request required with 0 approvals; required checks Frontend (Node 22), Frontend (Node 24), Backend (Node 22), Backend (Node 24), Backend Docker image, each bound to the GitHub Actions app (id 15368); branches must be up to date; enforced for administrators; force pushes and deletions disabled; code owner review off. The first PUT returned HTTP 422 because it sent both `contexts` and `checks`; the corrected payload used `checks` only. No rulesets |
| Actions workflows / runs / secrets / variables / Environments | Workflows `CI` and `CD`. CI runs all successful: https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44714705352 (PR #3), 44720737504 (push, main), 44725363123 (PR #4), 44726873391 (push, main). CD run 44726970656 (workflow_run) concluded `skipped`: `CD_ENABLED` is unset. Secrets 0, variables 0, Environments 0 |
| AWS resources, Terraform apply, deployment | None have occurred. CD is disabled |

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
| 90825d7 | docs/post-merge-status | docs: correct stale status and clarify secret-scan evidence |
| 4d8f304 | main | Merge pull request #2 from Bhabotos/docs/post-merge-status |
| f0f55ce | feature/phase2-docker-compose-leftovers (PR #5) | feat: add frontend container, dev/test Compose stacks and Phase 2 evidence |
| 6d186e5 | feature/bluegreen-deploy-scripts (PR #6) | feat(deploy): add blue/green production stack, deploy and rollback scripts |
| 459fe48 | feature/bluegreen-deploy-scripts (PR #6) | test(deploy): add offline blue/green suite with a fake Docker |
| 336d3bc | feature/bluegreen-deploy-scripts (PR #6) | ci: add rollback workflow, deploy-scripts job and an explicit CD bundle list |
| d8e3ddf | feature/bluegreen-deploy-scripts (PR #6) | docs(evidence): add local blue/green rehearsal evidence (attempts 1-4) |
| 461584f | feature/bluegreen-deploy-scripts (PR #6) | docs: record the blue/green rehearsal, rollback workflow and corrected Node 22 status |
| 1c95a13 | feature/bluegreen-deploy-scripts (PR #6) | fix(deploy): validate the frontend before the switch; exit 3 when recovery fails |
| d7b22cf | feature/bluegreen-deploy-scripts (PR #6) | ci: surface exit code 3 in the CD and rollback workflows; clean up rollback tooling |
| a1e436a | feature/bluegreen-deploy-scripts (PR #6) | test(deploy): extend the local rehearsal with the frontend-missing and post-switch scenarios |
| 69d9298 | feature/bluegreen-deploy-scripts (PR #6) | docs(evidence): attempt 4 failure analysis and rehearsal attempt 5 (24 of 24) |
| dec31e1 | docs/complete-planning-documentation, feature/phase2-app-code (LOCAL ONLY, not on origin) | docs: record approved Phase 2 planning direction and align runtime documentation |

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
6. OPEN DOCUMENTATION REQUIREMENT, Part H (GitHub Copilot). Checklist rows H1-H7 stay Not started, and the evidence each one needs is listed in docs/REQUIREMENTS_CHECKLIST.md. CLI-VERIFIED 2026-11-19: no Copilot evidence exists in the repository (no docs/copilot or docs/failures directory, 0 workflows, 0 workflow runs). UNKNOWN: whether Copilot is enabled for the account. Timing: a Copilot origin cannot be shown afterwards, so the first workflow (the first CI workflow) must be created with Copilot when it is first written, with Copilot's unedited output committed before any manual edit. The evidence must be the user's own; nothing is written or reconstructed on the user's behalf.

## Manual actions log
- 2026-11-17: Gitleaks 8.30.1 installed via winget (user-approved).
- 2026-11-17: User provided the verified GitHub noreply email; set as local repo config only (global config unchanged).
- 2026-11-17: Assistant ran git init, created commits and the history scan locally.
- 2026-11-17: With the user's approval, assistant created the public repository, pushed `main` and `docs/project-foundation`, and opened PR #1. No other GitHub settings were changed; secret scanning and push protection were already enabled.
- 2026-11-17: With the user's approval, assistant merged PR #1 with a normal merge commit (668a93e), kept the feature branch, and pulled `main` locally.
- 2026-11-19: USER-REPORTED: the GitHub email privacy settings were enabled in the web UI. The assistant only checked that `gh api user/public_emails` returns `[]` (read-only; no extra token scopes requested; authentication not refreshed).
- 2026-11-19: With the user's approval, the assistant set the global Git `user.email` to the GitHub noreply address. The global `user.name` and the repository-local email were not changed.
- 2026-11-20: Local assistant actions during the Phase 2 remediation (no AWS and no GitHub changes; nothing staged, committed or pushed): created branch `feature/phase2-app-code`; `git add -N` was run once on the new files, leaving intent-to-add index entries only (no content staged); pulled `node:24-alpine` and `nginxinc/nginx-unprivileged:1.29-alpine` because they were absent from the local image store, to read their exact versions and digests; created and removed throwaway containers, volumes and networks (Compose projects `shopnest-dev`, `shopnest-test` and `shopnest-verify`, and a test PostgreSQL on 127.0.0.1:55432); all of them were confirmed gone. Local images built for these runs (`shopnest-dev-*`, `shopnest-verify-*`) may remain in the local Docker image store.
- 2026-11-20: With the user's approval the assistant: created the public CI workflow and opened PR #3, PR #4 (merged by the assistant at the user's explicit request); applied branch protection to `main` with `gh api` (first attempt HTTP 422, corrected payload applied, read back `all_ok: true`); fast-forwarded local `main` to 56cb0e8 and created the local backup branch `backup/pre-sync-da55851`. Local work after PR #4 (not staged, not committed): fixed the two PostgreSQL health checks in the dev and test Compose files (TCP `pg_isready -h 127.0.0.1`); wrote the blue/green deploy, rollback, release-status and request-loop scripts, `deploy/docker-compose.prod.yml`, `deploy/nginx/nginx.conf`, `deploy/env/*.env`, an offline fake-Docker test suite (80 of 80 checks, mutation-tested) and a real-Docker rehearsal script that has NOT been run. No AWS resource, GitHub Environment, secret or variable was created; CD remains disabled.
- 2026-11-20: With the user's approval the assistant ran the local Blue/Green rehearsal on Docker Desktop (local named pipe, project `shopnest-demo-staging`, loopback port 18081, throwaway temp home and random passwords). Attempt 1 stopped at deploy A because the Windows filesystem cannot hold mode 600 on `secrets.env` (the deploy script's check rejected it). Attempt 2 (override `BG_ALLOW_LOOSE_SECRETS=1`, this command only, authorised by the user) recorded 1 failed request of 213 during deploy B (HTTP 500 plus a 2.5 s stall) because deploy B recreated the database container; the run aborted there, so release C and the rollback did not run. Fixes: `up -d --no-recreate db` and stable host mount paths for the database init scripts and the nginx config, with offline regression tests and a database-identity check in the rehearsal. Attempt 3 passed 12 of 12 checks with 238, 107 and 161 requests all HTTP 200 (the loop for the failed C attempt ended about 57 s early). Before and after Docker snapshots were identical (29 containers, 60 images, 14 networks, 26 volumes) and no `shopnest-demo` resource remained. Evidence: docs/evidence/bluegreen-local/ (uncommitted). No AWS, GitHub, Git staging or commit action was taken.
- 2026-11-20 (follow-up, local only): with the user's approval the assistant created branches `feature/phase2-docker-compose-leftovers` (commit f0f55ce, 33 files) and `feature/bluegreen-deploy-scripts` (commits 6d186e5, 459fe48, 336d3bc, d8e3ddf, then the status and checklist update), staged by explicit file list with a gitleaks scan before and after each commit (all clean). Nothing was pushed; no PR, merge, GitHub setting, secret, Environment, AWS or Terraform action. Docker: attempt 4 of the local rehearsal (`--scenario post-switch`, project `shopnest-demo-staging`, loopback port 18081, throwaway home, random passwords, the `BG_ALLOW_LOOSE_SECRETS` override set to 1 for that command only, accepted by the new guard because the script sets the prefix and the loopback bind); before and after Docker listings were identical and no `shopnest-demo` resource remained. Original evidence was copied OUTSIDE the repository (`evidence-originals/` next to the repository, with a SHA-256 manifest) before six files were sanitized (docs/evidence/bluegreen-local/SANITIZED.md). ShellCheck 0.11.0 was installed from PyPI into a scratch directory only (not into the repository or the system) to lint the scripts locally; it is preinstalled on the CI runner.
- 2026-11-20 (PRs and reliability work): with the user's approval the assistant pushed `feature/phase2-docker-compose-leftovers` and `feature/bluegreen-deploy-scripts` (no force push, no history rewrite), opened PR #5 and PR #6 (not merged), then added commits 1c95a13, d7b22cf, a1e436a and 69d9298 to the PR #6 branch. Docker: attempt 5 (`--scenario all`, project `shopnest-demo-staging`, loopback port 18081, throwaway home, random passwords, the loose-secrets override set for that command only and accepted by the guard); before and after Docker listings were identical and no `shopnest-demo` resource remained. Original attempt 5 evidence was copied outside the repository before four files were sanitized. A gitleaks run blocked the first evidence commit (the nginx log excerpt contained the Docker bridge gateway address, flagged by the repository IP rule); the published copy was sanitized instead of loosening the rule. No GitHub setting, branch protection, secret or Environment was changed; no AWS, Terraform or deployment action.

## Risks / limitations
- Privacy (personal data, NOT a credential): merge commit 668a93e on `main` (PR #1, merged 2026-11-17T17:24:31Z, parents eca306c and e6e7cbc; CLI-verified with `git` and `gh` on 2026-11-19) has the account's primary, non-noreply email address and the account's name as author, and GitHub as committer. The author email address is therefore public in commit metadata. It is not a credential, key, password or server address; whether the instructor treats it as relevant to Part D is UNKNOWN. All other commits use the GitHub noreply address as author and committer (CLI-verified 2026-11-19). The email privacy settings were USER-REPORTED as enabled afterwards (see Open question 5); that does not change existing history. Commit 668a93e is unchanged and still public. No history rewrite has been performed or approved. Options: leave as is (recommended), or rewrite `main` with a force push, which may not remove the commit from GitHub's pull-request refs or from existing clones or forks.
- Scheduled sweeper is best-effort: GitHub can delay or drop runs and disables them after 60 days of public-repo inactivity; nominal orphan exposure is about 20 minutes, not bounded.
- IAM cannot restrict SSH rule port/CIDR; a compromised deploy job in an allowed environment could open other ports on the SSH group (mitigations in OIDC_DESIGN.md).
- Single instance: staging/prod are not infrastructure-isolated (document in README).
- GitHub-hosted runner IPs are not fixed; hence per-run port 22 opening strategy.
