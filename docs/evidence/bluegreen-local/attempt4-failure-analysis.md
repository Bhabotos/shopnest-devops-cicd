# Attempt 4: why 83 of 181 requests failed, and the fix

Source: `attempt4-post-switch-rollback/05-request-loop-post-switch-D.log` (the request loop on `/`) and
`05-deploy-D-post-switch-failure.log` (the deploy log). Both are committed and unchanged apart from the
path sanitization in `SANITIZED.md`. Times are UTC, 2026-11-20.

## What the evidence shows

| Fact | Value |
|---|---|
| Requests / failed | 181 / 83 |
| Failure status | all 83 were HTTP **500** (none 502, 503 or 504; no connection error; no timeout) |
| Time spent per failed request | 13.6 ms to 100 ms, so nginx itself answered at once; nothing waited on an upstream |
| Pattern | one contiguous block: 98 OK, then 83 failed, then OK again (exactly two transitions) |
| First failure | 14:02:28.252 |
| Last failure | 14:02:48.925 (the next request, 14:02:49.199, was OK) |
| Length of the failing window | 20.7 s |
| Deploy log | pre-switch validation passed 14:02:26; nginx reload notice 14:02:27; `post-switch verification FAILED` 14:02:47; return reload notice 14:02:48; `automatic rollback complete` 14:02:49 |

The window starts right after the first reload (traffic moved to the new release) and ends right after the
second reload (traffic returned to the old one). Nothing failed before the first reload or after the second.

## Where the failures came from

| Suspect | Verdict | Why |
|---|---|---|
| nginx switching (the reloads) | **not the cause** | no 502/503/504 or connection error at either reload; the request right after the return reload was OK. The failures are one steady block between the reloads, not spikes at them |
| Upstream connection handling | **not the cause** | the new backend was healthy and the answers took milliseconds; a connection problem would show as 502/504 with timeouts |
| Backend draining | **not involved** | draining runs only after a successful release; here the old backend was never stopped |
| Live health validation | **detected the fault, but only after 20 s** | the check did fail (`curl -f /`), then retried for its whole budget before giving up |
| The release itself | **the cause** | release D's frontend files had no `index.html` (that was the deliberate fault) |

**Root cause.** The checks before the switch covered the backend only (`/health` and `/version` of the new
colour). The frontend files go live in the *same* atomic switch, but nothing checked them first. A release without
`index.html` therefore passed every pre-switch check, real users were the first to find out, and they kept
getting errors until the post-switch check used up its retries.

How the 500 arises is **inferred from the nginx configuration, not observed**: `try_files $uri /index.html` sends the
request internally to `/index.html`, which does not exist, which matches `location /` again, and nginx stops that
loop with a 500. The nginx error log was not saved in attempt 4. Attempt 5 saved it and **confirmed this**: `06-nginx-errors-excerpt.txt` shows `rewrite or internal redirection cycle while internally redirecting to "/index.html"` for `GET /`.

**Why 20 s.** `bg_live_check` is retried `LIVE_ATTEMPTS` (10) times. Each attempt runs two `docker compose exec`
probes, two `curl` calls and a 1 s sleep, about 2 s on Docker Desktop. The retries are there to ride out the moment
a reload settles; for a failure that never clears they only lengthen the window.

## Minimal fix (root cause only; `LIVE_ATTEMPTS` is unchanged)

Check what can be checked **before** any traffic can reach it:
1. `bluegreen-deploy.sh` refuses a bundle whose `frontend-dist` has no non-empty `index.html`, before it loads the image,
   runs migrations or starts a container.
2. `bg_release` re-checks the installed frontend release before the switch (this also covers a manual rollback
   and a half-installed release).
3. `rollback.sh` refuses a target whose frontend files have lost their `index.html`, before anything starts.

For this failure class the result is zero failed requests: nothing is ever switched.

## What this does not fix

A failure that only appears after traffic moves still costs a window (up to `LIVE_ATTEMPTS` times the cost of one attempt,
about 20 s here), then the automatic rollback runs. It can be shortened (fewer attempts, cheaper probes, or a
candidate-port check before the switch) but not removed. That is a design decision for the author, not a defect fix,
so it is not done here.

## Result after the fix: attempt 5 (`attempt5-all-scenarios/`, real Docker, 24 of 24 checks)

| Case | Requests | Failed | Notes |
|---|---|---|---|
| Release D, frontend has no `index.html` (the attempt 4 defect) | 105 on `/`, 108 on `/api/products` | **0 and 0** | refused by `bluegreen-deploy.sh` before the image was loaded, before migrations, before any container started; exit 1; A stayed live |
| Release E, good, `index.html` deleted by the harness right after the switch (a fault that cannot be seen before the switch) | 171 on `/` | **79** | 92 OK, one block of 79 HTTP 500 from 14:26:04.074 to 14:26:24.516 (20.4 s), then OK from 14:26:24.753; the live check failed and the automatic rollback restored A (`automatic rollback complete` 14:26:25); exit 1 |
| Releases B and C, manual rollback to A (steps 2-4 repeated) | 269 / 176 / 180 on `/api/products` | 0 / 0 / 0 | database container unchanged throughout |

- **Zero failed requests is reached for the defect that was investigated**: a frontend that would otherwise be switched in broken.
- **It is not reached for faults that appear only after the switch.** The 79 failures in step 6 are the same mechanism as
  attempt 4: users get errors until the live check gives up (20.4 s here, 20.7 s in attempt 4). The database container was
  untouched in every step (checked by container id and start time), and Docker before and after were identical
  (`docker-before-after.txt`).
- Recovery time for step 6: 20.4 s from the first failed request to the last, then clean. Shortening it is a separate
  decision (see "What this does not fix" above).
