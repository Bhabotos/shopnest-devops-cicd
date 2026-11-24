# CLAUDE.md — ShopNest DevOps CI/CD

Guidance for Claude Code in this repository. Source of truth for requirements:
`assignment/GITHUB ACTIONS.docx` (Parts A–I, 100 marks). Do not invent requirements.

## Project
Automated CI/CD for ShopNest's three-tier app using GitHub Actions.
- Presentation: React + Vite, served by Nginx
- Application: Node.js + Express REST API
- Data: PostgreSQL (Docker, internal network only)
- Infra (current, `infra/lab/`): AWS in ap-south-1, provisioned with Terraform (our choice, not mandated): a dedicated VPC, one public subnet, an Internet Gateway, ONE `t3.small` with a public address, inbound TCP 80 only. PostgreSQL runs in a Docker container on an internal network. Staging and production are separate Compose projects on that one instance. No NAT Gateway, ALB, RDS or ECR. Written, never applied.
- The earlier, larger design in `infra/terraform/` (ALB, NAT, RDS, ECR, CodeBuild) is kept for reference only: do not modify it, never apply its saved plan files, and the deployment workflows no longer use it.
- Deploy: GitHub Actions builds the images, publishes them to GHCR tagged with the commit SHA, and deploys by digest over SSH through an AWS Systems Manager port-forwarding tunnel (a forced-command key per Environment, root-owned wrappers) using GitHub OIDC, with Docker Compose, Nginx reverse proxy, blue-green, health checks and automatic rollback. Production waits for the `production` Environment's reviewer. No inbound port 22. Never run against the instance.
- The assignment says deployment is "over SSH"; the owner decided on SSM (2026-11-23) but the instructor has not confirmed it (do not claim it is accepted). Same for the public live URL.
- Runtime matrix: backend and frontend Node.js 22 and 24; local development on Node.js 24 (never 18 or 20)

## Hard rules (never violate)
1. Never commit or print credentials, SSH keys, passwords, tokens, server IPs or hostnames.
   Any credential in repo/history = 0 marks for Part D. Use GitHub Secrets/Variables only.
2. Never use AWS root credentials. Never create permanent AWS access keys.
   Use the existing AWS CLI profile `devops` (region ap-south-1) locally only.
3. Never run `terraform apply` or `terraform destroy` without the user's explicit approval
   in that turn. Other Terraform commands only when the user asks.
4. Never create AWS resources, deploy, or start work outside the approved phase.
5. Never delete GitHub Actions runs (failed runs are graded evidence).
6. Never push directly to `main`; use feature branches + PRs with meaningful commit messages.
7. Run a secret scan (gitleaks) before each commit/push. Never use `--no-verify`.
8. Do not fabricate screenshots, logs or evidence. Mark evidence as pending until real.
9. Copilot prompts/modifications (Part H) must be the user's real ones; never invent them.
10. Keep mandatory requirements (from the .docx) separate from our recommendations in all docs.
11. The owner decided (2026-11-23) on a public live URL (HTTP 80); the instructor has not confirmed it. Still do not write any server IP, DNS name
    or URL into any repository file (or screenshot) until the owner approves it after a real deployment.
12. Do not open SSH (port 22) at all: the current design has no inbound SSH rule and deploys through OIDC and Systems Manager
   (infra/lab/README.md, docs/LAB_DEPLOYMENT.md). Do not reintroduce SSH names or keys; a CI check fails if they reappear.

## Workflow
- Work phase by phase (see PROJECT_STATUS.md). Show a plan and get approval before each phase.
- After each phase: update PROJECT_STATUS.md and docs/REQUIREMENTS_CHECKLIST.md.
- Every requirement row needs: status, validation method, evidence location, related commit/run.
  Never mark a row done without real evidence.
- Record manual actions the user performs (AWS console, GitHub settings) in PROJECT_STATUS.md.

## Repository layout (planned)
.github/workflows/ ci.yml, cd.yml, rollback.yml | frontend/ | backend/ | deploy/ (scripts, nginx,
compose) | infra/lab/ (current) | infra/terraform/ (earlier design, reference) | config/ (non-secret, *.example only) | docs/ (screenshots, evidence,
failures, ARCHITECTURE.md, REQUIREMENTS_CHECKLIST.md) | assignment/

## Conventions
- Commits: Conventional style, e.g. `ci: add backend node version matrix`.
- Branches: `feature/*`, `fix/*`, `docs/*`; PR into `main`; CI must pass.
- Third-party actions pinned to a version or commit SHA; explicit `permissions:` per workflow.
- Config per environment in separate files/GitHub Environments (staging, production).
- Commands (filled in once code exists): lint / test / build / compose — TBD.

## Open items
See PROJECT_STATUS.md "Open questions".
