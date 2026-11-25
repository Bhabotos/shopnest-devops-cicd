# Evidence index (verified)

Every run below (all 36 run links in the README, `PROJECT_STATUS.md` and the docs, re-verified on **2026-11-25 at about 03:41 +0600**; the runs added in the second reconciliation, later the same day, were read through the GitHub API when they were added; the pull-request links too) was looked up through the GitHub API: it exists, and its workflow, event, conclusion and commit are as listed. URL pattern: `https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/<id>`. Failed and cancelled runs are graded evidence and are **never deleted**. Evidence of Claude's own activity is never presented as GitHub Copilot evidence.

## Final staging state (at the time of writing)
| Item | Result |
|---|---|
| Commit live on staging | `dba02a851c20322af4554e4fb6aa0d10a6ca2a41` (merge of PR #62), deployed by CD run 45501575887: the host log (artifact `deploy-log-staging-dba02a85...`) shows `release dba02a8 is live on green`, `DEPLOY SUCCEEDED` and `CONFIRMED` with backend digest `sha256:e2df6e00...` and frontend digest `sha256:5dba1332...`; the previous release was `5a20d16` (blue). The commit is read from the deploy log and the GitHub deployment record, because `/version` is not public |
| Checked from outside | `staging-verify` run 45548376271 (2026-11-25 04:40Z, after the deploy): frontend `GET /` 200 and HTML; `/health` 200 with status ok; `/version` not public (404, internal by design); `GET /api/products` 200 with a non-empty catalogue (backend to PostgreSQL). Database connectivity is shown by `/health` (`SELECT 1`) and the catalogue answer; the database was not queried directly. The earlier check 45489787099 (commit `4a557d0`) is kept below |
| Production | **not deployed**: every CD run's `deploy-production` job is waiting, pending, cancelled (superseded) or skipped; it has never been approved. Runs still waiting on 2026-11-25: CD 45501575887 (pending), CD 45473412551 and 45469834249 (waiting), oidc-sts-test 45432917228 (waiting) |

Every merge to `main` deploys to staging while `CD_ENABLED=true`, so the commit above is the newest one at the time of writing (2026-11-25); the run list shows later ones.

## Verified runs (the main table; the failed runs are in the next table)
| Run | Workflow | Event | Result | Commit | Purpose |
|---|---|---|---|---|---|
| 44714705352 | CI | pull_request | success | `da55851` | PR run, Node 22 and 24 |
| 44720737504 | CI | push | success | `d72695b` | main |
| 44725363123 | CI | pull_request | success | `5252243` | PR |
| 44726873391 | CI | push | success | `56cb0e8` | main (Node 22 evidence) |
| 44726970656 | CD | workflow_run | skipped | `56cb0e8` | CD disabled by design at the time |
| 44785811248 | Terraform CI | pull_request | success | `c77d34e` | static Terraform checks |
| 44786392731 | Terraform CI | push | success | `2ed1f58` | static Terraform checks on main |
| 44786392818 | CI | push | success | `2ed1f58` | main |
| 44859967355 | CI | push | success | `75d1d93` | main |
| 44860058198 | CD | workflow_run | skipped | `75d1d93` | CD disabled by design at the time |
| 44884710861 | pipeline-demo | push | success | `d2b645c` | recovery from Part H failure 1 |
| 44885032635 | pipeline-demo | workflow_dispatch | success | `8feb5a0` | recovery from Part H failure 2 |
| 44920708004 | CI | pull_request | success | `5472d40` | recovery from Part H failure 3 |
| 45128964969 | approval-demo | workflow_dispatch | success | `3738e0b` | production approval gate demonstrated (deploys nothing) |
| 45424741285 | oidc-diagnostic | workflow_dispatch | success | `b76d306` | OIDC claims, staging |
| 45425321335 | oidc-diagnostic | workflow_dispatch | success | `b76d306` | OIDC claims, production |
| 45431405176 | oidc-sts-test | workflow_dispatch | success | `00e202a` | AWS STS role assumption, staging |
| 45432917228 | oidc-sts-test | workflow_dispatch | **waiting** | `00e202a` | STS role assumption, production: waiting for the reviewer |
| 45459661738 | ssh-preflight | workflow_dispatch | success | `7cbd668` | OIDC, tunnel, pinned host key, forced command; nothing started |
| 45469834249 | CD | workflow_run | waiting (production job) | `3c53ba7` | **first real staging deployment** (staging job succeeded) |
| 45473006606 | staging-verify | workflow_dispatch | success | `11fc2c2` | Part F loop 1: 1117 requests, 0 failed |
| 45473412551 | CD | workflow_run | waiting (production job) | `11fc2c2` | deploy 2 (staging job succeeded) |
| 45477290060 | staging-verify | workflow_dispatch | success | `d25e808` | Part F loop 2: 1850 requests, 0 failed |
| 45477964033 | CD | workflow_run | cancelled* | `d25e808` | deploy 3 (staging job succeeded) |
| 45479105861 | CD | workflow_run | cancelled* | `c5f6ef3` | deploy 4 (staging job succeeded; the first fault attempt found no file) |
| 45484404230 | staging-verify | workflow_dispatch | success | `c5f6ef3` | Part F/G loop 3: 2270 requests, 0 failed |
| 45485651117 | Rollback | workflow_dispatch | success | `6ac7802` | manual rollback to `3c53ba7` |
| 45486448054 | CD | workflow_run | cancelled* | `6ac7802` | restore deploy (staging job succeeded) |
| 45487248329 | staging-verify | workflow_dispatch | success | `6ac7802` | staging healthy after the restore |
| 45489277843 | CD | workflow_run | cancelled* | `4a557d0` | staging deploy (staging job succeeded) |
| 45489787099 | staging-verify | workflow_dispatch | success | `4a557d0` | endpoint verification of that commit |
| 45499313336 | staging-verify | workflow_dispatch | success | `5a20d16` | endpoint verification before the real-fault demonstration (22:16Z) |
| 45501575887 | CD | workflow_run | pending (production job) | `dba02a8` | **latest staging deploy** (staging job succeeded, `CONFIRMED`) |
| 45548376271 | staging-verify | workflow_dispatch | success | `dba02a8` | **final endpoint verification** (2026-11-25): frontend, `/health`, `/version` hidden, `/api/products` |

\* GitHub marks a CD run `cancelled` when a newer run's *pending* production job supersedes its own pending production job (the production jobs queue behind a waiting one); in both cases the `deploy-staging` job itself succeeded.

## Failed and cancelled runs (18, all kept) and what each one is
| Run | Result | Workflow / branch | Class | Qualifies as one of the three required Part H failures? |
|---|---|---|---|---|
| 44884178546 | failure | pipeline-demo, push, `demo/yaml-syntax-error` | **deliberate**, YAML syntax error; recovery 44884710861 (fix commit `d2b645c`) | **Yes, as a deliberate failure** (scenario 1). Its Copilot troubleshooting is unavailable and not reconstructed |
| 44884809417 | failure | pipeline-demo, dispatch, `demo/baseline` | **deliberate**, deployment health check; recovery 44885032635 (a corrected dispatch, no fix commit) | **Yes, as a deliberate failure** (scenario 3). Same Copilot caveat |
| 44920064307 | failure | CI, PR #28, `test/failing-config-default-port` | **deliberate**, failing test; recovery 44920708004 (fix commit `5472d40`) | **Yes, as a deliberate failure** (scenario 2). Same Copilot caveat |
| 45500242957 | failure | CD, main, commit `f4df02f` | **deliberate**, the real-fault demonstration (Part G, staging): the new backend colour was frozen, validation failed, traffic never moved, exit 1, previous release (`5a20d16`) kept serving, production skipped; recovered by the next CD run 45501575887 | A deliberate deployment failure with a full host log; Copilot evidence for it can only come from the owner's own session |
| 45485258931 | failure | CD, main | **deliberate**, a fault-injected staging deploy (Part G); the previous release kept serving, production skipped | A *deliberate deployment failure* with a full host log: usable as the material for Copilot troubleshooting scenario 3, but only the owner's own Copilot session can supply the Copilot evidence |
| 44864872114 | failure | CI, PR #11 | **accidental**: a false positive in a CI check, fixed in the same PR | **No** |
| 44916673865 | failure | CI, PR #26 | **accidental**: an offline test assertion failed (`the guard is executable in the bundle`), fixed by commit `3fe0ca0` | **No** |
| 45444399255 | failure | CI, PR #48 | **accidental**: the `ShellCheck` step failed on two warnings (SC2097/SC2098) in a test added in commit `91ad57c`; fixed by commit `a958e54`, whose CI run passed | **No.** It is a real failure with a root cause, a fix commit and a green recovery, but it was an unplanned mistake in Claude-written code and no GitHub Copilot was involved. It must not be counted as a deliberate scenario or as Copilot evidence |
| 45472728637 | failure | staging-verify | **accidental**: the workflow wrongly expected `/version` to be public (it is internal by design); fixed in PR #55 | **No** |
| 45478319860 | cancelled | staging-verify | a redundant queued traffic loop that I cancelled | no |
| 45471417111 | cancelled | ssh-preflight | a probe that proved a waiting production job holds a shared concurrency group; I cancelled it | no |
| 45455233746 | cancelled | Terraform CI, PR | superseded by a newer push to the PR | no |
| 45479105861, 45477964033, 45486448054, 45489277843, 45492040334, 45495732856 | cancelled | CD | see the note above: the staging job of each succeeded (read through the API on 2026-11-25); only the production job was superseded | no |

**Summary for Part H.** Three deliberate failures exist as real runs with recoveries (YAML, deployment health check, test); what is missing is GitHub Copilot's role in troubleshooting them, which only the owner can supply. [`COPILOT_EXERCISE.md`](COPILOT_EXERCISE.md) prepares one workflow-generation prompt and three fresh, safe failure scenarios with the owner's Copilot troubleshooting prompts and an evidence checklist.

## Pull requests of the deployment work (all merged)
#46 and #47 (OIDC diagnostics), #48 (SSH deploy client, host wrappers), #49 (lab-mode blue/green), #50 (CD and rollback workflows), #51 (lab Terraform, documentation), #52 (pre-flight, request-loop tool), #53, #54 (per-environment concurrency, `staging-verify`), #55, #56 (staging fault injection), #57 (Part F evidence and fault diagnostics), #58 (Part G evidence). PR #28 is a deliberate failing-test demonstration, open and unmerged by design.

## Evidence folders
`docs/evidence/staging-deploy-1/` (first deployment), `docs/evidence/zero-downtime/` (three request-loop data sets with host timelines), `docs/evidence/rollback/` (automatic rollback, manual rollback, restore), `docs/evidence/phase2/` and `docs/evidence/bluegreen-local/` (local), `docs/screenshots/` (CI, Part B, D and H; staging CD, request loop and rollback; four AWS console pages with the account label and resource IDs blacked out).
