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
