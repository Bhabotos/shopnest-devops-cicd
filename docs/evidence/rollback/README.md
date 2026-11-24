# Part G evidence: automatic rollback, manual rollback and restore on staging

Captured 2026-11-24 (UTC), staging only. Real output of real runs. The only edits: line endings, and in the first line of each host log the public SSH key fingerprint is replaced by `<masked>` (a public value that the repository's secret scanner flags as a key; the original is in the runs' log artifacts). **Production was never touched: its job was skipped in the failed run (`needs: deploy-staging`) and no production approval was given.**

## Sequence
| # | What | Run | Result |
|---|---|---|---|
| 1 | **Automatic rollback**: a staging deploy of commit `6ac7802` with the one-shot fault file armed on the host | CD run [45485258931](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45485258931) | job `deploy-staging` **failed (exit 1) on purpose**; the previous release `c5f6ef3` kept serving; `deploy-production` skipped. This failed run is kept as evidence |
| 2 | **Manual rollback** to the first deployed commit `3c53ba7` | Rollback run [45485651117](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45485651117) | success: `ROLLBACK SUCCEEDED`, `CONFIRMED: staging is serving 3c53ba7` |
| 3 | **Restore** staging to the newest release by re-running CI on `main` | CD run [45486448054](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45486448054) | success: `DEPLOY SUCCEEDED: 6ac7802 is live on staging` |
| 4 | Staging checked from outside after the restore | `staging-verify` run [45487248329](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45487248329) | frontend 200, `/health` 200, `/version` not public (404), `/api/products` 200 with a catalogue |
| - | Continuous requests across 1 to 3 | `staging-verify` traffic run [45484404230](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45484404230) | see below |

## 1. Automatic rollback (`1-automatic-rollback-fault-deploy-host-log.txt`)
| Time (UTC) | Host log line |
|---|---|
| 20:53:31 | `release 6ac7802... (deploy): live=green (c5f6ef3...), target colour=blue` |
| 20:53:34 | `backend-blue validated; switching traffic` (nginx tested and reloaded: traffic now on the new release) |
| 20:53:35 | `FAULT INJECTION (staging test): armed for release 6ac7802...; the fault file is consumed and removed; its post-switch verification will be reported as FAILED` |
| 20:53:45 | `post-switch verification FAILED; returning traffic to the previous release` and `this failure was INJECTED by the staging fault file (a test); the automatic rollback below is the real one` |
| 20:53:46 | nginx switched back; `previous release c5f6ef3... is live again (automatic rollback complete)` |
| 20:53:46 | `DEPLOY FAILED (exit 1): the previous release is serving` |

What proves what:
- The **rollback logic ran for real**: traffic was switched back to the previous colour, and that line is printed only after the live check of the previous release passed (nginx `/health` ok, the internal `/version` equal to `c5f6ef3`, and the published-port `/health` and `/`).
- The fault file was **consumed** (the log says it is removed; later runs log `no fault file ... not armed`): one-shot.
- `no pending migrations` in every deploy and a rollback never runs migrations, so the schema was not touched.
- **What is simulated:** the failure is injected into the post-switch *verification* (a staging-only, root-owned fault file armed by the owner, see `docs/LAB_DEPLOYMENT.md`); the new release's containers were actually healthy. For about 10 s (20:53:35 to 20:53:45) nginx served that healthy release before the (injected) failure sent traffic back, so real users never met a broken backend. This demonstrates the rollback mechanism, not a real production fault.
- A first attempt earlier the same evening (CD run 45479105861) found no fault file on the host and deployed normally; the host log had no fault line. The staging deploy now logs what it looked for (PR #57), and the second attempt worked.

## 2. Manual rollback (`2-manual-rollback-to-3c53ba7-host-log.txt`)
- Request: staging, target `3c53ba7143839ef8d1aa6a2d0bea2af87c62a61b` (the first deployed commit, an ancestor of `main`), carrier `6ac7802` (the tip of `main`).
- 20:55:10 `live=green (c5f6ef3), target colour=blue`; 20:55:13 `backend-blue validated` (healthy and reporting `3c53ba7`) then traffic switched; 20:55:25 `ROLLBACK SUCCEEDED`; the client printed `CONFIRMED: staging is serving 3c53ba7`.
- The target was in the host's release history as deployed (the rollback refuses otherwise), it passed the same validation as a deploy before traffic moved, and **no migration ran**.
- **Not exercised on the instance:** re-pulling the recorded image digests. The images were still on the host, so that path ran only in the offline tests (`lab-mode.test.sh` section 7).

## 3. Restore (`3-restore-deploy-host-log.txt`)
`live=blue (3c53ba7)` -> `green` with `6ac7802`: validated 21:00:45, live 21:00:56, `DEPLOY SUCCEEDED`. The fault file was gone (`no fault file ... not armed`). The images were rebuilt in that run, so their digests differ from the failed attempt's.

## Requests during all of it (`request-loop.log`, `summary.json`)
`/health` of the staging nginx through the Systems Manager port-forward, 20:47:38 to 21:03:38 (960 s):

| | Value |
|---|---|
| **Requests** | **2270** |
| **Failed** | **0** (0 timeouts, 0 non-200, longest failure streak 0) |
| Latency (ms) | min 204, avg 205, p50 205, p95 206, p99 211, max 250 (includes the tunnel) |
| During the fault deploy and automatic rollback (20:53:21 to 20:53:47) | 62 requests, all 200 (26 of them inside the 10 s the injected release was on nginx) |
| During the manual rollback (20:55:09 to 20:55:26) | 41 requests, all 200 |
| During the restore deploy (21:00:41 to 21:00:57) | 38 requests, all 200 |

Limit: through the tunnel the loop sends about 2.4 requests per second (a gap of about 0.42 s), so a failure shorter than that could fall between two requests; it requested only `/health`. This is a measurement, not a proof for every sub-second interval.

## Not shown here
Screenshots (the owner captures them from the runs above). The version of the wrapper installed on the host was not checked in this sequence. The deploys in this evidence do not include a real (non-injected) unhealthy release.
