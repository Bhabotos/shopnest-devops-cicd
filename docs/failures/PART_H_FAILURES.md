# Part H: three deliberate pipeline failures, root causes and recoveries

> **Work in progress: evidence is incomplete.** Every fact below comes from the Git history or the GitHub Actions logs and was read
> on 2026-11-21, or is the project owner's statement and is labelled as such. Items the owner can still supply are marked **PENDING YOUR INPUT** or **MISSING** (screenshots not yet captured).
> Items that cannot be recovered are marked **Not recalled / Evidence unavailable**: the owner could not recall them on 2026-11-21 and no record of them exists in Git, GitHub or the repository.
> Nothing is reconstructed: no Copilot prompt, answer or troubleshooting step is invented. Thirteen screenshots are in `docs/screenshots/part-h/` and are mapped to the runs in the
> [screenshot evidence map](#screenshot-evidence-map); several are **partial** evidence and are labelled as such there.

Repository: https://github.com/Bhabotos/shopnest-devops-cicd

## Summary

| # | Kind | Failed run | Fix | Recovered run |
|---|---|---|---|---|
| 1 | YAML syntax error | [44884178546](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44884178546) (push, `7c526dc`) | commit [`d2b645c`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/d2b645c) | [44884710861](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44884710861) |
| 2 | Deployment / connection failure (health check) | [44884809417](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44884809417) (manual dispatch, `8feb5a0`) | a corrected workflow input on the same commit `8feb5a0`; **no fix commit** (see the gap below) | [44885032635](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44885032635) |
| 3 | Failing test | [44920064307](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920064307) (PR #28, `a3282f4`) | commit [`5472d40`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/5472d40c1ea4e9e54a453d3f8120a65ac3b71a46) | [44920708004](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920708004) |

All failed runs are kept in the Actions history and must not be deleted. Failures 1 and 2 use the demonstration workflow
`.github/workflows/pipeline-demo.yml` (generated with GitHub Copilot, see `docs/copilot/`). Failure 3 uses the real CI workflow.

**Timestamps.** Git commit times are recorded in **UTC+06:00** (the author and committer dates of `7c526dc`, `d2b645c`, `a3282f4` and `5472d40` all carry the offset `+0600`).
GitHub run times are in **UTC**. Worked example: `7c526dc` is dated 13:48:27 +0600, which is 07:48:27 UTC, and its failed run started at 08:17:27 UTC, so the push came after the commit.
`d2b645c` is dated 14:23:01 +0600, which is 08:23:01 UTC, and its recovered run started at 08:24:06 UTC.

---

## Failure 1: YAML syntax error

**Description.** A workflow file that is not valid YAML, so GitHub cannot create any job.

**Deliberate change.** Commit [`7c526dc`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/7c526dc) ("demo: introduce a deliberate YAML syntax error in
pipeline-demo.yml"), on branch `demo/yaml-syntax-error`, one line in `.github/workflows/pipeline-demo.yml`:
```diff
-    runs-on: ubuntu-latest
+    runs-on ubuntu-latest
```
(the colon after `runs-on` was removed). The commit message gives the position as **line 19**, in the `backend-tests` job. Both failure 1 commits (`7c526dc` and `d2b645c`) carry a
`Co-Authored-By: Claude Sonnet 5.5` trailer in Git, which means they were created with Claude Code's assistance.

**Observed error.** Run 44884178546 (event `push`, branch `demo/yaml-syntax-error`, commit `7c526dc`) finished as `failure` with **0 jobs**. The GitHub CLI
(`gh run view`) reports for this run: *"This run likely failed because of a workflow file issue."* GitHub's web page for this run (screenshot
[`YAML Syntax Failure.png`](../screenshots/part-h/YAML%20Syntax%20Failure.png): run #2, commit `7c526dc`, branch `demo/yaml-syntax-error`, status Failure) shows one annotation, visible in the image as:

> **Invalid workflow file: .github/workflows/pipeline-demo.yml#L20**
> **You have an error in your yaml syntax on line 20**

That is GitHub's own error text with the line number (line 20), and it agrees with the commit message, which put the break at line 19 and the parser error at line 20. The screenshot does not show the run ID; the run is
identified by its run number, commit and branch, which match run 44884178546 in the GitHub API.

**Run-name evidence (read from the GitHub API on 2026-11-21).** The failed run 44884178546 is named `.github/workflows/pipeline-demo.yml`, the **file path**, instead of
the workflow's `name:` value. The recovered run 44884710861, on the fixed commit `d2b645c`, is named `pipeline-demo`. A run named with the file path is consistent with GitHub being unable to
read the workflow file, which matches the syntax error. This is an observation from the API: it does not give the error message or the line number, which come from the screenshot above.

**Recorded in Git at the time** (details taken from the commit messages of `7c526dc` and `d2b645c`; the messages were written with Claude Code's assistance). They state that: the colon was removed at
**line 19**; the parser fails at **line 20**; locally, PyYAML and actionlint both rejected the file with *"mapping values are not allowed here"* at line 20 (actionlint also reported *"could not parse as YAML"*);
the missing colon turns line 19 into the start of a multi-line plain scalar; run 44884178546 failed immediately with 0 jobs and *"This run likely failed because of a workflow file issue."*; and after the fix PyYAML parses the file and
actionlint reports no findings. These are the **local tools' messages** as recorded in the commit messages. They are **not** the text of GitHub's web page, which is quoted from the screenshot above.

**Root cause.** `runs-on ubuntu-latest` has no `:`, so it is not a `key: value` pair inside the job's mapping. The YAML parser rejects the file, GitHub
marks the workflow invalid, and no job starts. The mistake is in the file's syntax, not in the application or the runner.

**What the evidence shows** (analysis of the run and the commit, written afterwards; **not a record of the steps that were taken**).
1. The run has no jobs and a workflow-file issue message, which points to a failure before any step runs, in how the file is parsed.
2. The only change in the commit is one line, so that line is the suspect.
3. The line lacks the colon that every other key in the file has.

**Troubleshooting steps actually taken.** The only steps recorded in Git are those in the two commit messages above (local validation with PyYAML and actionlint, and reading the GitHub run result),
made with Claude Code's assistance. Any other steps the owner took, and any Copilot use: **Not recalled / Evidence unavailable**.

**Fix.** Commit [`d2b645c`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/d2b645c) ("demo: fix the YAML syntax error in pipeline-demo.yml"):
```diff
-    runs-on ubuntu-latest
+    runs-on: ubuntu-latest
```

**Recovered run.** [44884710861](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44884710861), push, commit `d2b645c`, `success`.

**Copilot troubleshooting.** **Not recalled / Evidence unavailable.** The project owner states that GitHub Copilot was used for troubleshooting (owner's statement, not independently verified), but could not
recall which failure it covered, and no Copilot conversation is stored in this repository or in its GitHub commit, pull request or comment records. The prompt, the answer and the changes made are therefore
not available and are **not reconstructed**. This is not assumed to match any other failure.

---

## Failure 2: deployment / connection failure (health check)

**Description.** The demo workflow's `deploy-check` job calls a health endpoint, as a deployment check would. A manual run was started with an
endpoint that cannot be reached.

**Deliberate change.** No commit. The project owner started the run **manually from the GitHub Actions UI** (event `workflow_dispatch`) on `demo/baseline` (commit `8feb5a0`) and
**personally entered** `https://shopnest-demo-target.invalid/health` in the `health_check_url` input. This is the owner's statement; the run log's `HEALTH_CHECK_URL` shows the same value.
The workflow's default is `https://api.github.com/zen`.

**Observed error.** Run 44884809417: job `backend-tests` = success, job `deploy-check` = **failure** at step *Check health endpoint*. Log:
```
HEALTH_CHECK_URL: https://shopnest-demo-target.invalid/health
Health check request failed.
##[error]Process completed with exit code 1.
```

**Screenshot evidence for this failure (partial).**
[`Health Check failure.png`](../screenshots/part-h/Health%20Check%20failure.png) shows run #4 (manually triggered, commit `8feb5a0`, branch `demo/baseline`, status Failure): `backend-tests` passed and `deploy-check` failed.
It does **not** show the expanded *Check health endpoint* step, so the screenshot does **not** prove the `.invalid` URL or the exact error message quoted above; those come from the run log read through the GitHub API.
**MISSING:** a screenshot of the expanded *Check health endpoint* step. [`Health Check Recovery.png`](../screenshots/part-h/Health%20Check%20Recovery.png) shows run #5 (manually triggered, commit `8feb5a0`,
Success, both jobs green). Neither screenshot shows the workflow inputs, so how the recovery run was started and which value it received stay **unverified**.

**Verified from the GitHub API and the run logs (2026-11-21).**
- The same commit `8feb5a0` had passed before: run [44881750147](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44881750147) (push to `demo/baseline`, 07:45:56 UTC, `success`).
- The failed run 44884809417 (08:25:22 UTC) and the recovered run 44885032635 (08:28:16 UTC, 2 minutes 54 seconds later) are **two separate runs**, each with `run_attempt` 1. The recovery was therefore a **new
  manual dispatch**, not a re-run of the failed run (a re-run would have kept the same run ID with attempt 2).
- Both runs have event `workflow_dispatch` and actor and triggering actor `Bhabotos`.
- The failed run's log shows `HEALTH_CHECK_URL: https://shopnest-demo-target.invalid/health`. The recovered run's log shows `HEALTH_CHECK_URL: https://api.github.com/zen`, and both of its jobs passed.
- **Not confirmable from GitHub:** whether either run was started from the web UI or the command line (the API records only the event and the actor), and whether the recovery run's URL was typed or left at the
  default (the workflow uses the default when the input is empty, so both give the same log). For the failed run, the UI method and the typed URL are the owner's statement above.

**Root cause.** The `.invalid` top-level domain is reserved and can never resolve, so the HTTP request cannot connect. The step's script treats a failed request as a
failed deployment check and exits 1, which is the intended behaviour. This is a configuration and connectivity failure, not a code defect.

**What the evidence shows** (analysis of the run log and the workflow script, written afterwards; **not a record of the steps that were taken**).
1. `backend-tests` passed, so the failure is limited to the deployment check.
2. The failing step's log names the value of `HEALTH_CHECK_URL` and the message "Health check request failed". The script prints a different message for a non-2xx status, so the request itself failed.
3. The URL ends in `.invalid`, which cannot resolve.

**Troubleshooting steps actually taken, including any Copilot use.** **Not recalled / Evidence unavailable.** The owner could not recall them, and nothing is recorded for this failure: it has no commit,
no pull request and no comment.

**Fix.** The recovery was a **corrected workflow input on the same commit** (`8feb5a0`): the run was started again with a reachable endpoint, `HEALTH_CHECK_URL: https://api.github.com/zen`
(the workflow's default), and no file in the repository changed. **There is no fix commit**, because the failure came from an input and not from the repository, and none has been created.
See "Evidence gaps" below: the assignment asks for a link to the fix commit.

**Recovered run.** [44885032635](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44885032635), `workflow_dispatch`, same commit `8feb5a0`: `deploy-check` = success, `backend-tests` = success. The log shows the default URL. How this recovery run was started (UI or CLI) is **Not recalled / Evidence unavailable**; the GitHub API does not record it (see the verified facts above).

**Copilot troubleshooting.** **Not recalled / Evidence unavailable.** The project owner states that GitHub Copilot was used for troubleshooting (owner's statement, not independently verified), but could not
recall whether it covered this failure. No conversation is stored in the repository or in GitHub's records, so the prompt, answer and changes are not available and are **not reconstructed**.

---

## Failure 3: failing test (verified; PR #28)

**Description.** A unit test that asserts a wrong value, caught by the required CI checks on a pull request.

**Deliberate change.** Commit [`a3282f4`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/a3282f41f43f96f0fc3b3a1aed5f3ec74d6d8c59). The edit was made by the project owner, who confirmed it was introduced
deliberately for this assignment. The commit and the pull request were created with Claude Code's assistance, under the owner's Git identity. Branch `test/failing-config-default-port`, PR [#28](https://github.com/Bhabotos/shopnest-devops-cicd/pull/28) ("DO NOT MERGE"):
```diff
   it('falls back to the default for a non-numeric port', () => {
-    expect(loadConfig({ PORT: 'abc' }).port).toBe(3000);
+    expect(loadConfig({ PORT: 'abc' }).port).toBe(3001);
```
(`backend/test/config.test.js`, line 34). The application code was not changed.

**Observed error.** Run [44920064307](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920064307) (pull request, `a3282f4`) = failure:
- **Backend (Node 22)** and **Backend (Node 24)** failed at the step *Test (unit and PostgreSQL integration)*; install and lint had passed.
- **Backend Docker image** was skipped (it needs the Backend job). Frontend (Node 22 and 24) and Deploy scripts and Compose passed.
- Log: `FAIL test/config.test.js > loadConfig > falls back to the default for a non-numeric port`, `AssertionError: expected 3000 to be 3001 // Object.is equality`
  (Expected 3001, Received 3000), `Test Files 1 failed | 12 passed (13)`, `Tests 1 failed | 170 passed (171)`.
- The PR's merge state was **BLOCKED**. This was observed through the GitHub API while the checks were failing. **No screenshot of the blocked merge exists**: the checks are green now, so that view can no longer be captured as it was.

**Screenshot evidence for this failure.**
[`Failed backend test.png`](../screenshots/part-h/Failed%20backend%20test.png) shows CI run #56 on PR #28 (Failure; Backend Node 22 and 24 red, Frontend and Deploy scripts and Compose green, Backend Docker image skipped).
[`Backend Failed run.png`](../screenshots/part-h/Backend%20Failed%20run.png) shows the Backend (Node 22) log with `AssertionError: expected 3000 to be 3001`, Expected 3001 and Received 3000, and the config test reported as 1 failed.
[`Fix commit.png`](../screenshots/part-h/Fix%20commit.png) shows commit `5472d40` restoring `toBe(3001)` to `toBe(3000)` at line 34. [`recovery plan.png`](../screenshots/part-h/recovery%20plan.png) shows the recovered CI run #57 (all six jobs green), and
[`PR28 open test.png`](../screenshots/part-h/PR28%20open%20test.png) shows PR #28 as Open and titled "DO NOT MERGE". **PR #28 is OPEN, UNMERGED and must not be merged.**

**Root cause.** The test's expectation was wrong. `loadConfig` in `backend/src/config.js` correctly falls back to 3000 (`intFrom(env.PORT, 3000)`), and the first test in the same file also expects 3000.
The code was right and the test was wrong.

**Troubleshooting steps actually taken** (carried out with Claude Code's assistance during the session and checked against the run logs and the local test results).
1. Open the failed run: only the two Backend jobs are red, at the Test step, so the problem is in the backend tests.
2. The log names one failing test and shows `expected 3000 to be 3001` at line 34 of `test/config.test.js`.
3. Read `backend/src/config.js`: the default port is 3000. So the application is correct and the assertion is wrong.
4. Fix the assertion (not the code), and validate locally: `test/config.test.js` 5 of 5 passed; full backend suite 160 passed, 0 failed, 11 skipped (the PostgreSQL integration tests need a database
   and were skipped locally; CI ran them); lint clean.
5. The project owner's own use of Copilot for this failure: **Not recalled / Evidence unavailable** (the owner states Copilot was used for troubleshooting but could not recall whether it covered this failure).

**Fix.** Commit [`5472d40`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/5472d40c1ea4e9e54a453d3f8120a65ac3b71a46) ("fix(test): restore the expected default port to 3000 (recovery from failure 3)"). The owner approved the fix; the commit was created with Claude Code's assistance:
```diff
-    expect(loadConfig({ PORT: 'abc' }).port).toBe(3001);
+    expect(loadConfig({ PORT: 'abc' }).port).toBe(3000);
```

**Recovered run.** [44920708004](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920708004) (pull request, `5472d40`): all six checks passed (Backend 22 and 24, Backend Docker image,
Deploy scripts and Compose, Frontend 22 and 24, including the PostgreSQL integration tests). The merge state became CLEAN. PR #28 stays open and is not merged; it exists only as evidence.

**Copilot troubleshooting.** **Not recalled / Evidence unavailable.** The project owner states that GitHub Copilot was used for troubleshooting (owner's statement, not independently verified), but could not
recall whether it covered this failure. The troubleshooting recorded above was done with Claude Code. No Copilot conversation is stored in the repository or in GitHub's records, so a Copilot prompt, answer and
changes are not available and are **not reconstructed**.

---

## How the required checks stopped a failing change from merging

The `main` branch is protected (read-back: `docs/evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md`): a pull request is required, and five status checks must pass
(**Frontend Node 22 and 24, Backend Node 22 and 24, Backend Docker image**), the branch must be up to date, administrators are included, and force pushes are disabled.

On PR #28, both Backend checks failed and the Docker-image check was skipped, so the required checks were not satisfied. GitHub reported the merge state as **BLOCKED**, and the change could not be merged.
After the fix commit, all required checks passed and the state became **CLEAN**. The failing change was stopped by CI before it could reach `main`.

Screenshots: the failing checks are in `Failed backend test.png` and `Backend Failed run.png`. The branch protection screenshots are **partial**: `Branch Protection.png` shows that "Require a pull request before merging" and
"Require status checks to pass before merging" are enabled for `main`, but not the names of the required checks, "Require branches to be up to date", administrator enforcement or the force-push setting, which rest on the
read-back document above. There is **no screenshot of a live blocked-merge banner**; the historical failure is shown by `docs/screenshots/part-b/pr28-commits.png` and `docs/screenshots/part-b/pr28-blocked-check.png` (added 2026-11-23).

---

## Existing Copilot evidence (not troubleshooting)

`docs/copilot/` records how `pipeline-demo.yml` was **generated** with Copilot: the prompts (labelled EXACT or PARTIAL), the responses, the edits, and an assistant-written SHA comparison
that is explicitly not Copilot output. **No Copilot troubleshooting conversation** is in the repository, in any commit message, or in any pull request, issue or review comment (0 comments exist in the
repository). The project owner states that GitHub Copilot was used for troubleshooting; this is the owner's statement and is not independently verified. The owner could not recall which failure(s) it covered or the
prompts and answers, which are therefore marked **Not recalled / Evidence unavailable** and are not assumed to be the same for each failure. Part H asks for this evidence for each failure, so this remains an open gap in the evidence.

**Local check on the owner's machine (cannot be verified from the repository).** VS Code's chat index for this repository's workspace lists three chat sessions on 2026-11-21, all before the first failure commit
(`7c526dc`, 13:48:27 +06:00): two empty sessions titled "New Chat" (created 12:38 and 13:03, UTC+06:00) and one titled "GitHub Actions workflow for pipeline-demo.yml" (created 13:03, last request 13:21, UTC+06:00).
No session dated after the first failure commit is listed. Only titles and times were read; no session content was opened. This does not rule out Copilot use elsewhere (for example on github.com or in another
VS Code window), which is why the owner's statement is kept and labelled as unverified. None of the 13 screenshots shows GitHub Copilot.

---

## Screenshot evidence map

Thirteen screenshots are in [`docs/screenshots/part-h/`](../screenshots/part-h/), stored under the filenames the owner supplied (two of them, `CI Configure.png` and `recovery plan.png`, do not describe what they show, and `Sucessfully recovery.png`
is spelled as supplied). **No screenshot displays a run ID or URL.** Each is tied to a run by its run number, commit and branch, which were checked against the GitHub API on 2026-11-21: run #2 is 44884178546, #3 is 44884710861,
#4 is 44884809417, #5 is 44885032635, and the CI runs #56 and #57 are 44920064307 and 44920708004.

| # | File | Failure | Run / commit | What it shows | Evidence level |
|---|---|---|---|---|---|
| 1 | [`YAML Syntax Failure.png`](../screenshots/part-h/YAML%20Syntax%20Failure.png) | 1 | run 44884178546 (#2), `7c526dc` | Failure with the annotation *Invalid workflow file: .github/workflows/pipeline-demo.yml#L20 / You have an error in your yaml syntax on line 20* | Sufficient |
| 2 | [`Sucessfully recovery.png`](../screenshots/part-h/Sucessfully%20recovery.png) | 1 | run 44884710861 (#3), `d2b645c` | Success; `backend-tests` and `deploy-check` green. It shows the run, not the fix diff | Sufficient for the recovery run |
| 3 | [`Health Check failure.png`](../screenshots/part-h/Health%20Check%20failure.png) | 2 | run 44884809417 (#4), `8feb5a0` | Manually triggered; `backend-tests` green, `deploy-check` red. **No expanded step, so no URL or error message** | **Partial** |
| 4 | [`Health Check Recovery.png`](../screenshots/part-h/Health%20Check%20Recovery.png) | 2 | run 44885032635 (#5), `8feb5a0` | Manually triggered; Success, both jobs green. It shows no inputs | Sufficient for the run state only |
| 5 | [`Failed backend test.png`](../screenshots/part-h/Failed%20backend%20test.png) | 3 | CI run 44920064307 (#56), PR #28 | Failure; Backend 22 and 24 red; Docker image skipped; Frontend and Deploy scripts green | Sufficient |
| 6 | [`Backend Failed run.png`](../screenshots/part-h/Backend%20Failed%20run.png) | 3 | run 44920064307, Backend (Node 22) | Test step log: `AssertionError: expected 3000 to be 3001`, Expected 3001, Received 3000 | Sufficient |
| 7 | [`Fix commit.png`](../screenshots/part-h/Fix%20commit.png) | 3 | commit `5472d40`, parent `a3282f4` | Diff `toBe(3001)` to `toBe(3000)`, 1 file, +1 −1 | Sufficient |
| 8 | [`recovery plan.png`](../screenshots/part-h/recovery%20plan.png) | 3 | CI run 44920708004 (#57), PR #28 | Success; all six jobs green. It is the recovered run, not a plan | Sufficient |
| 9 | [`PR28 open test.png`](../screenshots/part-h/PR28%20open%20test.png) | 3 | PR #28 | Open, "DO NOT MERGE" title and body, 2 commits. **It does not show a blocked merge** | Sufficient for "open and DO NOT MERGE" |
| 10 | [`Branch Protection.png`](../screenshots/part-h/Branch%20Protection.png) | B, D | rule for `main` | "Require a pull request before merging" and "Require status checks to pass before merging" are checked. **Not visible:** check names, up to date, admin enforcement, force pushes | **Partial** |
| 11 | [`CI Configure.png`](../screenshots/part-h/CI%20Configure.png) | B, D | rule for `main` | The branch protection rules list: one rule for `main`, applying to 1 branch. It shows no rule settings | **Partial** (adds little) |
| 12 | [`Github actions.png`](../screenshots/part-h/Github%20actions.png) | all | Actions list | 108 runs; recent CI success on `main` (`011752c`) and CD runs; workflows listed. **No failed run is visible in this view** | **Partial** |
| 13 | [`Readme.png`](../screenshots/part-h/Readme.png) | I | README on `main` | The top of the README with its "Honest status" banner and contents. The Part H section is not in view | **Partial** |

**Added 2026-11-23 (owner's captures):** `../screenshots/part-h/health-check-failure-expanded.png` (failure 2, run #4, the *Check health endpoint* step expanded), `../screenshots/part-b/pr28-commits.png` and `../screenshots/part-b/pr28-blocked-check.png` (failure 3, historical). **Still missing:** a live blocked-merge banner for PR #28 (cannot be reproduced now); the lower half of the branch protection page (required check names, up to date, administrator enforcement, force pushes); and the Actions list filtered to failed runs.

---

## Evidence gaps (what is still missing)

| # | Gap | Who | Needed for |
|---|---|---|---|
| G1 | **Resolved:** the failed run's page and its annotation are in `YAML Syntax Failure.png` (the exact text is quoted in failure 1) | none | failure 1 |
| G2 | **Partly resolved:** run summaries exist for the failed and recovered runs. **MISSING:** a screenshot of the expanded *Check health endpoint* step (`HEALTH_CHECK_URL` line and the error message) | project owner | failure 2 |
| G3 | **Partly resolved:** the failed run, the Test log, the fix commit, the recovered run and PR #28 as open are captured. **MISSING:** a screenshot of the blocked merge | project owner | failure 3 |
| G4 | **Not recalled / Evidence unavailable:** the Copilot troubleshooting conversation(s): which failure(s) each covered, and the exact prompt, answer and changes (not assumed to be the same across failures). The owner states Copilot was used | none can be recovered | all three |
| G5 | **Partly recovered:** failure 1's steps are recorded in its commit messages. Failure 2's steps are **Not recalled / Evidence unavailable** | none can be recovered | failures 1, 2 |
| G6 | Failure 2 has **no fix commit** to link (the fix was a corrected input). Decide how to document it; do not invent a commit | project owner | failure 2 |
| G7 | **Resolved (owner's statement):** the owner started the failure 2 run from the GitHub Actions UI and entered the `.invalid` URL; the run log shows the same value | none | failure 2 |
| G8 | **Resolved:** Git commit times are UTC+06:00 and run times are UTC (see "Timestamps" above) | none | all |
| G9 | **Partial evidence:** the branch protection screenshots do not show the required check names, "up to date", administrator enforcement or the force-push setting. **MISSING:** the lower half of the settings page | project owner | Parts B, D |
| G10 | **Partial evidence:** the Actions list screenshot shows no failed run. **MISSING:** the list filtered to failed runs | project owner | all failures |
| G11 | No screenshot displays a run ID or URL; runs are identified by run number, commit and branch (see the evidence map). Including the browser address bar in future screenshots would show the ID | project owner | all |

**Where the evidence is:** the 13 screenshots are in `docs/screenshots/part-h/` and are mapped to the runs in the [screenshot evidence map](#screenshot-evidence-map). The README links this file and the folder.
