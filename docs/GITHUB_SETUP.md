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

## 4. Environments (Part D)
Settings -> Environments:
| Environment | Protection |
|---|---|
| `staging` | Deployment branches: `main` only. No reviewers. |
| `production` | Deployment branches: `main` only. Required reviewers: the repo owner. |

Note: with a single maintainer, leave "Prevent self-review" OFF for `production`, otherwise
nobody can approve. Secrets and variables are created per Environment (names in README, values never).
See docs/OIDC_DESIGN.md for the planned names.

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
