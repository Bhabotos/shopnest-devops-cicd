# Architecture (initial design — Phase 0)
Status: proposal. "M" = mandated by the assignment; "R" = our design choice.
No server IP, DNS name or URL is recorded here (live URL pending instructor clarification).

## Tiers
| Tier | Technology | Role |
|---|---|---|
| Presentation | React + Vite build, served by Nginx | Public UI (M: frontend tier) |
| Application | Node.js + Express REST API (Docker) | Business logic, /api, /health, /version |
| Data | PostgreSQL (Docker) | Internal only, no published port (M: not public) |

## Topology (one EC2 instance, ap-south-1)
```
 Internet ── 80/443 ──► Nginx
                          ├─ /      → static frontend
                          └─ /api   → upstream: backend-blue | backend-green
 GitHub runner ─ SSH (opened per run only, see below) ─► deploy user
 Docker networks: edge (nginx <-> backend), internal (backend <-> postgres; no host port)
```
Staging and production run as separate Compose projects with separate ports, env files,
networks and DB volumes on the same instance (R, due to the one-instance decision).
Limitation: not infrastructure-isolated; documented in the README.

## Network security
- Security group inbound (R): 80/443 public; 5432 never open; 22 closed by default.
- Postgres has no `ports:` mapping; reachable only on the internal Docker network.
- Validation: external connection attempt to 5432 must fail; screenshot of the SG as evidence.

## SSH connectivity strategy (GitHub runners <-> EC2)
Problem: GitHub-hosted runners have wide, changing IP ranges; allowing them all on port 22
exposes SSH unnecessarily. Part E still requires deployment over SSH (M).

Chosen strategy (R), port 22 closed by default, opened for one runner for one run:
1. Workflow authenticates to AWS with GitHub OIDC, assuming a role with short-lived credentials.
   No permanent AWS access keys are created or stored.
2. The role is least-privilege: only authorize/revoke ingress on this instance's security group.
3. The job determines the runner's public IP at run time and adds a single /32 rule for port 22.
4. Deploy over SSH with a dedicated deploy key stored as an Environment secret.
5. A cleanup step with `if: always()` revokes the rule, even when the deploy fails.
   A periodic safety check reports any leftover rule.
6. Host hardening: key-only auth, no root login, no password auth, dedicated unprivileged deploy
   user, pinned host key (known_hosts stored as a secret/variable), fail2ban optional.

Alternatives considered:
- SSH over AWS SSM Session Manager (port 22 never opened; needs OIDC role + SSM agent). Fallback.
- Allow all GitHub IP ranges on 22: rejected (large, changing, over-exposed).
- Self-hosted runner: rejected (extra infrastructure, out of scope).

Requires user approval in Phase 4 (IAM role / OIDC provider creation). Nothing is created now.

## Pipelines
- `ci.yml`: on push/PR to main. Parallel frontend & backend jobs (install -> lint -> test -> build).
  The backend and frontend test jobs use a Node.js version matrix: 22 and 24. Build outputs are uploaded as
  artifacts and consumed by CD.
- `cd.yml`: runs only after CI succeeds on main. Deploy staging -> validate -> production
  (GitHub Environment with required reviewers = manual approval).
- `rollback.yml`: workflow_dispatch with target commit SHA input.
- Workflow permissions are explicit and minimal.

## Deployment & rollback (R)
1. SSH to host; pull images tagged with the commit SHA.
2. Start the idle colour (e.g. green) beside the live colour (blue).
3. Post-deploy validation of green: `/health`, `/version` must equal the expected SHA, with
   retries and timeout.
4. Pass -> switch Nginx upstream, graceful reload, drain, stop old colour, record release.
5. Fail -> traffic stays on the old colour, new colour stopped, release marked failed
   (automatic recovery), job fails with clear logs.
- Release history on server: list of SHAs + `last_good` pointer. Manual rollback redeploys any
  listed SHA through the same validation path.
- Traceability: SHA in image tag, container label, `/version` endpoint and deploy log.
- Logs: written on the server and uploaded as workflow artifacts.
- Trade-offs: roughly 2x backend memory during deploy; DB migrations must be backward compatible.

## Controlled staging rollback test (Part G demonstration)
Performed on staging only, never production:
1. Establish a known-good release A on staging (recorded in release history, `/version` = A).
2. Start a continuous request loop against staging and log every response.
3. Deploy a deliberately broken release B (for example a backend that returns failures on
   /health, or fails to start) through the normal CD path.
4. Post-deploy validation fails; the pipeline triggers automatic recovery and keeps/returns
   traffic on A.
5. Verify: `/version` reports A, release history marks B as failed and `last_good` is still A,
   the request loop shows continuity, and the pipeline log shows the failure and the recovery.
6. Evidence: failed validation step, recovery step, request-loop output, workflow run link,
   commit SHAs of A and B.

## Secrets & config (M for separation and no secrets in repo)
- GitHub Secrets/Variables scoped to Environments `staging` and `production`.
- Names will be finalised in Phase 6 and listed in the README (names and purposes only).
- Local AWS access only via profile `devops`; no permanent AWS keys created or stored in GitHub.
- Terraform state is git-ignored; no `.tfvars` with real values committed.

## Open items
- Live URL vs. server-address restriction (instructor).
- SSH strategy approval (OIDC role vs SSM fallback).
- Terraform state backend.
