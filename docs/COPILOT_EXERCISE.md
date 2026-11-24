# Part H: the GitHub Copilot exercise (the owner's own actions)

The assignment requires **GitHub Copilot** to be used for workflow development and for troubleshooting. These steps are for you to perform in your own GitHub Copilot session. Claude Code prepared this page only: **nothing Claude produced may be presented as Copilot output**, and the evidence below must be your real prompts and Copilot's real answers, copied verbatim. If something was not done with Copilot, write "not done" instead of reconstructing it.

## 1. The workflow-generation exercise (one prompt)

Open Copilot Chat in your editor (or on github.com) with this repository and paste **exactly** this prompt (change it if you like, but then record the changed text):

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

Record, in `docs/copilot/` (create the files on a branch `copilot/pr-guard`):
1. `01-prompt.md`: the exact prompt you sent (and the date).
2. `02-copilot-original-output.yml`: Copilot's output, **unedited**, and a screenshot of the answer.
3. `03-changes-and-reasons.md`: every change you made to it and why (for example: a missing SHA pin, a wrong permission, an expression in a script).
4. The final `.github/workflows/pr-guard.yml`, opened as a pull request. Run `actionlint` on it first (`docker run --rm -v "$PWD/.github/workflows:/wf:ro" rhysd/actionlint:latest /wf/pr-guard.yml`). Record the PR URL and the green run URL.

## 2. Three deliberate, safe failures, each troubleshot with Copilot

Rules for all three: use a dedicated branch or the diagnostic below; **never merge a deliberately broken change into `main`**; never trigger anything against production; never delete a failed run (they are graded evidence). For each failure keep: the failed run URL, a screenshot of the failing step with the exact error, your Copilot prompt and Copilot's answer (verbatim), the root cause in your own words, the fix, the fix commit (or the corrected dispatch), and the green run URL.

| # | Failure | How to cause it (safe) | Expected failing evidence | Fix |
|---|---|---|---|---|
| 1 | **YAML / workflow validation** | Branch `copilot-demo/yaml-failure`: break the indentation or duplicate a key in `.github/workflows/pr-guard.yml` and push the branch | A run (or the workflow list) marked as failed with "Invalid workflow file" and the line number | Ask Copilot to explain the error from the log text; fix the YAML; push the fix commit; the run is green. Link both commits |
| 2 | **Automated unit-test failure** | Branch `copilot-demo/test-failure`: change one value that a backend test asserts (for example a default in `backend/src/config.js`) and open a **draft** pull request | The CI job `Backend (Node 22)` and `(Node 24)` fail at the "Test" step with the failing assertion; the pull request shows the failed required checks and cannot be merged | Ask Copilot to read the test output and propose the fix; revert the value in a fix commit on the same branch; CI turns green. Close the pull request without merging if you do not want the commit sequence in `main` |
| 3 | **Deployment / connection failure (staging only)** | After the staging pre-flight works once: Actions -> `ssh-preflight` -> Run workflow: environment `staging`, simulate **`wrong-host-key`** | The job fails in the step "Pre-flight through the SSM tunnel" with exit 4 and a host-key verification error; the log shows `the pre-flight check failed`; **nothing is started or deployed** (`ssh-preflight` never sends the real command) | Ask Copilot to troubleshoot from the log excerpt (strict host-key checking refused a key that is not the pinned one); the fix is to run it again with simulate `none`, which turns green. There is no code change in this scenario: say so, do not invent a commit |

The `ssh-preflight` workflow needs the instance to be reachable (see `docs/PRE_DEPLOYMENT_CHECKLIST.md`, rows 8 and 9). Until that works, scenario 3 cannot be run.

## 3. What goes into the repository
- `docs/copilot/` with the prompt, Copilot's original output, your changes and reasons, and the troubleshooting transcripts (copied from your Copilot session, with any secret removed first).
- `docs/screenshots/part-h/` with the screenshots (the failing step, the Copilot answer, the green run).
- A table in the README: failure, failed run URL, root cause, fix commit or corrected dispatch, green run URL, Copilot prompt reference.
- Run `gitleaks` on everything before you commit it.

Earlier deliberate failures already exist as graded evidence (runs 44884178546, 44884809417 and 44920064307, each with a recovery run). Their Copilot troubleshooting prompts were **not recorded and cannot be reconstructed**; this exercise produces the missing Copilot evidence.
