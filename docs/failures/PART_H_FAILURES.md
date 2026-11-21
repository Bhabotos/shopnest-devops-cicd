# Part H: three deliberate pipeline failures, root causes and recoveries

> **Work in progress: evidence is incomplete.** Every fact below comes from the Git history or the GitHub Actions logs and was read
> on 2026-11-21. Anything that is not on record is marked **PENDING YOUR INPUT** (the project owner supplies it). Copilot prompts and answers
> are placeholders: none is invented. Screenshots are listed as to-do items: none exists yet.

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
(the colon after `runs-on` was removed).

**Observed error.** Run 44884178546 (event `push`, branch `demo/yaml-syntax-error`, commit `7c526dc`) finished as `failure` with **0 jobs**. The GitHub CLI
(`gh run view`) reports for this run: *"This run likely failed because of a workflow file issue."* The text that GitHub's web page shows for this run, including the line number of
the YAML error, was not read and is **PENDING YOUR INPUT** (screenshot).

**Run-name evidence (read from the GitHub API on 2026-11-21).** The failed run 44884178546 is named `.github/workflows/pipeline-demo.yml`, the **file path**, instead of
the workflow's `name:` value. The recovered run 44884710861, on the fixed commit `d2b645c`, is named `pipeline-demo`. A run named with the file path is consistent with GitHub being unable to
read the workflow file, which matches the syntax error. This is an observation from the API: it does not give the error message or the line number, which stay pending above.

**Root cause.** `runs-on ubuntu-latest` has no `:`, so it is not a `key: value` pair inside the job's mapping. The YAML parser rejects the file, GitHub
marks the workflow invalid, and no job starts. The mistake is in the file's syntax, not in the application or the runner.

**What the evidence shows** (analysis of the run and the commit, written afterwards; **not a record of the steps that were taken**).
1. The run has no jobs and a workflow-file issue message, which points to a failure before any step runs, in how the file is parsed.
2. The only change in the commit is one line, so that line is the suspect.
3. The line lacks the colon that every other key in the file has.

**Troubleshooting steps actually taken, including any Copilot use.** **PENDING YOUR INPUT** (the project owner records them here).

**Fix.** Commit [`d2b645c`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/d2b645c) ("demo: fix the YAML syntax error in pipeline-demo.yml"):
```diff
-    runs-on ubuntu-latest
+    runs-on: ubuntu-latest
```

**Recovered run.** [44884710861](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44884710861), push, commit `d2b645c`, `success`.

**Copilot troubleshooting.** The project owner states that GitHub Copilot was used for troubleshooting (owner's statement, not independently verified). Whether it was used for **this** failure, and the
exact prompt, answer and changes, are **PENDING YOUR INPUT** and are not assumed to match any other failure. PLACEHOLDER:
- Prompt (verbatim): ____
- Copilot's answer (verbatim): ____
- What I accepted or changed, and why: ____

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

**Root cause.** The `.invalid` top-level domain is reserved and can never resolve, so the HTTP request cannot connect. The step's script treats a failed request as a
failed deployment check and exits 1, which is the intended behaviour. This is a configuration and connectivity failure, not a code defect.

**What the evidence shows** (analysis of the run log and the workflow script, written afterwards; **not a record of the steps that were taken**).
1. `backend-tests` passed, so the failure is limited to the deployment check.
2. The failing step's log names the value of `HEALTH_CHECK_URL` and the message "Health check request failed". The script prints a different message for a non-2xx status, so the request itself failed.
3. The URL ends in `.invalid`, which cannot resolve.

**Troubleshooting steps actually taken, including any Copilot use.** **PENDING YOUR INPUT** (the project owner records them here).

**Fix.** The recovery was a **corrected workflow input on the same commit** (`8feb5a0`): the run was started again with a reachable endpoint, `HEALTH_CHECK_URL: https://api.github.com/zen`
(the workflow's default), and no file in the repository changed. **There is no fix commit**, because the failure came from an input and not from the repository, and none has been created.
See "Evidence gaps" below: the assignment asks for a link to the fix commit.

**Recovered run.** [44885032635](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44885032635), `workflow_dispatch`, same commit `8feb5a0`: `deploy-check` = success, `backend-tests` = success. The log shows the default URL. How this recovery run was started (UI or CLI) has not been recorded.

**Copilot troubleshooting.** The project owner states that GitHub Copilot was used for troubleshooting (owner's statement, not independently verified). Whether it was used for **this** failure, and the
exact prompt, answer and changes, are **PENDING YOUR INPUT** and are not assumed to match any other failure. PLACEHOLDER: prompt (verbatim) ____ / answer (verbatim) ____ / what I changed ____

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
- The PR's merge state was **BLOCKED**.

**Root cause.** The test's expectation was wrong. `loadConfig` in `backend/src/config.js` correctly falls back to 3000 (`intFrom(env.PORT, 3000)`), and the first test in the same file also expects 3000.
The code was right and the test was wrong.

**Troubleshooting steps actually taken** (carried out with Claude Code's assistance during the session and checked against the run logs and the local test results).
1. Open the failed run: only the two Backend jobs are red, at the Test step, so the problem is in the backend tests.
2. The log names one failing test and shows `expected 3000 to be 3001` at line 34 of `test/config.test.js`.
3. Read `backend/src/config.js`: the default port is 3000. So the application is correct and the assertion is wrong.
4. Fix the assertion (not the code), and validate locally: `test/config.test.js` 5 of 5 passed; full backend suite 160 passed, 0 failed, 11 skipped (the PostgreSQL integration tests need a database
   and were skipped locally; CI ran them); lint clean.
5. The project owner's own use of Copilot for this failure: **PENDING YOUR INPUT** (the owner states Copilot was used for troubleshooting; whether that covered this failure is not yet recorded).

**Fix.** Commit [`5472d40`](https://github.com/Bhabotos/shopnest-devops-cicd/commit/5472d40c1ea4e9e54a453d3f8120a65ac3b71a46) ("fix(test): restore the expected default port to 3000 (recovery from failure 3)"). The owner approved the fix; the commit was created with Claude Code's assistance:
```diff
-    expect(loadConfig({ PORT: 'abc' }).port).toBe(3001);
+    expect(loadConfig({ PORT: 'abc' }).port).toBe(3000);
```

**Recovered run.** [44920708004](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920708004) (pull request, `5472d40`): all six checks passed (Backend 22 and 24, Backend Docker image,
Deploy scripts and Compose, Frontend 22 and 24, including the PostgreSQL integration tests). The merge state became CLEAN. PR #28 stays open and is not merged; it exists only as evidence.

**Copilot troubleshooting.** The project owner states that GitHub Copilot was used for troubleshooting (owner's statement, not independently verified). Whether it was used for **this** failure, and the
exact prompt, answer and changes, are **PENDING YOUR INPUT** and are not assumed to match any other failure. PLACEHOLDER: prompt (verbatim) ____ / answer (verbatim) ____ / what I changed ____

---

## How the required checks stopped a failing change from merging

The `main` branch is protected (read-back: `docs/evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md`): a pull request is required, and five status checks must pass
(**Frontend Node 22 and 24, Backend Node 22 and 24, Backend Docker image**), the branch must be up to date, administrators are included, and force pushes are disabled.

On PR #28, both Backend checks failed and the Docker-image check was skipped, so the required checks were not satisfied. GitHub reported the merge state as **BLOCKED**, and the change could not be merged.
After the fix commit, all required checks passed and the state became **CLEAN**. The failing change was stopped by CI before it could reach `main`.

---

## Existing Copilot evidence (not troubleshooting)

`docs/copilot/` records how `pipeline-demo.yml` was **generated** with Copilot: the prompts (labelled EXACT or PARTIAL), the responses, the edits, and an assistant-written SHA comparison
that is explicitly not Copilot output. **No Copilot troubleshooting conversation** is in the repository yet. The project owner states that GitHub Copilot was used for troubleshooting; this is the
owner's statement and is not independently verified. Which failure(s) it covered, and the exact prompts and answers, are pending and are not assumed to be the same for each failure. Part H asks for the evidence for each failure.

---

## Evidence gaps (what is still missing)

| # | Gap | Who | Needed for |
|---|---|---|---|
| G1 | Screenshots: failed run 44884178546 with the workflow-file error and its line number | project owner | failure 1 |
| G2 | Screenshots: failed run 44884809417 (the failed step and `HEALTH_CHECK_URL` line) and recovered run 44885032635 | project owner | failure 2 |
| G3 | Screenshots: failed run 44920064307, the expanded Test step, PR #28 blocked, then green; recovered run 44920708004 | project owner | failure 3 |
| G4 | The project owner's real Copilot troubleshooting conversation(s): which failure(s) each covered, and the exact prompt, answer and changes for each (not assumed to be the same across failures). The owner states Copilot was used | project owner | all three |
| G5 | The project owner's own troubleshooting steps for failures 1 and 2 | project owner | failures 1, 2 |
| G6 | Failure 2 has **no fix commit** to link (the fix was a corrected input). Decide how to document it; do not invent a commit | project owner | failure 2 |
| G7 | **Resolved (owner's statement):** the owner started the failure 2 run from the GitHub Actions UI and entered the `.invalid` URL; the run log shows the same value | none | failure 2 |
| G8 | **Resolved:** Git commit times are UTC+06:00 and run times are UTC (see "Timestamps" above) | none | all |

**Where the missing material goes:** screenshots under `docs/screenshots/part-h/`, referenced from this file. A link from the README's Evidence section is not added yet.
