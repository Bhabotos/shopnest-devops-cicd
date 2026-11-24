# Screenshot checklist (Parts E, F, G and H)

Screenshots must be real captures of the pages below, taken by the owner. **None exists yet for Parts E, F and G, and none is claimed.** Save them under `docs/screenshots/part-e/`, `part-f/`, `part-g/` and `part-h/` (new files, original names kept) and reference each from the README.

**Redaction rule (important):** the public run logs show the instance id (in each step's `env:` header) and, once, the role ARN with the AWS account id (in the credentials step's `with:` echo). Do **not** capture those lines. Capture the run summary, the job graph and the specific log lines listed below; crop or scroll so that the credentials step's input block and the `env:` blocks are not visible. Run `gitleaks` over the image folders' text sidecars if you add any, and never capture a secret value, a private key or a browser address bar with a server address.

Base URL: `https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/<id>`

## Part E: deployment to EC2
| # | Capture | Page | Must show |
|---|---|---|---|
| E1 | CD run graph | run **45469834249** | `gate`, `Build and publish images`, `Deploy to staging` green; `Deploy to production` **Waiting** for review |
| E2 | Staging deploy job's summary | run 45469834249 -> job `Deploy to staging` -> Summary | release SHA, both image digests, result code `0` |
| E3 | Host log in the artifact | download the artifact `deploy-log-staging-...` and open it, or open `docs/evidence/staging-deploy-1/deploy-log-host.txt` | `backend image ... pulled from GHCR by digest and its revision label matches`, `applying migrations`, `DEPLOY SUCCEEDED`, `CONFIRMED` |
| E4 | Endpoint verification | run **45489787099** (`staging-verify`) -> Summary / job log | 4 PASS lines: frontend, `/health`, `/version` hidden, `/api/products` |
| E5 | SSH pre-flight | run **45459661738** -> job log, lines `tunnel is up`, `pre-flight ok`, `the real command was NOT sent` | the path works and starts nothing |
| E6 | Production gate | run 45469834249 -> the `Deploy to production` job showing **Waiting for review** (do **not** approve) | the approval gate is real |
| E7 | GHCR packages | the repository's Packages page showing `shopnest-backend` and `shopnest-frontend` public | public visibility |

## Part F: zero downtime
| # | Capture | Page | Must show |
|---|---|---|---|
| F1 | Request-loop result | run **45477290060** -> Summary (or `docs/evidence/zero-downtime/staging-deploys-3-4/summary.json`) | `requests=1850 failed=0`, timeouts 0, latency percentiles |
| F2 | Same for the other two loops | runs **45473006606** (1117) and **45484404230** (2270) | `failed=0` |
| F3 | The deployment inside the window | run 45477964033 and 45479105861 job `Deploy to staging` times, next to the loop's window (the README tables in `docs/evidence/zero-downtime/*/README.md`) | the loop's window encloses the deploy |
| F4 | Host timeline | `docs/evidence/zero-downtime/staging-deploys-3-4/deploy-4-host-log.txt` lines from `live=blue` to `is live on green` | validated before the switch, old colour drained |

## Part G: rollback
| # | Capture | Page | Must show |
|---|---|---|---|
| G1 | Automatic rollback run | run **45485258931** | `Deploy to staging` **failed**, `Deploy to production` **skipped** |
| G2 | Its host log | artifact `deploy-log-staging-6ac7802...` or `docs/evidence/rollback/1-automatic-rollback-fault-deploy-host-log.txt` | `FAULT INJECTION`, `post-switch verification FAILED`, `previous release ... is live again (automatic rollback complete)` |
| G3 | Manual rollback | run **45485651117** (Rollback) | three green jobs; the summary names `3c53ba7` |
| G4 | Its host log | `docs/evidence/rollback/2-manual-rollback-to-3c53ba7-host-log.txt` | `ROLLBACK SUCCEEDED`, `CONFIRMED: staging is serving 3c53ba7` |
| G5 | Restore | run **45486448054** | `DEPLOY SUCCEEDED` for the newest release |
| G6 | Requests during all three | run **45484404230** Summary | `requests=2270 failed=0` |

## Part H (Copilot): see [`COPILOT_EXERCISE.md`](COPILOT_EXERCISE.md), section 4 for the per-failure checklist.
