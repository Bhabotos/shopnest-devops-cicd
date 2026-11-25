# Part H: the GitHub Copilot exercise (the owner's own actions)

The assignment requires **GitHub Copilot** to be used for workflow development and for troubleshooting. These steps are for you to perform in your own GitHub Copilot session (Copilot Chat in your editor or on github.com). Claude Code prepared this page only: **nothing Claude produced may be presented as Copilot output**, and every piece of evidence below must be your real prompt and Copilot's real answer, copied verbatim. If something was not done with Copilot, write "not done" instead of reconstructing it. Accidental failures (see section 2) are not part of this exercise.

## 1. The workflow-generation exercise (one prompt)

Open Copilot Chat with this repository and paste **exactly** this prompt (if you change it, record the changed text):

```text
Create a GitHub Actions workflow file `.github/workflows/pr-guard.yml` for this repository (a Node.js 22/24 project with backend/, frontend/, deploy/, infra/ and docs/ folders).
Requirements:
- Trigger: pull_request into main, and workflow_dispatch.
- One job on ubuntu-latest with a 5 minute timeout.
- Least privilege: top-level `permissions: {}` and `contents: read` on the job only. No secrets.
- Check out the repository with persist-credentials: false, and pin every third-party action to a full commit SHA with the version in a comment.
- Write to the job summary which top-level folders the pull request changed.
- Fail the job with a clear error message if any file under deploy/ (excluding deploy/tests/) changed but nothing under deploy/tests/ changed.
- Do not use any expression inside a `run:` script; pass values through `env:`.
```

Record on a branch `copilot/pr-guard`: `docs/copilot/01-prompt.md` (the exact prompt and the date), `docs/copilot/02-copilot-original-output.yml` (Copilot's output **unedited**) plus a screenshot of the answer, `docs/copilot/03-changes-and-reasons.md` (each change you made and why, for example a missing SHA pin, a wrong permission, an expression in a script), and the final `.github/workflows/pr-guard.yml` as a pull request.
Check it first: `docker run --rm -v "$PWD/.github/workflows:/wf:ro" rhysd/actionlint:latest /wf/pr-guard.yml`. Record the PR URL and the green run URL. Do not merge a version that fails CI.

## 2. Which existing failed runs count (verified list: [`EVIDENCE_INDEX.md`](EVIDENCE_INDEX.md))
| Run | What it is | Counts as a required deliberate failure? |
|---|---|---|
| 44884178546 (YAML), 44884809417 (deployment health check), 44920064307 (failing test) | deliberate, each with a kept recovery run | **Yes as deliberate failures.** Their Copilot troubleshooting was never recorded and is **not reconstructed**, so they cannot carry Copilot evidence |
| 45485258931 | a deliberate, fault-injected staging deploy (Part G), full host log kept | a deliberate *deployment* failure; usable as log material for scenario 3 if you prefer it, but the Copilot evidence still has to come from your own session |
| 44864872114, 44916673865, **45444399255 (ShellCheck)**, 45472728637 | **accidental** mistakes (the ShellCheck one was a test I added in PR #48, fixed by commit `a958e54`) | **No.** Not deliberate, no Copilot involved: they must not be presented as required scenarios or as Copilot evidence |

The exercise below therefore produces **three fresh deliberate failures with Copilot's troubleshooting**, distinct from each other and safe (nothing merged into `main`, nothing near production).

### 2b. Can PR #28 be one of the three demonstrations?
**Yes, as the deliberate automated-test failure, with Copilot evidence still missing.** PR #28 (branch `test/failing-config-default-port`, run [44920064307](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920064307)) is deliberate, isolated, never merged, and has a kept failed run, a green recovery run [44920708004](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920708004), the fix commit `5472d40`, and screenshots in `docs/screenshots/part-h/` (failed run, test log, fix commit, recovered run, PR open and marked DO NOT MERGE). What is **missing** for it to count as Copilot-assisted debugging:
1. the Copilot troubleshooting **prompt** and Copilot's **verbatim answer** (none was recorded; the owner could not recall which failure Copilot covered);
2. a **screenshot of that Copilot interaction**;
3. the root cause in your own words, tied to Copilot's answer (the existing write-up in `docs/failures/PART_H_FAILURES.md` was not produced with a recorded Copilot session);
4. a screenshot of the **blocked merge** (it cannot be recreated: the checks on PR #28 are green now).

Two honest options. **A (recommended):** do the fresh scenario 2 above, which produces all of this contemporaneously. **B (retrospective):** open Copilot Chat now, give it the *preserved* failing log of run 44920064307 and the diff of the failing commit (`git diff a3282f4~1 a3282f4`), save the prompt, the answer and a screenshot dated today, and say in the README that it was done **after the fact on a preserved failure**; use this only if your instructor accepts retrospective evidence, and never present it as contemporaneous. The same applies to the other two earlier deliberate failures (44884178546, 44884809417).

**Recorded so far (option B, retrospective): the YAML failure (below) and the backend test failure (next paragraph).** **Failure.** `.github/workflows/pipeline-demo.yml` at commit `7c526dc` (branch `demo/yaml-syntax-error`) has `runs-on ubuntu-latest` (no colon) on line 19; run [44884178546](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44884178546) failed at once with no jobs and the annotation "You have an error in your yaml syntax on line 20". **Root cause.** The missing colon after `runs-on` (verified in `git show 7c526dc` and in the diff of `d2b645c`). **Fix.** Commit `d2b645c` (parent `7c526dc`) adds the colon; recovery run [44884710861](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44884710861) (push, `d2b645c`) succeeded. **Copilot analysis.** Captured in Copilot Chat on a *preserved* failure, **after the fact** (the failed run page already says "4 days ago"): this is the retrospective option B of this file, not contemporaneous troubleshooting, and its acceptance by the instructor is unconfirmed. The original diagnosis and fix of this failure were done with Claude Code (commit trailers on `7c526dc` and `d2b645c`), not with Copilot; the Copilot analysis was added afterwards. Copilot's answer matches the repository facts above (line 19, the missing colon, commit `d2b645c`); it also cites the repository's own failure write-up, so it was not working from the log alone. No prompt file or verbatim answer file is stored in `docs/copilot/`; the screenshot is the only record. Screenshots: [`09`](../docs/screenshots/copilot/09_yaml_failure_copilot_analysis.png), [`10`](../docs/screenshots/copilot/10_yaml_failed_run.png), [`11`](../docs/screenshots/copilot/11_yaml_recovery.png). **Only the YAML and backend test debugging exercises are evidenced, both retrospectively.** The deployment / SSH failure (failure 2 and the never-run SSH preflight scenario) has **no** Copilot troubleshooting evidence, no SSH preflight failure run exists, and Part H is **not** complete.

**Recorded so far (option B, retrospective, backend test failure).** **Failure.** `backend/test/config.test.js` at commit `a3282f4` (PR #28, branch `test/failing-config-default-port`) asserts `toBe(3001)` where `loadConfig({ PORT: 'abc' }).port` returns 3000 (the default at `backend/src/config.js` line 8); run [44920064307](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920064307) failed in Backend (Node 22) and Backend (Node 24) with `AssertionError: expected 3000 to be 3001` at `test/config.test.js:34:46` (1 of 171 tests; Backend Docker image skipped). **Root cause.** A deliberately wrong expectation in the test; the application code is unchanged. **Fix.** Commit `5472d40` (parent `a3282f4`) restores `toBe(3000)`; the test file is identical to the one before the failure, so no assertion was weakened; recovery run [44920708004](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/44920708004) passed all six jobs, 171 of 171 backend tests on Node 22 and 24. **Original diagnosis.** Done with Claude Code at the time and checked again on 2026-11-25 from the raw job log, with a local reproduction (`a3282f4` fails 1 of 5 in `config.test.js`, `5472d40` passes 5 of 5). **Copilot analysis.** Captured in Copilot Chat on a *preserved* failure, **after the fact** (the failed run page already says "4 days ago"): the retrospective option B of `docs/COPILOT_EXERCISE.md`, not contemporaneous troubleshooting, and its acceptance by the instructor is unconfirmed. Its visible text agrees with the repository facts above. No prompt file or verbatim answer file is stored, so the screenshots are the only record, and the part of the answer that names the failing test and root cause is not visible in them. Screenshots: [`12`](../docs/screenshots/copilot/12_backend_test_copilot_analysis.png), [`13`](../docs/screenshots/copilot/13_backend_failed_run.png), [`14`](../docs/screenshots/copilot/14_backend_recovery.png).

## 3. The three failure scenarios
Rules for all three: a dedicated branch or the staging-only diagnostic; **never merge a deliberately broken change into `main`**; nothing touches production; never delete a failed run. For each, save: the failed run URL, a screenshot of the failing step with the exact error, your Copilot prompt and Copilot's answer (verbatim), the root cause in your own words, the fix, the fix commit (or corrected dispatch), and the green run URL with a screenshot.

### Scenario 1: YAML / workflow validation failure
```bash
git switch -c copilot-demo/yaml-failure origin/main   # after pr-guard.yml exists on a branch, branch from that instead
# break .github/workflows/pr-guard.yml: for example indent `timeout-minutes:` by one extra space or repeat the `permissions:` key
git commit -am "test: deliberately invalid workflow YAML (Part H failure 1)" && git push -u origin copilot-demo/yaml-failure
```
- **Expected failing evidence:** the Actions list shows a failed run named after the file with the annotation `Invalid workflow file ... You have an error in your yaml syntax on line N`; no job ran.
- **Copilot prompt (paste the exact annotation text):** `This GitHub Actions workflow file failed with: "<paste the annotation>". Here is the file: <paste .github/workflows/pr-guard.yml>. Explain the root cause and show the minimal fix.`
- **Fix and recovery:** apply the fix in a new commit on the same branch; the run goes green. Link both commits. Close the branch without merging if you do not want it in `main`.

### Scenario 2: automated unit-test failure
```bash
git switch -c copilot-demo/test-failure origin/main
# backend/src/config.js line 8: change `intFrom(env.PORT, 3000)` to `intFrom(env.PORT, 3001)` (backend/test/config.test.js asserts port 3000)
git commit -am "test: deliberately break a backend default (Part H failure 2)" && git push -u origin copilot-demo/test-failure
gh pr create --draft --base main --title "test: deliberate failing test (Part H) - DO NOT MERGE" --body "Deliberate failure for the Part H exercise."
```
- **Expected failing evidence:** the CI jobs `Backend (Node 22)` and `Backend (Node 24)` fail at the `Test` step with an assertion diff showing port 3001 against the expected 3000; `Backend Docker image` is skipped; the pull request cannot be merged.
- **Copilot prompt:** `This Vitest run failed in CI: <paste the failing assertion and the 10 lines around it>. The diff of the pull request is: <paste git diff origin/main>. Which change caused it, and what is the fix?`
- **Fix and recovery:** revert the value in a fix commit on the same branch; CI turns green. Keep the pull request unmerged (or close it).

### Scenario 3: deployment / connection failure (staging only, deploys nothing)
```bash
gh workflow run ssh-preflight.yml --ref main -f environment=staging -f simulate=wrong-host-key
```
- **What it does:** the job swaps the pinned SSH host key for a throwaway one, so strict host-key checking must refuse the connection. Nothing is started or changed on the host, and production is not involved.
- **Expected failing evidence:** the job fails in the step *Pre-flight through the SSM tunnel* with exit code 4 and a host-key verification error; the log contains `the pre-flight check failed`.
- **Copilot prompt:** `This GitHub Actions deployment step failed: "<paste the last 25 log lines of the step, without the credentials step's input block>". The workflow connects with SSH through an AWS Systems Manager port-forward and pins the server's host key with StrictHostKeyChecking=yes. What is the root cause and how should I fix it?`
- **Fix and recovery:** the cause is the deliberately wrong pinned key; the fix is to run the same workflow with `simulate=none` (a corrected dispatch, **no code change**: say so, do not invent a commit). The recovery run turns green.
- Alternative material for the same scenario: the preserved log of the fault-injected staging deploy (run 45485258931), if you prefer a failure from the deploy itself.

## 4. Evidence checklist (per scenario, and for the workflow exercise)
Save prompts and answers as `docs/copilot/<scenario>-prompt.md` and `docs/copilot/<scenario>-copilot-answer.md` (verbatim), screenshots under `docs/screenshots/part-h/`.

| Item | WF generation | Scenario 1 | Scenario 2 | Scenario 3 |
|---|---|---|---|---|
| Exact prompt saved with the date | [ ] | [ ] | [ ] | [ ] |
| Copilot's original answer saved verbatim, plus a screenshot | [ ] | [ ] | [ ] | [ ] |
| Your changes to it, and why | [ ] | n/a | n/a | n/a |
| Failed run URL | n/a | [ ] | [ ] | [ ] |
| Screenshot of the failing step with the exact error | n/a | [ ] | [ ] | [ ] |
| Root cause in your own words | n/a | [ ] | [ ] | [ ] |
| Fix commit SHA (scenario 3: the corrected dispatch run) | [ ] PR | [ ] | [ ] | [ ] |
| Green rerun URL and screenshot | [ ] | [ ] | [ ] | [ ] |
| `gitleaks` run over everything committed | [ ] | [ ] | [ ] | [ ] |

Then add a table to the README (failure, failed run URL, root cause, fix commit or corrected dispatch, green run URL, Copilot prompt file) and update `PROJECT_STATUS.md` row H. Do not delete any failed run.
