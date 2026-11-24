# PROJECT STATUS — ShopNest DevOps CI/CD

Last updated: 2026-11-25. Source: git, the GitHub API and real workflow runs. The long, dated record of earlier phases, decisions and manual actions is kept in [`docs/PROJECT_HISTORY.md`](docs/PROJECT_HISTORY.md) (it is history: where it disagrees with this file, this file wins).
Labels: **VERIFIED** = a real run or a read-back produced the result; **IMPLEMENTED, NOT EXECUTED** = merged code covered by offline or static checks only; **PENDING**; **BLOCKED**.

## Where the deployment stands
Nothing is deployed. `CD_ENABLED` is unset, so every CD run is `skipped`, and `cd.yml` / `rollback.yml` have never run their deploy jobs.

| Step | State |
|---|---|
| CI (lint, tests, Node 22 and 24, Docker image, deploy-script suites) | **VERIFIED**, required checks green on every merged PR |
| SSH-over-SSM-tunnel deploy client, host wrappers, forced command, tests (PR #48) | IMPLEMENTED, NOT EXECUTED (offline suites run in CI) |
| Lab-mode blue/green deploy and rollback scripts, lab-mode tests (PR #49) | IMPLEMENTED, NOT EXECUTED |
| `cd.yml`, `rollback.yml` for the SSH tunnel; plugin installed before the AWS credentials; account id masked; error-text redaction (PR #50) | IMPLEMENTED, NOT EXECUTED |
| `infra/lab` Terraform, lab docs, `/var/lib/shopnest` root-owned `0755` in the setup script and bootstrap (PR 4) | IMPLEMENTED, NOT EXECUTED |
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
| E | code merged; the SSH path to the instance is **VERIFIED by `ssh-preflight` (staging)**; **no deployment** | first staging deploy (needs approval), live evidence |
| F | local and offline evidence only | request loop during a real deploy |
| G | local and offline evidence only | automatic and manual rollback on the instance |
| H | three deliberate failures with kept failed and recovery runs | the owner's own GitHub Copilot prompts and evidence: **UNAVAILABLE so far**, never reconstructed |

## Failed workflow runs (evidence; none may be deleted)
Deliberate (Part H): 44884178546, 44884809417, 44920064307. Accidental: 44864872114, 44916673865, and 45444399255 (a ShellCheck failure on PR #48, fixed in the next commit).

## Blockers and the next actions
1. Owner: re-authenticate AWS (`aws login --profile devops`; the session expired) so the host read-back can run, and approve or cancel production STS run 45432917228.
2. Owner approval: enable `CD_ENABLED` and run the first real **staging** deploy (production only after staging passes and with the reviewer).
3. On the instance `sudo bash deploy/host/readiness-check.sh` (read-only); the staging `ssh-preflight` already passed. The full list is [`docs/PRE_DEPLOYMENT_CHECKLIST.md`](docs/PRE_DEPLOYMENT_CHECKLIST.md).
4. After the first deploy: zero-downtime request loop, then a deliberately unhealthy **staging** release (automatic rollback) and a manual rollback.
5. Owner: the GitHub Copilot exercise for Part H, step by step in [`docs/COPILOT_EXERCISE.md`](docs/COPILOT_EXERCISE.md) (one prompt, three safe failures, exact evidence).

## Open decisions
Staging administrator bypass (currently on); the live URL in the README (D2); screenshots to commit.
