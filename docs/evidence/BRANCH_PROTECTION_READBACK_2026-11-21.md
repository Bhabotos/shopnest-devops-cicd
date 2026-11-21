# Branch protection read-back: `main` (2026-11-21)

**Scope:** the ShopNest repository (`Bhabotos/shopnest-devops-cicd`), branch `main`.
**Audit date:** 2026-11-21.

> **What this document is.** A redacted, written read-back of the settings reported by a read-only audit of GitHub on 2026-11-21.
> It is **not** a raw API response and **not** a screenshot. No raw output, request identifier, response timestamp or screenshot is
> included, because none was saved for this document. No GitHub setting was changed while this document was written.

## VERIFIED LIVE CONFIGURATION (read from GitHub on 2026-11-21)

### Branch protection on `main`
| Setting | Value |
|---|---|
| Branch protection exists | yes |
| Pull request required before merging | enabled |
| Required approving reviews | 0 |
| Branches must be up to date before merging (strict) | enabled |
| Administrators included in enforcement | enabled |
| Force pushes | disabled |
| Branch deletion | disabled |
| Push restrictions | none |
| Rulesets | none |
| Conversation resolution required | disabled |

### Required status checks (exactly five, all bound to the GitHub Actions app, ID `15368`)
1. `Frontend (Node 22)`
2. `Frontend (Node 24)`
3. `Backend (Node 22)`
4. `Backend (Node 24)`
5. `Backend Docker image`

These are the job names in `.github/workflows/ci.yml`. The job `Deploy scripts and Compose` and the Terraform CI jobs are **not** required checks.

### Repository merge settings
| Setting | Value |
|---|---|
| Merge commit | enabled |
| Squash merge | enabled |
| Rebase merge | enabled |
| Automatically delete head branches after merge | disabled |

## Environments, secrets and variables snapshot (read-only, 2026-11-21)
| Item | Value on 2026-11-21 |
|---|---|
| GitHub Environments | 0 |
| GitHub Actions secrets | 0 |
| GitHub Actions variables | 0 |
| Dependabot secrets | 0 |
| `CD_ENABLED` variable | unset |

This is a point-in-time, read-only snapshot, **not** a permanent configuration: Environments, secrets and variables are expected to be created later, when the deployment phases need them (and only with the owner's approval).
Because `CD_ENABLED` is unset, the CD workflow (`cd.yml`) stays disabled and its runs conclude `skipped`. This section is a written summary like the rest of this document, not a raw API response or screenshot.

## PROJECT CONVENTION (not enforced by GitHub)
- Pull requests are merged with a **normal merge commit**. Squash and rebase remain enabled in GitHub, so merge-commit-only behaviour is **not** technically enforced.
- Source branches are kept after merge by practice; GitHub does not delete them automatically.

## ACCEPTED CONFIGURATION
- Conversation resolution is intentionally left disabled. This is an accepted setting for a single-maintainer assignment project and is **not** an assignment requirement.
- Required approvals are 0 because there is a single maintainer; the pull request plus the five passing checks is the enforced gate.
- `Deploy scripts and Compose` stays an optional check for now. The deployment validation it performs is not yet mature enough to be a mandatory merge gate. The five application CI checks remain required.

## PENDING DEMONSTRATION
- Showing a pull request with a **deliberately failing required check** being blocked from merging has **not** been done. Checklist row B5 stays **In progress** until that demonstration exists (roadmap task T2.5). No screenshot exists in `docs/screenshots/`.

## Related documents
- [`docs/GITHUB_SETUP.md`](../GITHUB_SETUP.md) section 5 (setup instructions and the current settings table)
- [`docs/REQUIREMENTS_CHECKLIST.md`](../REQUIREMENTS_CHECKLIST.md) row B5
- [`README.md`](../../README.md) (required checks and merge convention)
