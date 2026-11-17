# GitHub Setup (prepared in Phase 1 — nothing here has been executed)

Status: instructions only. The repository has not been created and nothing has been pushed.
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
  Node 20 and 22 matrix entries) once they exist
- Require branches to be up to date before merging
- Require conversation resolution
- Do not allow bypassing the above settings (include administrators)
- Block force pushes and deletions

CLI equivalent (fill `<check names>` from the first CI run; run only after approval):
```
gh api -X PUT repos/<owner>/shopnest-devops-cicd/branches/main/protection --input protection.json
```
`protection.json` (create locally in a scratch location, do not commit if it contains anything sensitive; it does not):
```
{
  "required_status_checks": { "strict": true, "contexts": ["<check names>"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
```
Approving review count is 0 because there is a single maintainer; the PR plus passing checks is
the enforced gate. Raise it if a reviewer is added.

Evidence for checklist B5: a PR with failing CI showing the merge button blocked
(docs/screenshots/branch-protection).

## 6. Bootstrap order note
`main` needs one root commit before any PR can exist. The planned root commit contains only
`.gitignore`, `.gitleaks.toml` and `.githooks/`. All other work goes through feature branches and PRs.
