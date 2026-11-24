# Part F evidence: request loop during a real staging deployment (blue -> green)

Captured 2026-11-24 (UTC). Everything here is real output of real runs. The only edits: line endings, and in the first line of each `deploy-log-host.txt` the public SSH key fingerprint is replaced by `<masked>` (it is a public value, but the repository's secret scanner flags it as a key; the original is in the run's log artifact).

## What was measured
| Item | Value |
|---|---|
| Deployment under test | CD run [45473412551](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45473412551), commit `11fc2c204c79bc52101bf149275be546f9eb7ce4`, staging, `live=blue (3c53ba7...)` replaced by `green` |
| Request loop | `staging-verify` run [45473006606](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45473006606), mode `traffic`, 780 s, `deploy/scripts/request-loop.sh` against `/health` of the staging nginx, through a Systems Manager port-forward |
| Window of the loop | 19:42:37.251Z to 19:55:37.500Z |
| Window of the deployment | job `deploy-staging` 19:45:24Z to 19:46:10Z; host script 19:45:40Z to 19:46:03Z |
| **Requests** | **1117** |
| **Failed** | **0** (0 timeouts, 0 non-200, longest failure streak 0) |
| Latency (ms) | min 232, avg 237, **p50 240, p95 242, p99 244**, max 254 (includes the tunnel: GitHub runner -> Systems Manager -> instance) |

## The release timeline on the host (`deploy-log-host.txt`)
| Time (UTC) | Event |
|---|---|
| 19:45:49 | `release 11fc2c2... (deploy): live=blue (3c53ba7...), target colour=green`; `backend-green` started |
| 19:45:49 | waiting for `backend-green` to report healthy and the expected commit |
| 19:45:52 | `backend-green validated; switching traffic` (nginx configuration tested, then reloaded gracefully) |
| 19:45:53 | draining `backend-blue` for 10 s before stopping it |
| 19:46:03 | `release 11fc2c2... is live on green`; `DEPLOY SUCCEEDED`; the client then printed `CONFIRMED` with both image digests |

Traffic moved only after the new colour reported healthy for the expected commit, and the old colour kept running for 10 s afterwards. The loop log shows every request that fell in this interval:
- inside 19:45:49 to 19:46:04: **21 requests, all 200**, average 0.242 s, maximum 0.249 s;
- around the switch (19:45:51 to 19:45:54): 5 requests, all 200.

## What this does and does not prove
- It is a **measured result for one real blue-to-green deployment**: no request failed, timed out or was slow, across 1117 requests that spanned the whole deployment.
- **Limit 1 (sampling):** through the tunnel a request takes about 0.24 s, so the loop sent about 1.4 requests per second (a gap of roughly 0.7 s). A failure shorter than that gap could have fallen between two requests. It is therefore strong evidence, not a proof for every sub-second interval.
- **Limit 2 (what was requested):** only `/health` (which also queries PostgreSQL). The frontend page and `/api/products` were checked separately by `staging-verify` (verify mode, run [45472728637](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45472728637): frontend 200, `/health` 200, `/api/products` 200 with a non-empty catalogue).
- **Limit 3 (one deploy):** a single deployment, with an unchanged database schema (`no pending migrations`).
- **Limit 4 (the running commit is not visible from outside):** `/version` is internal by design, so the loop's version log only shows the 404 page. The release timeline above comes from the host's own log, which is the authoritative record.
- **Screenshots: pending** (the owner captures them from the runs linked above).

## Files
- `request-loop.log`: one line per request (`UTC timestamp, status, seconds`), then the `SUMMARY` and `STATS` lines.
- `summary.json`: the same numbers, machine-readable.
- `deploy-log-host.txt`: the host's log of this deployment, as uploaded by the CD run.
- `../../staging-deploy-1/deploy-log-host.txt`: the first deployment (first deploy ever, so no previous release: it shows the migrations, the seed and the first switch, and is **not** a zero-downtime test).
