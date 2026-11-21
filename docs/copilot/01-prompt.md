# Prompts used with GitHub Copilot (Part H)

Evidence labels: **EXACT** = verbatim text; **PARTIAL** = incomplete or not independently verified;
**UNAVAILABLE** = not recoverable. Nothing below was reconstructed or paraphrased. Missing text is marked
UNAVAILABLE and must be copied manually from the Copilot Chat history if it still exists.

| # | Prompt | Text label | Response it produced (owner's statement) | Mapping label |
|---|---|---|---|---|
| 1 | First workflow prompt | EXACT as transcribed (see note) | `02-copilot-response.md`, also in `02a-workflow-response.md` | PARTIAL: not independently verified |
| 2 | 12-point secure workflow prompt | EXACT (quoted in `03-edits.md`) | the current `.github/workflows/pipeline-demo.yml`, in `02b-secure-workflow-response.md` | PARTIAL: not independently verified |
| 3 | Documentation draft prompt | PARTIAL: opening words only | `03-edits.md` (treated as the documentation response draft, not modified) | PARTIAL: not independently verified |

## Prompt 1: first workflow generation prompt
Text label: EXACT as transcribed from the owner's message in the working session. It was not byte-compared
with the Copilot Chat history. Mapping: the owner states that this prompt generated the first workflow
response; this cannot be independently verified (PARTIAL).

> I am working on my ShopNest DevOps CI/CD assignment. I need GitHub Copilot to independently generate a GitHub Actions workflow for an educational CI/CD demonstration.
>
> Please generate a complete workflow file named:
>
> `.github/workflows/pipeline-demo.yml`
>
> Requirements:
>
> 1. Triggers:
>    - Push to branches matching `demo/**`
>    - Manual `workflow_dispatch`
>
> 2. Security:
>    - Use least-privilege, read-only permissions.
>    - Pin all GitHub Actions to full commit SHAs.
>    - Do not include credentials, secrets, SSH keys, AWS configuration or real server IP addresses.
>    - Do not modify existing workflows.
>
> 3. Job 1: backend-tests
>    - Ubuntu latest.
>    - Node.js 24.
>    - Work inside the `backend` directory.
>    - Install dependencies using the existing lockfile.
>    - Run the actual backend test command from `backend/package.json`.
>    - Do not modify application code or package files.
>
> 4. Job 2: deploy-check
>    - Ubuntu latest.
>    - Accept a configurable health-check URL.
>    - Use curl to verify HTTP success.
>    - Fail on DNS errors, connection failures and non-success HTTP responses.
>    - Set connection and request timeouts.
>    - Use `https://api.github.com/zen` as the harmless default URL.
>
> 5. Keep the two jobs independent so they can run in parallel.
>
> Before generating the workflow:
> - Inspect the existing repository structure and CI workflow.
> - Confirm the actual backend test command and lockfile.
> - Explain the workflow design and any assumptions.
>
> Then provide the complete YAML and explain each job.
>
> IMPORTANT:
> - Do not create, edit, stage, commit or push any files automatically.
> - Do not run GitHub Actions or change GitHub settings.
> - I need the actual Copilot-generated response for my assignment evidence.

## Prompt 2: 12-point secure workflow generation prompt
Text label: EXACT. Copied unchanged from the "Original Copilot prompt" block in `03-edits.md`; the original chat
transcript itself was not independently available. Mapping: the owner states that this prompt produced the
current secure workflow with the HTTPS redirect protections; this cannot be independently verified (PARTIAL).

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

## Prompt 3: documentation draft prompt
Text label: PARTIAL. Only the opening words are known, as stated by the owner:

> "Prepare a documentation draft for the Copilot-generated pipeline workflow..."

The rest of the original prompt is **UNAVAILABLE** and has not been recovered. The response is treated as
`03-edits.md` (documentation response draft); that file has not been modified here, and its own statements
(including about edits and validation) are the owner's to confirm.
