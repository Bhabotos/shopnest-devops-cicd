# Pre-deployment checklist: first real staging deployment

Nothing here deploys anything. Each row says how it is checked, who does it, and its state. `VERIFIED` means a real run or a read-back produced the result (date and evidence given); `NOT VERIFIED` means exactly that. Updated 2026-11-25.

## 1. What deploys, and what triggers it
`CD_ENABLED` is unset, so `cd.yml` only ever reports `skipped`. Setting `CD_ENABLED=true` does **not** start a deployment by itself. The only trigger is the `CD` workflow's `workflow_run` event: **a CI run on `main` that was started by a push and finished successfully**. After `CD_ENABLED=true` is set, a deploy therefore starts on the next push to `main`, or when the latest successful push-triggered CI run on `main` is re-run (`gh run rerun <id>`), because the re-run completes again and fires `workflow_run`. The `gate` job then requires: CI `success`, event `push`, branch `main`, same repository, and that the commit is still the tip of `main`. Staging deploys first; the production job waits for the reviewer and never runs if staging failed.

## 2. Checks

| # | Check | How | State |
|---|---|---|---|
| 1 | Deployment code on `main`, no obsolete ECR/CodeBuild/SSM references in active workflows | PRs #48 to #51 merged; grep of `cd.yml` / `rollback.yml` | **VERIFIED** 2026-11-24 |
| 2 | Environment variables and secret exist in both Environments | `gh api` (names only; values never read) | **VERIFIED** 2026-11-24: `AWS_ROLE_ARN`, `AWS_REGION`, `LAB_INSTANCE_ID`, `SSH_HOST_KEY`, secret `DEPLOY_SSH_KEY` |
| 3 | The two private keys are ED25519, different, and match the public keys given to the host | local `ssh-keygen -y` fingerprints compared with the verified fingerprints | **VERIFIED** 2026-11-24 |
| 4 | `SSH_HOST_KEY` is the instance's real host key | local fingerprint of the stored value compared with the host's fingerprint | value **VERIFIED** against the recorded fingerprint; the host's current key is checked by row 8 |
| 5 | Branch restriction `main` only on both Environments; production reviewer, no administrator bypass | `gh api` | **VERIFIED** 2026-11-24. Staging has no reviewer and administrator bypass is **on** (decision open) |
| 6 | OIDC claims and role assumption, staging | `oidc-diagnostic` and `oidc-sts-test` runs | **VERIFIED**: [45431405176](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45431405176) |
| 7 | OIDC role assumption, production | `oidc-sts-test` run [45432917228](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45432917228) | **PENDING** the reviewer's approval |
| 8 | **The whole path: OIDC -> SSM tunnel -> SSH with the pinned host key -> forced command -> wrapper `--check`, with nothing started** | run workflow **`ssh-preflight`** (staging, simulate `none`) | **NOT VERIFIED yet** (the workflow is new). Success proves the host prerequisites for SSH (user, keys, wrappers, sudoers, `/etc/shopnest/release.conf`) and the instance's host key |
| 9 | Strict host-key checking really refuses a wrong key | `ssh-preflight` with simulate `wrong-host-key` must FAIL with exit 4 | **NOT VERIFIED yet** (this is also Part H failure scenario 3) |
| 10 | Host read-back: ownership and modes (`/var/lib/shopnest` root `0755`, wrappers, `authorized_keys`), `sshd` settings, Docker, listeners | `deploy/host/readiness-check.sh` (read-only) in a Session Manager session, or `setup-deploy-host.sh --verify` | **NOT VERIFIED**: needs a fresh AWS login (`aws login --profile devops`) or the owner's session |
| 11 | The instance has the capacity: Docker running, free disk and memory | row 10 output | **NOT VERIFIED** |
| 12 | The two GHCR packages are **public** | the first `publish-images` job checks an anonymous pull and **fails clearly if they are private** | **EXPECTED first-run stop.** GitHub creates the packages private on the first push: the owner makes `shopnest-backend` and `shopnest-frontend` public in the package settings, then re-runs the failed job |
| 13 | Database is private | `docker compose config` in CI (no published db port, `internal: true` network); security group admits TCP 80 only | **VERIFIED** statically and read-only on AWS (2026-11-24) |
| 14 | Staging and production cannot overwrite each other | separate Compose projects, ports, networks, subnets, secrets directories and database volumes (code read, `lab-mode.test.sh`) | **VERIFIED** statically; not exercised on the instance |
| 15 | Production approval pauses a real run | `approval-demo` run 45128964969 | **VERIFIED** with the separate demo; the real `deploy-production` job has never run |

## 3. Order of the first real run (needs the owner's approval to start)
1. Run `ssh-preflight` for staging (row 8) and read-back the host (row 10). Fix anything that fails; nothing has deployed yet.
2. Approve: set the repository variable `CD_ENABLED=true`.
3. Re-run the latest successful CI run on `main` (or merge a small PR). Expect `publish-images` to stop at the anonymous-pull check (row 12); make the packages public and re-run that job.
4. `deploy-staging` runs. Verify on the instance, not only in the log: frontend, backend, PostgreSQL containers running, `/health` OK, `/version` equals the commit, the digests in the run summary equal the running images.
5. Run the zero-downtime request loop during a **second** staging deploy (Part F), then the broken-release and manual-rollback demonstrations (Part G) on staging only.
6. Only then let `deploy-production` wait for the reviewer. Never break a release in production.
