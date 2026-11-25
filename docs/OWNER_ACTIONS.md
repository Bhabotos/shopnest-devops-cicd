# Owner actions: the exact things only you can do

Everything else in the assignment has been done and is in `main`. Production is **not** approved and **not** deployed; do not approve it unless you decide to. Tick each box when done and record the result in `PROJECT_STATUS.md`.

## A. GitHub Copilot (your own session; nothing here may be written or "recreated" by Claude)
Details, exact prompts and the evidence table: [`COPILOT_EXERCISE.md`](COPILOT_EXERCISE.md).
- [ ] **A1. Workflow generation.** Paste the single prompt of section 1 into Copilot Chat. Save the prompt (with the date), Copilot's **unedited** output and a screenshot of the answer; list every change you made and why; open the PR for `.github/workflows/pr-guard.yml`; run `actionlint`; record the PR and the green run URL.
- [ ] **A2. Scenario 1 (YAML failure).** Push the deliberately broken workflow on `copilot-demo/yaml-failure`; screenshot the failed run with the annotation; ask Copilot with the prompt in section 3; save the answer; fix in a new commit; screenshot the green run.
- [ ] **A3. Scenario 2 (test failure).** Branch `copilot-demo/test-failure` (default port 3001 in `backend/src/config.js`), draft PR; screenshot the failed `Backend` checks and the log; ask Copilot; save the answer; revert in a fix commit; screenshot green. *Or*, if your instructor accepts retrospective evidence, option B of section 2b for PR #28 (labelled as after the fact).
- [ ] **A4. Scenario 3 (deployment/connection failure, staging, deploys nothing).** `gh workflow run ssh-preflight.yml --ref main -f environment=staging -f simulate=wrong-host-key`; screenshot the failed step (do not capture the credentials step's input block or any `env:` block); ask Copilot; save the answer; re-run with `simulate=none` (no code change: say so); screenshot green.
- [ ] **A5. Record it.** `docs/copilot/` files and `docs/screenshots/part-h/` images; the README table (failure, failed run URL, root cause, fix commit or corrected dispatch, green run URL, prompt file); `gitleaks` over everything before committing.

## B. AWS (your Administrator Session Manager session on the instance; I cannot reach the host)
- [ ] **B1. Optional, strengthens Part G: arm the REAL fault once.** Only after I tell you the final safety check ([`PART_G_REAL_FAULT_DESIGN.md`](PART_G_REAL_FAULT_DESIGN.md)) has passed and the traffic loop is about to start:
  ```bash
  printf 'FAULT=backend-unhealthy-pre-switch\n' | sudo tee /opt/shopnest/staging/fault.env > /dev/null
  sudo chown root:root /opt/shopnest/staging/fault.env && sudo chmod 600 /opt/shopnest/staging/fault.env
  sudo stat -c '%U:%G %a %n' /opt/shopnest/staging/fault.env     # must print: root:root 600 /opt/shopnest/staging/fault.env
  ```
  Paste me the `stat` line. Do not create it earlier: the next staging deploy consumes it. Do not touch it afterwards.
- [ ] **B2. Only if you decide to deploy production later:** update the host wrappers from current `main` (`git clone` the repository, save the two **public** key lines as files, `sudo bash deploy/host/setup-deploy-host.sh --repository Bhabotos/shopnest-devops-cicd --staging-key-file ... --production-key-file ...`, then `sudo bash deploy/host/setup-deploy-host.sh --verify` and `sudo bash deploy/host/readiness-check.sh`). Not needed for anything already shown.
- [ ] **B3. Nothing else in AWS.** No Terraform apply, no IAM or security-group change, no access key.

## C. GitHub web (reviewer and screenshots)
- [ ] **C1. Production approval run [45432917228](https://github.com/Bhabotos/shopnest-devops-cicd/actions/runs/45432917228)** (an STS role-assumption check, not a deployment) is still waiting for you as the production reviewer: approve it, reject it, or leave it. Claude never approves it. Any production *deployment* approval is a separate decision you take in the `Deploy to production` job of a CD run.
- [ ] **C2. Screenshots for Parts E, F and G** (some exist: staging CD, request loop, automatic rollback and four redacted AWS console pages in `docs/screenshots/`; missing: manual rollback and restore, the real-fault run 45500242957, `staging-verify` run 45548376271, anything for production): the exact pages and what each must show are in [`SCREENSHOT_CHECKLIST.md`](SCREENSHOT_CHECKLIST.md). Crop out the instance id and the AWS account id.

## D. Decisions that are yours
- [ ] The **live URL** in the README: only possible after a production deployment (staging is loopback-only). Part D forbids a server address in the repository while the assignment asks for a URL: decide how to reconcile it, ideally with your instructor.
- [ ] Whether to deploy production at all (needs B2 first, then the reviewer's approval of the `Deploy to production` job).
- [ ] The staging environment's administrator bypass (currently on; production's is off).
- [ ] Whether your instructor accepts retrospective Copilot evidence (A3 option B).
