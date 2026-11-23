# GitHub Setup (partly executed, see Status)

Status: instructions, partly executed. CLI-verified 2026-11-19: the repository exists and is public, `main` and the feature branches have been pushed, and secret scanning and push protection are enabled (sections 2 and 3). Branch protection on `main` (section 5) was applied on 2026-11-20 and read back again on 2026-11-21: see the VERIFIED LIVE CONFIGURATION table in section 5 and [`docs/evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md`](evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md). GitHub Environments (section 4), Actions secrets and variables: read-only snapshot from 2026-11-21: 0 GitHub Environments, 0 Actions secrets, 0 Actions variables, 0 Dependabot secrets, and the variable `CD_ENABLED` unset (see "Environments, secrets and variables snapshot" in [`docs/evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md`](evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md)). This is a point-in-time snapshot, not a permanent configuration: they are created when the deployment phases need them, and CD stays disabled while `CD_ENABLED` is unset. The other settings in section 3 were not checked against these instructions.
Do not add any server IP, DNS name or URL to this file or any repository file (live URL pending
instructor clarification).

## 1. Local prerequisites (per clone)
1. Install Gitleaks: `winget install gitleaks.gitleaks` (restart the shell afterwards).
2. Enable the versioned hook: `git config core.hooksPath .githooks`
3. Use the GitHub noreply address for commits made in this repository only:
   `git config user.email "<ID>+<username>@users.noreply.github.com"`
   (take the exact value from GitHub -> Settings -> Emails; do not guess it).
4. On Linux/macOS clones make the hook executable: `chmod +x .githooks/pre-commit`.

The hook runs `gitleaks git --pre-commit --staged` with `.gitleaks.toml` and fails closed if
gitleaks is missing. Never bypass it with `--no-verify`.

## 2. Create the repository (run only after approval)
Name: `shopnest-devops-cicd`, visibility: public.

```
gh repo create shopnest-devops-cicd --public --source=. --remote=origin --description "ShopNest three-tier CI/CD with GitHub Actions"
```
This creates the repo and adds the `origin` remote; it does not push. Pushing is a separate
approved step. Browser alternative: github.com/new, same name, public, no README/.gitignore/licence
(the local repo already has the files).

## 3. Repository security settings
Settings -> Code security:
- Secret scanning: enabled
- Push protection: enabled
CLI equivalent:
```
gh api -X PATCH repos/<owner>/shopnest-devops-cicd -F "security_and_analysis[secret_scanning][status]=enabled" -F "security_and_analysis[secret_scanning_push_protection][status]=enabled"
```

Settings -> Actions -> General:
- Workflow permissions: read repository contents only (jobs request more explicitly)
- Require approval for workflows from outside collaborators/forks: enabled
- Do not delete workflow runs at any time (failed runs are graded evidence)

## 4. Environments and variables (Part D)
**Current state (read back through the GitHub API on 2026-11-23): two Environments exist, `staging` (id 28213109031) and `production` (id 28213117188); 0 Actions secrets and 0 Actions variables at repository level and in both Environments; `CD_ENABLED` is unset.** The Environments were created by the repository owner's approval on 2026-11-23; nothing else below has been configured. Creating any further item below is a GitHub settings change and needs the user's explicit approval. Values are never written in the repository.

Verified Environment configuration (API read-back, 2026-11-23):

| Setting | `staging` | `production` |
|---|---|---|
| Deployment branches | selected branches: `main` only | selected branches: `main` only |
| Required reviewers | none | `Bhabotos` (the repository owner) |
| Prevent self-review | not applicable (no reviewer) | **OFF** (single maintainer; the owner must be able to approve) |
| Administrators can bypass protection rules | `true` (GitHub's default, not changed; no reviewer to bypass) | **`false`** (changed on 2026-11-23 from the default `true`, read back independently) |
| Variables / secrets | 0 / 0 | 0 / 0 |

This is configuration only. It does **not** prove that a run pauses at "Waiting for review", that an approval works, or that anything was deployed: none of that has been tested.

Settings -> Environments:
| Environment | Protection | Used by |
|---|---|---|
| `staging` | Deployment branches: `main` only. A required reviewer is recommended. | `deploy-staging` in `cd.yml` and the deploy job in `rollback.yml` (both declare `environment: staging`) |
| `production` | Deployment branches: `main` only. Required reviewers: the repo owner. | The `production-approval` job in `cd.yml` (an approval gate only: **no production deployment is implemented**, so approving it deploys nothing). |

Note: with a single maintainer, leave "Prevent self-review" OFF for `production`, otherwise nobody can approve.

**There are no GitHub secrets in the current design** (the old `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `EC2_HOST`, `EC2_USER` and `SSH_SG_ID` names are obsolete).
Names below were read from `cd.yml` and `rollback.yml` on `main` (`7d88e9b`):

| Scope | Variable | Purpose | Read by |
|---|---|---|---|
| Repository | `CD_ENABLED` | Master switch. Unless exactly `true`, CD is skipped and `rollback.yml` refuses. | `cd.yml`, `rollback.yml` |
| `staging` | `AWS_ROLE_ARN` | GitHub OIDC deploy role to assume (Terraform output `github_deploy_role_arn`) | both |
| `staging` | `AWS_REGION` | AWS region | both |
| `staging` | `ECR_REPOSITORY` | Backend image repository **name** (for example `shopnest/staging/backend`), not the URL from `ecr_repository_urls` | `cd.yml` |
| `staging` | `ARTIFACT_BUCKET` | S3 bucket for release bundles | both |
| `staging` | `MIGRATOR_PROJECT` | CodeBuild migrator project name | `cd.yml` |
| `staging` | `SSM_DEPLOY_DOCUMENT` | Systems Manager deploy document name | `cd.yml` |
| `staging` | `SSM_ROLLBACK_DOCUMENT` | Systems Manager rollback document name | `rollback.yml` |
| `staging` | `STAGING_INSTANCE_ID` | The application instance targeted by Systems Manager | both |

The values come from Terraform outputs after an approved apply, so these variables cannot be set meaningfully before AWS exists.
Reference: `docs/AWS_STAGING_INTEGRATION.md` section 4.

### 4.1 Production approval gate (Part D)
`cd.yml` ends with the job `production-approval`: `environment: production`, no permissions, no `id-token`, no checkout, no AWS step. It needs `gate` and
a successful `deploy-staging`. Its only action is to write a notice that nothing was deployed. It exists so that a production step is **held for a
manual approval**; it does not deploy, because no production infrastructure or production deploy job exists.

**Manual configuration (GitHub settings, needs the repository owner). Steps 1 and 2 were DONE on 2026-11-23 (see the table in this section); step 3 onwards is NOT done:**
1. DONE: create the `staging` Environment (deployment branches: `main` only).
2. DONE: create the `production` Environment with **Required reviewers** (the repo owner), **Deployment branches: `main` only**, "Prevent self-review" OFF (single maintainer) and "Allow administrators to bypass configured protection rules" OFF (otherwise the administrator, who is also the only reviewer, could skip the approval).
3. NOT DONE: only then set the repository variable `CD_ENABLED`, and the `staging` variables from the table above. **Order matters:** if a workflow references an Environment that does not exist, GitHub creates it
   with **no protection rules**, and the approval job would run without waiting. Do not set `CD_ENABLED` before step 2.
4. **Warning (UNVERIFIED behaviour):** because `production-approval` is bound to the `production` Environment, GitHub may record a deployment to `production` for it (the repository's Deployments view and the Environment's history) even though the job deploys nothing. The run summary says plainly that nothing was deployed. Check what GitHub shows during the test below, and do not present that entry as a production deployment in any evidence.
5. Test it for real (PENDING): run CD on `main`, confirm the run stops at "Production approval gate" with "Waiting for review", approve it, and keep the screenshots. Until that is done, **approval is not verified**. Note that `production-approval` needs a successful `deploy-staging`, which needs AWS (OIDC role, CodeBuild, Systems Manager): with no AWS resources the job is skipped and never reaches "Waiting for review". Setting `CD_ENABLED` without AWS would start a failing deploy attempt, so it must stay unset. A separate, non-AWS demonstration workflow, `.github/workflows/approval-demo.yml` (manual `workflow_dispatch` only; one job `production-approval-demo` bound to `environment: production`; no permissions, no checkout, no AWS, no secrets or variables; it runs only from `main`), is IMPLEMENTED in a pull request and awaits merge. It has NOT been run. To demonstrate the approval after it is merged: Actions -> approval-demo -> Run workflow on `main`, confirm the job shows "Waiting for review", approve it as `Bhabotos`, confirm it then finishes successfully, and keep the screenshots (the run must be kept: failed or waiting runs are evidence and must not be deleted). It proves the reviewer mechanism only, not the `cd.yml` chain, and the evidence must be labelled as a demonstration workflow.

**OIDC subjects (immutable claims).** This repository's subject claim uses numeric IDs (GitHub's immutable-subject setting, read with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`).
So the staging deploy job's subject is expected to look like `repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:staging`, not `repo:<owner>/<repo>:environment:staging`.
That form is **derived from the settings, not verified from a real token**: capture the real `sub` from a workflow run before writing it into `github_oidc_subjects`.
The staging role must list **only** the staging subject. Terraform now refuses a subject that does not start with `repo:` and end with `:environment:<this stack's environment>`,
so a branch, a pull request, or the `production` Environment cannot be put on the staging role by mistake. A future production role (separate stack and workspace) lists only the production subject.
The approval job cannot assume any role in any case: it has no `id-token` permission.

## 5. Branch protection for `main` (Part B)
Configure after the first CI run exists (Phase 3): GitHub can only select status checks that
have already reported. Settings -> Branches -> Add rule for `main`:
- Require a pull request before merging
- Require status checks to pass: select the CI jobs (frontend and backend, including both
  Node 22 and 24 matrix entries) once they exist
- Require branches to be up to date before merging
- Require conversation resolution (planned; the live setting is disabled, see "Current settings" below)
- Do not allow bypassing the above settings (include administrators)
- Block force pushes and deletions

**TEMPLATE: planned configuration, not verified live state.** The command and JSON below are a template for reproducing the protection. They were not executed as written and are not evidence of the live settings; the verified live settings are in "Current settings" below and in [`docs/evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md`](evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md). Run only after approval.
```
gh api -X PUT repos/<owner>/shopnest-devops-cicd/branches/main/protection --input protection.json
```
`protection.json` (create locally in a scratch location, do not commit if it contains anything sensitive; it does not):
```
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "Frontend (Node 22)", "app_id": 15368 },
      { "context": "Frontend (Node 24)", "app_id": 15368 },
      { "context": "Backend (Node 22)", "app_id": 15368 },
      { "context": "Backend (Node 24)", "app_id": 15368 },
      { "context": "Backend Docker image", "app_id": 15368 }
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false
}
```
Notes on the template: `checks` (a context name plus the GitHub Actions app ID 15368) is used instead of the older `contexts` list; per `PROJECT_STATUS.md`, a payload that sent both `contexts` and `checks` was rejected with HTTP 422 on 2026-11-20. `required_conversation_resolution` is `false` because that setting is intentionally disabled (ACCEPTED CONFIGURATION, see below); the bullet list above shows it as planned and the live value is what the table below reports.
Approving review count is 0 because there is a single maintainer; the PR plus passing checks is
the enforced gate. Raise it if a reviewer is added.

Evidence for checklist B5: a PR with failing CI showing the merge button blocked
(docs/screenshots/branch-protection). **PENDING DEMONSTRATION:** this has not been done and no screenshot exists.

### Current settings (VERIFIED LIVE CONFIGURATION, read from GitHub on 2026-11-21)
The instructions above are the plan; this table is what GitHub actually reports. Source: a read-only audit,
recorded as a redacted written read-back in [`docs/evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md`](evidence/BRANCH_PROTECTION_READBACK_2026-11-21.md)
(not a raw API response or screenshot).

| Setting | Live value |
|---|---|
| Pull request required before merging | enabled (0 required approvals) |
| Required status checks | `Frontend (Node 22)`, `Frontend (Node 24)`, `Backend (Node 22)`, `Backend (Node 24)`, `Backend Docker image`, each bound to the GitHub Actions app (ID 15368) |
| Branches must be up to date before merging | enabled |
| Administrators included | enabled |
| Force pushes / branch deletion | disabled / disabled |
| Push restrictions / rulesets | none / none |
| Conversation resolution required | **disabled** |
| Merge commit / squash / rebase allowed | enabled / enabled / enabled |
| Automatically delete head branches after merge | disabled |

### Differences from the plan above, and conventions
- **ACCEPTED CONFIGURATION: conversation resolution.** The checklist and the sample JSON above list it as required; it is intentionally left
  **disabled** because this is a single-maintainer assignment project. It is not an assignment requirement.
- **PROJECT CONVENTION: merge method.** Pull requests are merged with a normal merge commit. Squash and rebase merging remain enabled in GitHub, so
  merge-commit-only behaviour is **not** enforced by the repository settings.
- **Optional check.** `Deploy scripts and Compose` (job in `ci.yml`) is **not** a required check. The deployment validation it performs is not yet mature enough to be a
  mandatory merge gate. Terraform CI is also not required (it is path-filtered, see `.github/workflows/terraform-ci.yml`). The five application CI checks are the required ones.

## 6. Bootstrap order note
`main` needs one root commit before any PR can exist. The planned root commit contains only
`.gitignore`, `.gitleaks.toml` and `.githooks/`. All other work goes through feature branches and PRs.
