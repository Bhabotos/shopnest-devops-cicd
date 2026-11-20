# Local blue/green rehearsal evidence

Everything here comes from the **local Docker Desktop rehearsal** (`deploy/scripts/demo-bluegreen-local.sh`),
run on a developer machine against a throwaway Compose project (`shopnest-demo-staging`), a loopback-only
port (18081), a temporary home directory and random database passwords. **None of it comes from AWS, EC2,
staging or a GitHub Actions deployment**; those have not run. See `SANITIZED.md` for the (small) edits made
for the public repository.

## Release identifiers are synthetic

`aaaa…`, `bbbb…`, `cccc…` and `dddd…` (forty repeated hex characters) are made-up release SHAs used only
by the rehearsal. They are not commits of this repository. Each one labels a locally built image
(`shopnest-backend:<sha>`, built from the same `backend/` source) so that the scripts' SHA, image-label and
`/version` checks have something to compare.

## What each attempt shows

| Attempt | Scenario | Result | Folder |
|---|---|---|---|
| 1 | Full scenario | **Failed** at deploy A: Windows cannot hold mode 600 on `secrets.env`, and the script rightly refused. Kept as failed-run evidence | `attempt1-failed-secrets-mode600/` |
| 2 | Full scenario, with the loose-secrets override authorised for that one run | **Failed**: during deploy B, 1 of 213 requests failed (HTTP 500 plus a 2.5 s stall) because deploy B recreated the database container. The run stopped there. Led to the `--no-recreate` and stable-mount fixes | `attempt2/` |
| 3 | Full scenario | **Passed 12 of 12**: A live, B deployed while requests flowed (238 of 238 HTTP 200), broken release C rejected before any traffic moved (107 of 107), manual rollback to A (161 of 161), database container never recreated | `attempt3/` |
| 4 | `--scenario post-switch` **as it was at commit `6d186e5`** (see the note below) | **Passed 9 of 9**: release D passed the pre-switch checks, traffic moved, the live check failed, and the **automatic rollback** put A back and stopped D. The database was never recreated. **Requests to `/` failed while D was live: 83 of 181** (about 20 s). The failure window is recorded, not hidden | `attempt4-post-switch-rollback/` |
| 5 | `--scenario all`, after the fix described in `attempt4-failure-analysis.md` | **Passed 24 of 24.** Steps 1-4 again (loops 269/269, 176/176, 180/180 HTTP 200). Step 5: release D with no `index.html` is **refused before anything changes** (exit 1); loops on `/` (105) and `/api/products` (108): **0 failed**. Step 6: release E is good, then its `index.html` is deleted right after the switch by the harness; the live check fails, the automatic rollback restores A (exit 1). **79 of 171 requests to `/` failed (about 20 s)**; nginx's own log shows `rewrite or internal redirection cycle ... "/index.html"` | `attempt5-all-scenarios/` |

**Historical note on attempt 4.** Attempt 4 was run with the rehearsal script as it was at commit `6d186e5`. In that
version `--scenario post-switch` deployed release D, whose frontend files had **no `index.html`**, and nothing checked the frontend
before the switch. The current script names that case `frontend-missing` (it is now refused before anything changes), and the
current `--scenario post-switch` is a different scenario: release E is good, and the harness deletes its `index.html` right after the
switch to inject a fault. The attempt 4 logs and results are unchanged; see `attempt4-failure-analysis.md` for what they show.

Attempt 4 shows that a failure *after* the switch is detected and reversed automatically. It also shows
that this case is **not** zero-impact: until the live check fails and traffic returns, users of the
affected path see errors. Only failures caught before the switch (attempt 3, release C; attempt 5, release D) cost no request. After the fix, the attempt 4 defect (a frontend without `index.html`) is caught before the switch; a failure that only appears after traffic moves (attempt 5, step 6) still costs a window of about 20 s before the automatic rollback.

## Kinds of evidence (do not mix them up)

| Kind | Where | What it proves | What it does not prove |
|---|---|---|---|
| Offline tests | `deploy/tests/bluegreen-logic.test.sh` (125 checks, fake Docker; run in CI by the "Deploy scripts and Compose" job) | the scripts' decisions: which colour, when traffic moves, what happens on failure, the loose-secrets guard | that real containers, nginx or Compose behave |
| Real Docker rehearsal | attempts 3, 4 and 5 here | real containers, real nginx reloads and a real database on a local engine | anything on AWS, staging, SSH, OIDC or the CD workflow |
| Failed attempts | attempts 1 and 2 | the defects that were found and fixed | – |

Exit code 3 (deploy failed AND the automatic rollback failed) is covered by the offline suite only; no real-Docker
run has produced it, because the harness cannot make a real recovery fail.

Not verified anywhere yet: AWS, EC2, staging, production, the CD and rollback workflows, OIDC and the
temporary SSH rule, and Node 22 inside the containers (images run Node 24).
