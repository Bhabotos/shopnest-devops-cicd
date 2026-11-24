# Part F evidence (second data set): one request loop across TWO real staging deployments

Captured 2026-11-24 (UTC). Real output of real runs. The only edits: line endings, and in the first line of each host log the public SSH key fingerprint is replaced by `<masked>` (a public value that the repository's secret scanner flags as a key; the original is in the runs' log artifacts).

## What was measured
| Item | Value |
|---|---|
| Request loop | `staging-verify` run [45477290060](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45477290060), mode `traffic`, 840 s, `request-loop.sh` against `/health` of the staging nginx through a Systems Manager port-forward |
| Window of the loop | 20:06:56.115Z to 20:20:56.397Z |
| **Requests** | **1850** |
| **Failed** | **0** (0 timeouts, 0 non-200, longest failure streak 0) |
| Latency (ms) | min 238, avg 240, **p50 239, p95 243, p99 246**, max 290 (includes the tunnel) |

## The two deployments inside that window
| | Deployment 3 | Deployment 4 |
|---|---|---|
| CD run | [45477964033](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45477964033) | [45479105861](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45479105861) |
| Commit | `d25e808` (merge of PR #55) | `c5f6ef3` (merge of PR #56) |
| Switch | `live=green` -> `blue` | `live=blue` -> `green` |
| Host log (UTC) | target `blue` started 20:11:38; validated and switched 20:11:41; old colour drained 20:11:42; live 20:11:53 | target `green` started 20:17:48; validated and switched 20:17:52; old colour drained 20:17:53; live 20:18:03 |
| Requests during the deployment | **112, all 200**, maximum 0.255 s | **113, all 200**, maximum 0.243 s |

Both switches happened only after the new colour reported healthy for the expected commit, and the old colour kept running for 10 s afterwards. Together with the first data set (`../staging-deploy-2`: 1117 requests, one deployment, 0 failed) this is **three real blue-to-green switches observed, 2967 requests, 0 failed**.

## What this does and does not prove
- A **measured result**: no request failed, timed out or was slow across 1850 requests that spanned two complete deployments.
- **Sampling limit:** through the tunnel a request takes about 0.24 s, so the loop sends about 2.2 requests per second (a gap of roughly 0.45 s); a failure shorter than that could fall between two requests. Strong evidence, not a proof for every sub-second interval.
- Only `/health` (which also queries PostgreSQL) was requested. The frontend page and the API were checked by `staging-verify` verify mode ([45472728637](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45472728637)).
- Both deployments had no pending migrations. `/version` is internal by design, so the running commit is read from the host log (authoritative).
- **Screenshots: pending** (the owner captures them from the runs linked above).

## Files
`request-loop.log` (one line per request, then the `SUMMARY` and `STATS` lines), `summary.json`, `deploy-3-host-log.txt`, `deploy-4-host-log.txt`.
