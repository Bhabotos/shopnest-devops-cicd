# Part G: a genuinely unhealthy backend, staging only. DESIGN: not implemented, not run

## The limitation this addresses
The automatic-rollback demonstration ([`docs/evidence/rollback/`](evidence/rollback/README.md)) uses a one-shot fault file that makes the **post-switch verification report a failure**; the new release's containers were actually healthy. It proves the real rollback logic, not that the pipeline reacts to a backend that is *really* broken.

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

## What must be true before anything runs (the readiness gate)
- [ ] The fake Docker in `deploy/tests/fake-docker.sh` learns `pause` (a paused container makes `exec` fail), and `lab-mode.test.sh` gets the same guard tests as section 8 for both modes (production ignores the file, a rollback ignores it, first deploy ignores it, an invalid or writable file is ignored, one-shot, the previous release stays live, exit code 1 and never 3).
- [ ] **A real-Docker rehearsal on a laptop** (the existing `demo-bluegreen-local.sh` harness) proves that a paused container fails the readiness check as expected, that `docker compose stop` and `rm -f` clean up a paused container, and that the previous release is unaffected. This must pass before the instance is involved.
- [ ] A grep and a test show that no production path reaches the new code.
- [ ] A reviewed pull request with green CI; no infrastructure, IAM or workflow change.
- [ ] The owner arms the file on the instance and confirms it with `stat` (root:root 600), exactly as for the existing fault.
- [ ] A request loop is started before the deploy, and its numbers are reported honestly (zero failures for the pre-switch mode; real failures are expected and must be shown for the post-switch mode).

## Pass criteria and evidence
- Mode A: host log shows the freeze, `validation FAILED for backend-<colour>; traffic was NOT moved`, `DEPLOY FAILED (exit 1)`; the previous release still reported by the host; `staging-verify` healthy afterwards; the loop shows 0 failures; production job skipped.
- Mode B: host log shows `post-switch verification FAILED`, `previous release ... is live again (automatic rollback complete)`; the loop shows the real failure window with its length.

## Cost and recommendation
About 40 lines in `bluegreen-lib.sh`, a few lines in `fake-docker.sh`, about 25 offline checks, one PR, one staging deploy. **Recommendation:** implement mode A (it removes the "the backend was actually healthy" caveat for the *rejection* path at no risk to users) and keep the injected-verification mode for the post-switch rollback; implement mode B only if a real outage window on a non-public staging environment is acceptable.

Status: **designed only.** Nothing here has been implemented or run; it will not be run until the checklist above is complete and the owner approves.
