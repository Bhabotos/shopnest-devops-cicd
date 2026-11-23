# Submission readiness (2026-11-22, reconciled)

> **UPDATE 2026-11-23 (later):** the GitHub Environments are configured and verified (PR #41, `main` = `053648a`). A separate approval demonstration workflow, `.github/workflows/approval-demo.yml`, is implemented in a pull request and awaits merge; it has not run, no run has paused at "Waiting for review", and no approval is verified. Part D is not complete and Parts E, F and G are not affected. The statement below about `9682ec4` is the earlier update.
>
> **UPDATE 2026-11-23:** `main` is now `9682ec4` (PR #39 merged: the job `production-approval` exists in `cd.yml`, bound to the `production` Environment; it deploys nothing). The approval is NOT verified: the Environment and its required reviewer are not configured and no real manual approval has been demonstrated (CD only ever `skipped`, `CD_ENABLED` unset). No AWS resource, no deployment, no live URL and no new graded evidence. The mark estimate below is unchanged. The SSH versus SSM question for Part E is still pending the instructor. The sections below were last fully reconciled at `18943e5`; only the statements about the production gate, the required checks and the PR list were corrected on 2026-11-23.
>
> **Earlier update, 2026-11-22 (later; superseded by the one above):** `main` was then `fc67aac` (PR #34 merged: the architecture, setup and Claude rules documents now describe the SSM design). This file's evidence picture is unchanged: no AWS resource, no deployment, no live URL, and no new graded evidence. The SSH versus SSM question for Part E is pending the instructor.

Reconciled against GitHub at `main` = `18943e5271f9ba62c2388616327cf28287168680` (the merge of PR #32, read with `git fetch` and `gh` on 2026-11-22; first written at `011752c` and updated after PRs #31 and #32). **Actual evidence** (something ran and its output was seen) is kept apart from **documented or planned**
functionality. Mark estimates are judgement, not grading. Nothing here claims an AWS deployment, a zero-downtime result on AWS, or any screenshot that is not on `main`. The first version of this file was written on 2026-11-21 at `8feb5a0`; sections 1, 4, 5, 6 and 7 below replace it, and sections 2 and 3 are unchanged from that version.

Status labels used below: **IV** = implemented and verified; **IE** = implemented but evidence incomplete; **NI** = not implemented.

## 1. Verified state (read from git and the GitHub API on 2026-11-22)
- 2026-11-23 addition: `origin/main` = `9682ec4` (PR #39 merge, 2026-11-23T04:48:48Z; head `e933ed1`; all eight checks `success`, five of them required). Also merged since `18943e5`: #33 (`7d88e9b`), #34 (`fc67aac`) and #35 (`5f4f657`). After the PR #39 merge, CI (run 45114055026) and Terraform CI (run 45114055032) succeeded on `9682ec4`, and CD (run 45114262715) was `skipped` (`CD_ENABLED` unset). Six checks ran and passed on PR #34, but only five checks are required by branch protection ("Deploy scripts and Compose" is not required).
- `origin/main` = `18943e5` (PR #32 merge; historical, read 2026-11-22). Merged PRs: #1 to #11, #14 to #27 and #29 to #32 (all except #28), and, from the 2026-11-23 line above, #33 to #35 and #39. PR #31 (`c6a1437`, the status documents) and PR #32 (`18943e5`, the Part H screenshots) merged on 2026-11-22. Merge commits for #22 to #30: #22 `bd1fe99`, #23 `2664382`, #24 `33f1a32`, #25 `d49d5fb`, #26 `e6e93a0`, #27 `4daa00e`, #29 `d6532bd`, #30 `011752c`. Open: Dependabot PRs #12 and #13, and **PR #28**, a deliberate failing-test demonstration for Part H (head `5472d40`, state BEHIND, no comments or reviews), which **must stay open and must not be merged**.
- Latest runs on `main` (read with `gh` on 2026-11-22): CI succeeded at `18943e5` (run 44986851698, the push after the PR #32 merge), at `c6a1437` (44986162185) and at `011752c` (44929895488); all five required checks also passed on the heads of PRs #31 and #32. CD has only ever been `skipped` (26 runs as of 2026-11-22, including the one at `18943e5`; `CD_ENABLED` unset); `rollback.yml` has never run.
- **Five failed runs exist**, none may be deleted:
  - Deliberate, Part H: 44884178546 (YAML, recovered by 44884710861, fix `d2b645c`); 44884809417 (deployment health check, `workflow_dispatch`, recovered by 44885032635, no fix commit); 44920064307 (failing test on PR #28, recovered by 44920708004, fix `5472d40`).
  - Accidental, NOT Part H: 44864872114 (CI on PR #11, the "Deploy scripts and Compose" guard step) and 44916673865 (CI on PR #26: the offline CI-helper tests reported 141 passed and 1 failed, "the guard is executable in the bundle"; fixed by `3fe0ca0`, green run 44917232302).
- Copilot: `docs/copilot/` and `pipeline-demo.yml` are on `main` (PRs #20, #21); the prompts and the Copilot origin are the owner's statements, not independently verified. **Copilot troubleshooting prompts and answers are UNAVAILABLE** and are not reconstructed.
- Screenshots: **the 13 Part H screenshots are on `main`** (PR #32, `docs/screenshots/part-h/`, mapped to runs in `docs/failures/PART_H_FAILURES.md`, linked from the README). Two are partial (failure 2's failing step is not expanded; the branch protection page shows only its top). No screenshot shows a blocked merge, a run ID or Copilot.
- `docs/failures/PART_H_FAILURES.md` (all three failures, PR #29) is on `main`.
- GitHub settings (updated 2026-11-23, API read-back): the `staging` and `production` Environments exist (main-only; `production` requires reviewer `Bhabotos`, self-review OFF, administrator bypass OFF); 0 Actions secrets, 0 Actions variables, `CD_ENABLED` unset, no Deployment entry, no workflow triggered. The approval pause has NOT been tested. (The earlier 2026-11-22 reading was 0 Environments.) Five required checks (Frontend and Backend on Node 22 and 24, Backend Docker image), strict, enforced for administrators.
- AWS: no resource is known to exist. A local `terraform plan` was produced on 2026-11-21 (54 resources); it is stale, was never applied and must not be reused. No live URL exists and none may be written into the repository until the instructor answers D2.

## 2. Seed guard policy (merged in PR #17, `eb82553`)
| `NODE_ENV` | `ALLOW_PRODUCTION_SEED` | Result |
|---|---|---|
| `development`, `test` | any value | allowed |
| `production` | exactly `true` | allowed (the one explicit override) |
| `production` | anything else | blocked |
| `staging`, any unknown name, empty, unset | any value | blocked |

Matching is exact: no trimming, no case folding. The old code let the flag unlock **any** environment (staging, unset, a typo like `prod`); it now only works in production
(`backend/src/seed.js`, a deliberate one-line behaviour change). Staging and unknown environments are blocked because seeding writes data, and the only place a deliberate
override is meaningful is production; an environment we cannot name is one we cannot reason about, so the safe default is refuse. Deployed containers already run `NODE_ENV=production`
(Dockerfile), so no deployment path changes.

## 3. Test coverage matrix (`docs/PHASE2_TEST_SPECS.md`)
Test files on `main` (static count of `it(`/`test(` calls, not a run result; `it.each` expansions are not counted): backend 65 (api 14, config 5, db.integration 11, logger 4, seed-script 4, seed 9, test-db-guard 6, validation 12); frontend 39 (api 4, app 10, cart 9, format 5, quantity-input 11). The earlier local run of "77 passed, 11 skipped" (backend) predates PR #18 and is historical. A fresh run total has not been re-captured in this reconciliation.

| Req | Status | Where / gap |
|---|---|---|
| U1-U6 test-db guard | Covered | `test-db-guard.test.js` (merged, PR #15) |
| U7-U9 id ranges | Covered | `validation.test.js` (merged, PR #16) |
| U10-U12 seed guard | Covered | `seed.test.js` (merged, PR #17) |
| U13 `DB_*` config | Extended by PR #18 | `config.test.js` (title of PR #18: "config and product-by-id API unit tests"); the exact `DB_*` cases were not re-read in this reconciliation |
| U14 `GET /api/products/:id` success | Added by PR #18 (title) | `api.test.js`; not re-read here |
| U15 out-of-range id never reaches the db | Partially covered | not re-verified |
| I1-I5 integration | Infrastructure exists in CI | `db.integration.test.js` runs in CI against PostgreSQL; not run locally (no Docker without approval); per-requirement mapping not re-verified |
| I6-I12 | Missing / Partially covered | not re-verified |
| S1-S2 child process | Covered | `seed-script.test.js` (merged, PR #17) |
| F1-F12 frontend | Files merged in PR #19 | `quantity-input.test.jsx`, `cart.test.js`, `format.test.js` exist on `main`; the per-requirement mapping to F1-F12 was not re-verified |

**T2.4 is not confirmed complete.** The tests were drafted with an AI assistant: for Part B4 the owner must review and adopt or rewrite them before citing them as their own.

## 4. Rubric audit and mark estimate
Labels: IV = implemented and verified; IE = implemented but evidence incomplete; NI = not implemented.

| Part | Marks | Item | Label | Estimate |
|---|---|---|---|---|
| A | 5 | README Part A (concepts, incidents, approach), on `main` via PR #10 | IV (owner read-through pending) | 4-5 |
| B | 15 | CI on push and PR, lint, tests, build, both tiers; many green runs | IV | |
| B | | tests written by the owner | IE (drafted with AI assistance; owner must adopt) | |
| B | | PR blocked by a failing required check (**B5**) | IE: demonstrated on PR #28 (merge state BLOCKED, read through the API); **no screenshot of the blocked state, and it cannot be recreated** | **11-13** |
| C | 10 | separate CI and CD files, jobs, `needs`, matrix, parallel, artifact upload, README diagram | IV for CI; IE for CD (file written, **never ran**; artifact hand-off in CD never executed) | 6-7 |
| D | 10 | no credentials in repo; separate env config files; README lists names | IV (guard, scans clean; final all-history scan still to do) | |
| D | | GitHub Environments, production approval gate, secrets in GitHub | IE (updated 2026-11-23): Environments `staging` and `production` configured (reviewer, main-only, administrator bypass off); **0 secrets, 0 variables**; the approval job (`production-approval`, deploys nothing) is in code, but no run has paused at "Waiting for review", so approval is **not verified** | **4-5** (unchanged: no approval evidence yet) |
| E | 15 | AWS EC2 three-tier, deploy after CI (assignment wording: "over SSH"; implemented design: SSM, pending instructor confirmation), private DB | NI: Terraform written and statically validated only; no EC2, no plan or apply, no deployment, no live URL | **0-3** |
| F | 15 | zero downtime with request evidence | IE, **local/offline only**: real-Docker rehearsals (238/238, 107/107, 161/161 in separate steps) and 125 offline checks; a post-switch fault cost 79 of 171 requests; nothing on AWS | **0-4** |
| G | 15 | health check, automatic rollback, manual rollback, logs | IE, **local/offline only**: scripts and local rehearsals; `rollback.yml` and CD never ran; no live automatic rollback | **3-6** |
| H | 10 | Copilot workflow and prompts | IE: documentation on `main` (PRs #20, #21); the Copilot origin and the prompts rest on the owner's statements; Copilot troubleshooting evidence UNAVAILABLE | |
| H | | three different deliberate failures | IV for the runs: 3 of 3 done, each with a kept failed run and a recovery run (YAML 44884178546 / 44884710861; deployment 44884809417 / 44885032635; test 44920064307 / 44920708004, PR #28 left open) | |
| H | | per failure: screenshot, root cause with Copilot troubleshooting, fix link | IE: root causes written (PR #29); fix commits `d2b645c` and `5472d40` (failure 2 has none); 13 screenshots on `main` (PR #32), two partial; **Copilot troubleshooting UNAVAILABLE** | **6-8** |
| I | 5 | README, structure, commits, PR workflow | IE (documentation implemented; only the 13 Part H screenshots exist, on `main`; live URL pending the instructor's decision) | 3-4 |
| | 100 | **Total (judgement, 2026-11-22)** | The 2026-11-21 estimate was about 34-51 (near 42). E, F and G are not awarded on the existence of code | **about 37-55, central estimate near 45** |

## 5. AWS deployment readiness (no AWS action was taken; reviewed 2026-11-22)
Target: ap-south-1, one staging stack (VPC, private RDS, ALB, one EC2 instance, ECR, S3, CodeBuild, GitHub OIDC, Systems Manager). The CODE for this was merged in PRs #22 to #27 and is covered by offline and static checks only; it has never run on AWS. Production is not implemented.

| Blocker | Needs your approval |
|---|---|
| Instructor decisions D1 (SSM instead of SSH) and D2 (live URL) | you send the question |
| Environments `staging` and `production` are configured (2026-11-23), but 0 variables and 0 secrets, `CD_ENABLED` unset. The approval job `production-approval` exists in `cd.yml` (PR #39, deploys nothing); there is still no production deploy job, and the approval is not verified | yes |
| The real GitHub OIDC `sub` claim not captured; whether an OIDC provider already exists in the account is unknown | read-only AWS check and a read-only GitHub query: yes |
| A fresh `terraform plan` (the 2026-11-21 plan is stale and not to be reused), then the apply | yes, each in its own turn |
| Cost envelope and budget (D5): the repository's own estimate is about $102 to $125 a month for staging, mostly NAT Gateway and ALB; the review adds about $2 to $3 for a third secret, CodeBuild and logs. These are estimates from list prices, not a quote | you decide |
| Operator steps: the `db-app` and `db-owner` secrets, the host settings file, the database bootstrap; the first deploy is expected to stop at the migrator by design | yes |
| Demo catalogue for staging is undecided | you decide |

Effort to a first verified staging release: roughly 8 to 16 working hours including debugging, a judgement that nothing has measured. Staging cannot be deployed safely today. If those hours or that budget do not exist, the honest submission is the documented state: Terraform and the AWS-mode code written and tested offline, local blue/green and rollback evidence, and clear limitations.

## 6. Submission checklist (evidence vs planned)
| Item | Actual evidence | Gap |
|---|---|---|
| README architecture and setup | on `main` (PR #10, later PRs #27 and #30) | owner read-through; GitHub Mermaid rendering unverified; clean-clone dry run not done |
| CI success | many green runs, CI succeeded on `main` at `18943e5` (run 44986851698) and on the heads of PRs #31 and #32 | screenshots for the CI triggers, matrix and job graph do not exist |
| Accidental CI failures | runs 44864872114 and 44916673865 | not Part H failures; keep, do not delete |
| Deliberate failure 1, YAML | failed 44884178546, recovered 44884710861, fix `d2b645c` | screenshots on `main` (PR #32) |
| Deliberate failure 2, deployment check | failed 44884809417, recovered 44885032635 | no fix commit (recovery was a new dispatch); the dispatch input is the owner's statement; failing step screenshot not expanded |
| Deliberate failure 3, failing test | failed 44920064307 (PR #28), recovered 44920708004, fix `5472d40` | PR #28 stays open and unmerged |
| Copilot evidence | `docs/copilot/` on `main`; failure write-ups (PR #29) | troubleshooting prompts and answers UNAVAILABLE; the owner confirms the record is their own |
| Required-check blocking (B5) | PR #28: both Backend checks failed, merge state BLOCKED (read through the API); protection read back | no screenshot of the blocked state, and it cannot be recreated |
| Test results | test files merged; CI runs (run 44920064307 reported 171 backend tests) | B4 ownership |
| Docker build | CI job "Backend Docker image" passes | none |
| Terraform validation | Terraform CI (format, init, validate, IAM rule checks, secret scan) | no apply; a stale local plan exists |
| GitHub Environments, secrets, variables | 2 Environments (`staging`, `production`; API read-back 2026-11-23), 0 secrets, 0 variables | no approval pause test yet; the approval job `production-approval` exists in code only (it deploys nothing), so manual approval is **not verified**. GitHub may also list a `production` Deployment entry for it although nothing is deployed (unverified) |
| Deployment evidence | **none** | not done |
| Rollback evidence | **local and offline only** | `rollback.yml` never ran |
| Screenshots | 13 Part H screenshots on `main` (PR #32), two partial | none for CI triggers, matrix, job graph or CD; no blocked merge; failure 2's failing step not expanded; branch protection page only the top |
| Live URL | none | not deployed; instructor decision pending |
| Known limitations | README, status and checklist | keep honest |

## 7. Shortest path to submission (no AWS)
1. Done on 2026-11-22: PR #31 (status reconciliation) and PR #32 (13 screenshots, README and Part H document changes) are merged. A follow-up documentation PR records this.
2. Capture the missing screenshots: the expanded "Check health endpoint" step of run 44884809417, the PR #28 Commits tab (red mark on `a3282f4`, green on `5472d40`), the lower half of the branch protection page, the Actions list filtered to failed runs, and the CI matrix and job graph.
3. Decide how to present the unavailable Copilot troubleshooting evidence; add the owner's own Copilot history only if it exists.
4. Adopt, rewrite or disclose the B4 tests.
5. Decide on GitHub Environments and the production approval gate (about 4 to 5 marks of Part D); this needs your approval.
6. Send the instructor draft (`docs/INSTRUCTOR_CLARIFICATION_DRAFT.md`); run the final all-history gitleaks scan; do the clean-clone dry run.
7. Only if hours and budget remain and you approve: the AWS route in section 5.
