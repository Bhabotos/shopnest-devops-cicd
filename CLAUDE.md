# CLAUDE.md — ShopNest DevOps CI/CD

Guidance for Claude Code in this repository. Source of truth for requirements:
`assignment/GITHUB ACTIONS.docx` (Parts A–I, 100 marks). Do not invent requirements.

## Project
Automated CI/CD for ShopNest's three-tier app using GitHub Actions.
- Presentation: React + Vite, served by Nginx
- Application: Node.js + Express REST API
- Data: PostgreSQL (Docker, internal network only)
- Infra: one AWS EC2 instance, ap-south-1, provisioned with Terraform (our choice, not mandated)
- Deploy: Docker + Docker Compose, Nginx reverse proxy, blue-green, health checks, auto rollback
- Runtime matrix: Node.js 20 and 22 (never 18)

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
11. Live URL is PENDING instructor clarification: do not write any server IP, DNS name or URL
    into any repository file until the user says it is resolved.
12. Do not expose SSH (port 22) unnecessarily; follow the SSH strategy in docs/ARCHITECTURE.md.

## Workflow
- Work phase by phase (see PROJECT_STATUS.md). Show a plan and get approval before each phase.
- After each phase: update PROJECT_STATUS.md and docs/REQUIREMENTS_CHECKLIST.md.
- Every requirement row needs: status, validation method, evidence location, related commit/run.
  Never mark a row done without real evidence.
- Record manual actions the user performs (AWS console, GitHub settings) in PROJECT_STATUS.md.

## Repository layout (planned)
.github/workflows/ ci.yml, cd.yml, rollback.yml | frontend/ | backend/ | deploy/ (scripts, nginx,
compose) | infra/terraform/ | config/ (non-secret, *.example only) | docs/ (screenshots, evidence,
failures, ARCHITECTURE.md, REQUIREMENTS_CHECKLIST.md) | assignment/

## Conventions
- Commits: Conventional style, e.g. `ci: add backend node version matrix`.
- Branches: `feature/*`, `fix/*`, `docs/*`; PR into `main`; CI must pass.
- Third-party actions pinned to a version or commit SHA; explicit `permissions:` per workflow.
- Config per environment in separate files/GitHub Environments (staging, production).
- Commands (filled in once code exists): lint / test / build / compose — TBD.

## Open items
See PROJECT_STATUS.md "Open questions".
