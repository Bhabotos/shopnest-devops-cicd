# Copilot Pipeline Demo Workflow

## Original Copilot prompt

> Generate a complete GitHub Actions workflow named `pipeline-demo.yml`.
>
> Requirements:
>
> 1. Trigger on push to `demo/**` branches.
> 2. Support manual workflow_dispatch with an optional `health_check_url` input. Default: `https://api.github.com/zen`.
> 3. Create two independent jobs: `backend-tests` and `deploy-check`.
> 4. Backend job must use Node.js 24, run `npm ci` and `npm test` in the backend directory.
> 5. Use minimal GitHub permissions.
> 6. Pin all third-party actions to verified full commit SHAs.
> 7. Health check must accept HTTPS only.
> 8. Prevent HTTPS redirects from downgrading to HTTP.
> 9. Limit redirects to a maximum of 3.
> 10. Use reasonable connection and total timeouts.
> 11. Do not use secrets or expose sensitive URLs.
> 12. Do not create, edit, or save any repository files.
>
> Show the complete YAML in one code block, followed by a short explanation of both jobs and their security controls.

## Generated workflow

The workflow filename is [`.github/workflows/pipeline-demo.yml`](../../.github/workflows/pipeline-demo.yml).

## Security requirements implemented

- Workflow-level permissions are empty. The backend job has only `contents: read`, and `deploy-check` has no permissions.
- Third-party actions are pinned to full commit SHAs. The referenced commits were confirmed to exist and have verified signatures.
- The health-check URL is checked for an HTTPS scheme. Curl allows only HTTPS for both the initial request and redirects.
- Redirects are capped at three. The connection timeout is 5 seconds and the total request timeout is 20 seconds.
- The script does not echo the URL, and curl error output is suppressed.
- No secrets are used.
- **Caution:** workflow-dispatch inputs may be visible in run metadata to people with access to the run. Do not provide credentials or sensitive URL data as input.

## Manual validation results

Manual validation was performed on 2026-11-21:

- YAML parsed successfully with PyYAML 6.0.3.
- The triggers, dispatch input, job structure, permissions, and backend commands were checked.
- Both action references use full 40-character SHAs; GitHub confirmed the commits exist and have verified signatures.
- The health-check script passed `bash -n`.
- HTTPS restrictions, redirect handling, and timeout settings were inspected.
- No errors were identified.

## Validation limitations and execution status

- `actionlint` was unavailable, so a dedicated GitHub Actions linter was not run.
- **The workflow has not been executed in GitHub Actions.** The results above are manual/static validation only.

## Post-generation edits

According to this session, no post-generation manual edits were made. The workflow file appeared to match the YAML generated in the chat; its edit history was not independently verified.
