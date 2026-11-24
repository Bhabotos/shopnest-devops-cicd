# PROJECT STATUS — ShopNest DevOps CI/CD

Last updated: 2026-11-25. Source: git, the GitHub API and real workflow runs. The long, dated record of earlier phases, decisions and manual actions is kept in [`docs/PROJECT_HISTORY.md`](docs/PROJECT_HISTORY.md) (it is history: where it disagrees with this file, this file wins).
Labels: **VERIFIED** = a real run or a read-back produced the result; **IMPLEMENTED, NOT EXECUTED** = merged code covered by offline or static checks only; **PENDING**; **BLOCKED**.

## Where the deployment stands
**Staging is deployed** (the first real deployment, 2026-11-24). `CD_ENABLED` is `true` (owner-authorized for staging); every push to `main` now deploys to staging. **Production has NOT been deployed**: its job waits for the production reviewer and has not been approved.

| Step | State |
|---|---|
| CI (lint, tests, Node 22 and 24, Docker image, deploy-script suites) | **VERIFIED**, required checks green on every merged PR |
| SSH-over-SSM-tunnel deploy client, host wrappers, forced command, tests (PR #48) | IMPLEMENTED, NOT EXECUTED (offline suites run in CI) |
| Lab-mode blue/green deploy and rollback scripts, lab-mode tests (PR #49) | IMPLEMENTED, NOT EXECUTED |
| `cd.yml`, `rollback.yml` for the SSH tunnel; plugin installed before the AWS credentials; account id masked; error-text redaction (PR #50) | IMPLEMENTED, NOT EXECUTED |
| `infra/lab` Terraform, lab docs, `/var/lib/shopnest` root-owned `0755` in the setup script and bootstrap (PR 4) | IMPLEMENTED, NOT EXECUTED |
| First real staging deployment (`cd.yml`: gate -> publish-images -> deploy-staging) | **VERIFIED**: CD run [45469834249](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45469834249) for commit `3c53ba7`. The host's own log (artifact `deploy-log-staging-...`) shows the database passwords generated, migrations 001 to 003 applied, the demo catalogue seeded, `backend-blue` validated for health and commit, nginx started, `DEPLOY SUCCEEDED` and `CONFIRMED` with both image digests. Both GHCR packages are public (anonymous pull verified by the run); the published images were pulled by digest and inspected: no secret, non-root, gitleaks clean. First deploy: there was no previous release, so zero downtime is NOT shown by it |
| Second staging deployment (a real blue -> green switch) and the Part F request loop | **VERIFIED, measured**: CD run [45473412551](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45473412551) (commit `11fc2c2`); `staging-verify` traffic run [45473006606](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45473006606): **1117 requests over 780 s, 0 failed, 0 timeouts, 0 non-200**, p50 240 ms, p95 242 ms, p99 244 ms (through the SSM tunnel), spanning the whole deployment; 21 requests inside the 14-second host deploy, all 200. Limits (about 1.4 requests per second, `/health` only, one deploy): [`docs/evidence/zero-downtime/staging-deploy-2/README.md`](docs/evidence/zero-downtime/staging-deploy-2/README.md) |
| `staging-verify` (endpoint checks through an SSM port-forward to the staging nginx) | **VERIFIED**: run [45472728637](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45472728637): frontend 200, `/health` 200, `/api/products` 200 with a non-empty catalogue (backend -> PostgreSQL); `/version` is internal by design (the first version of the workflow wrongly expected it; fixed in PR #55) |
| Production deploy job | **WAITING for the production reviewer** (never approved by Claude) |
| GitHub OIDC claims for both Environments | **VERIFIED**: `oidc-diagnostic` runs [45424741285](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45424741285) (staging) and [45425321335](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45425321335) (production) |
| AWS STS role assumption, staging | **VERIFIED**: `oidc-sts-test` run [45431405176](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45431405176) |
| AWS STS role assumption, production | **PENDING**: run [45432917228](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45432917228) is waiting for the production reviewer |
| Environment configuration | **VERIFIED by name through the API (2026-11-24)**: both Environments have `AWS_ROLE_ARN`, `AWS_REGION`, `LAB_INSTANCE_ID`, `SSH_HOST_KEY` and the secret `DEPLOY_SSH_KEY`; both restrict deployments to `main`; production requires reviewer `Bhabotos` with administrator bypass off; staging has no reviewer and administrator bypass **on** |
| The EC2 instance, its security group (TCP 80 only), SSM registration, the two deploy roles | **VERIFIED read-only (2026-11-24)** |
| `ssh-preflight` workflow (OIDC -> SSM tunnel -> SSH with the pinned host key -> forced command -> wrapper `--check`; deploys nothing) | **VERIFIED for staging**: run [45459661738](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45459661738) succeeded (2026-11-24). Production not run. The `simulate: wrong-host-key` failure is left for the owner's Part H exercise |
| `request-loop.sh` (Part F evidence tool: requests, failures, timeouts, latency percentiles, version-change log, JSON) | IMPLEMENTED, tested against a throwaway server (`request-loop.test.sh`), NOT used on a real deploy yet |
| Host prerequisites on the instance | **PARTLY VERIFIED** by the pre-flight (deploy user, restricted keys, wrappers, sudoers, config, host key). **NOT VERIFIED**: `/var/lib/shopnest` mode, Docker, capacity (`readiness-check.sh`); the first deploy fails closed (exit 4) if the lock directory is unsafe |

## Assignment parts (judgement, not a grade)
| Part | State | Missing |
|---|---|---|
| A, I | documentation merged | screenshots, clean-clone dry run, live URL decision (D2) |
| B, C | CI and workflow architecture **VERIFIED** | CD never ran; some screenshots |
| D | no credential in the repository; production approval **VERIFIED** with the separate `approval-demo` run | final all-history scan |
| E | staging **deployed** (run 45469834249); production waiting for the reviewer | endpoint checks through `staging-verify`, a second deploy, production approval by the reviewer, screenshots |
| F | **measured on staging** (1117 requests, 0 failed, one real blue -> green deploy) | screenshots; a denser (parallel) loop would strengthen it; no claim beyond the stated limits |
| G | fault-injection mechanism implemented and tested offline (PR #56); nothing run on the instance yet | arm the staging fault (owner, on the instance), the automatic-rollback deploy, the manual rollback, screenshots |
| H | three deliberate failures with kept failed and recovery runs | the owner's own GitHub Copilot prompts and evidence: **UNAVAILABLE so far**, never reconstructed |

## Failed workflow runs (evidence; none may be deleted)
Deliberate (Part H): 44884178546, 44884809417, 44920064307. Accidental: 44864872114, 44916673865, and 45444399255 (a ShellCheck failure on PR #48, fixed in the next commit).

## Blockers and the next actions
1. Owner: re-authenticate AWS (`aws login --profile devops`; the session expired) so the host read-back can run, and approve or cancel production STS run 45432917228.
2. Done: `CD_ENABLED=true` and the first staging deploy. Next: `staging-verify` (endpoints), then the Part F request loop during a second staging deploy, then Part G on staging. The production job stays waiting for the reviewer.
3. On the instance `sudo bash deploy/host/readiness-check.sh` (read-only); the staging `ssh-preflight` already passed. The full list is [`docs/PRE_DEPLOYMENT_CHECKLIST.md`](docs/PRE_DEPLOYMENT_CHECKLIST.md).
4. After the first deploy: zero-downtime request loop, then a deliberately unhealthy **staging** release (automatic rollback) and a manual rollback.
5. Owner: the GitHub Copilot exercise for Part H, step by step in [`docs/COPILOT_EXERCISE.md`](docs/COPILOT_EXERCISE.md) (one prompt, three safe failures, exact evidence).

## Open decisions
Staging administrator bypass (currently on); the live URL in the README (D2); screenshots to commit.
