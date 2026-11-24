# Part G: a genuinely unhealthy backend, staging only. Mode A IMPLEMENTED and tested offline; NOT yet run on the instance

## The limitation this addresses
The automatic-rollback demonstration ([`docs/evidence/rollback/`](evidence/rollback/README.md)) uses a one-shot fault file that makes the **post-switch verification report a failure**; the new release's containers were actually healthy. It proves the real rollback logic, not that the pipeline reacts to a backend that is *really* broken.

## Status
- **Mode A (`FAULT=backend-unhealthy-pre-switch`) is implemented** in `bg_fault_pre` (`deploy/scripts/lib/bluegreen-lib.sh`) and covered by 31 offline checks (`lab-mode.test.sh` section 9, 132 checks in total). **Mode B is not implemented** (optional, see below).
- The freezing primitive was **checked on real Docker (Docker Desktop, local)**: `docker exec` into a paused container fails (exit 1, "Container ... is paused"), which is the first thing the readiness check does; `docker stop` and `docker rm -f` clean a paused container up; pausing one Compose service leaves the others running.
- **It has not been run on the instance.** It is run only after the final safety check below and the owner's arming.

## Determination
**Yes, it can be added safely, staging only, without changing production behaviour and without touching the application image.** The mechanism is to genuinely freeze the new colour's container on the host (Docker `pause`, the cgroup freezer): the process is alive but cannot answer, so every real health check fails or times out. No backend code changes and nothing in the images changes. It reuses the existing fault-file gate (`bg_fault_arm`), so every existing safety rule carries over.

## Two modes (the second is optional)
| Mode (the single line of `/opt/shopnest/staging/fault.env`) | What really happens | Effect on users | What it demonstrates |
|---|---|---|---|
| **`FAULT=backend-unhealthy-pre-switch`** (recommended) | right after the idle colour starts, before the readiness wait, `docker compose pause backend-<idle>`; the readiness check (`docker compose exec` into the paused container, then `/health` and `/version`) really fails; the existing pre-switch rejection runs (`bg_abort_idle`), traffic never moves | **none**: nginx never pointed at the broken release | a *really* broken release is rejected, the previous release keeps serving, exit 1, production never runs |
| `FAULT=backend-down-post-switch` (optional) | right after the switch, `docker compose pause backend-<idle>`; nginx now proxies to a frozen backend (`proxy_connect_timeout 2s`, `proxy_read_timeout 5s`), the live check fails, the existing automatic rollback returns traffic | **real**: users see 502/504 until the rollback completes (about 10 to 20 s; the earlier local rehearsal measured 79 of 171 requests) | the real post-switch rollback with a real fault. It is **not** a zero-downtime event, and the request loop will record the failures; they must be reported, not hidden |

The existing `FAULT=post-switch-unhealthy` (verification only, no user impact) stays as the demonstration that needs no outage.

## The safety rules (all inherited from `bg_fault_arm`, each needs its own test)
1. **Staging only:** only `BG_ENV=staging` in lab mode; production returns before the code reads anything.
2. **Deploy only:** a rollback never arms it; the first deploy (no previous release to fall back to) never does.
3. **Root-owned, restricted file:** a plain file, owned by root, not writable by group or others, containing exactly one of the two strings; anything else is ignored, logged and left in place. No credential or secret is ever in it.
4. **One-shot:** the file is deleted *before* the container is frozen; if it cannot be removed, nothing is armed.
5. **Fully logged:** the deploy log says `FAULT INJECTION (staging test): armed ... will freeze backend-<colour>`, then the real failure, then the real recovery.
6. **Self-cleaning:** the failed colour is stopped and removed by the existing `bg_abort_idle` (the pause is never left behind); nothing else on the host is touched.
7. **No change to the previous release:** only the idle colour of the deploy in progress is ever paused.

## The final safety check (to be run immediately before the demonstration; every line must be true)
1. `origin/main` contains the merged mode-A change, its CI was green, and the latest staging deploy of that commit succeeded (a normal deploy: the hook logs `no fault file ... not armed`).
2. `staging-verify` (verify mode) is green: staging is healthy on a known release, so there is a previous release to fall back to.
3. The file `/opt/shopnest/staging/fault.env` does not exist yet (the deploy log of the last staging deploy says so), and `stat` after arming shows `root:root 600` with exactly the line `FAULT=backend-unhealthy-pre-switch`.
4. A request loop (`staging-verify`, traffic mode) is already running for about 15 minutes, started before the deploy is triggered.
5. The trigger is a normal merge to `main` (or a CI re-run of the tip); nothing touches production, and the production job stays waiting.
6. Expected duration of the failing deploy: about 60 s of readiness retries (`READY_ATTEMPTS=30` x `READY_INTERVAL=2` in `deploy/env/staging.env`), then `DEPLOY FAILED (exit 1)`.

## What must be true before anything runs (the readiness gate)
- [x] The fake Docker in `deploy/tests/fake-docker.sh` learns `pause` (a paused container makes `exec` fail and nginx get no answer), and `lab-mode.test.sh` section 9 has the guard tests for mode A (production ignores the file, a rollback ignores it, the first deploy ignores it, a wrong owner or a two-line file is ignored, one-shot, only the idle colour is frozen, the previous release stays live, exit code 1 and never 3). Mode B has no tests because it is not implemented.
- [x] **Real-Docker check of the primitive on a laptop** (container and Compose level, see Status): a paused container fails `exec`, `stop` and `rm -f` clean it up, and a sibling service is unaffected. (The full `demo-bluegreen-local.sh` harness targets the local-database mode, not lab mode, and was not re-run.)
- [x] A test shows that no production path reaches the new code (production ignores the file, logs nothing about faults and freezes nothing).
- [ ] A reviewed pull request with green CI; no infrastructure, IAM or workflow change (open: merged only after CI).
- [ ] The owner arms the file on the instance and confirms it with `stat` (root:root 600), exactly as for the existing fault.
- [ ] A request loop is started before the deploy, and its numbers are reported honestly (zero failures for the pre-switch mode; real failures are expected and must be shown for the post-switch mode).

## Pass criteria and evidence
- Mode A: host log shows the freeze, `validation FAILED for backend-<colour>; traffic was NOT moved`, `DEPLOY FAILED (exit 1)`; the previous release still reported by the host; `staging-verify` healthy afterwards; the loop shows 0 failures; production job skipped.
- Mode B: host log shows `post-switch verification FAILED`, `previous release ... is live again (automatic rollback complete)`; the loop shows the real failure window with its length.

## Cost and recommendation
About 40 lines in `bluegreen-lib.sh`, a few lines in `fake-docker.sh`, about 25 offline checks, one PR, one staging deploy. **Recommendation:** implement mode A (it removes the "the backend was actually healthy" caveat for the *rejection* path at no risk to users) and keep the injected-verification mode for the post-switch rollback; implement mode B only if a real outage window on a non-public staging environment is acceptable.

Status: **mode A implemented; not run on the instance.** It will not be run until the final safety check above is complete and the owner has armed the file.
