# Integration gap report: deployment code vs the final infrastructure design

Design: private RDS, Systems Manager access, ECR delivery, AWS SDK secret retrieval, NAT Gateway, staging 1 instance / production 2 instances.
Scope: **future changes only.** Nothing in `deploy/`, `.github/workflows/`, `backend/` or `docs/` was modified. The existing Docker Compose
deployment does **not** automatically support any of this. Verified by reading the files on `main` (commit `9277270`).
**Must** = deployment cannot work without it. **Should** = works but unsafe or unmaintainable without it.

## 1. SSM instead of SSH (Must)
| Where | Today | Required change |
|---|---|---|
| `.github/workflows/cd.yml` (both deploy jobs) and `rollback.yml` | OIDC role, then a port-22 security-group rule for the runner, `ssh`/`scp` with `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `EC2_HOST`, `EC2_USER`, then revoke | Delete the "Open SSH", "Prepare SSH" and "Close SSH" steps and those secrets. Use `aws ssm send-command` against the instance IDs from `terraform output instance_ids`, wait for completion, and map the command's `ResponseCode` to the existing exit codes (0 ok, 1 failed with previous release serving, 3 failed and recovery failed) |
| ci.yml check "rollback.yml keeps the same SSH steps as cd.yml" | diffs the SSH steps | Delete: there will be no SSH steps |
| OIDC deploy role (not created) | designed for `ec2:AuthorizeSecurityGroupIngress` | Redesign: `ssm:SendCommand` on these instances and one document, `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation`, plus ECR push for CI (README section 7). Capture the real OIDC `sub` claim first (`docs/OIDC_DESIGN.md`, item 2a) |
| `docs/ARCHITECTURE.md` (SSH strategy), `docs/OIDC_DESIGN.md` (SSH sweeper, EventBridge) | describe the per-run rule and its cleanup | Replace; the sweeper becomes unnecessary |
| Part E wording | "deployment over SSH" | Confirm with the instructor that SSM Run Command satisfies it |

## 2. Delivery through ECR (Must)
| Where | Today | Required change |
|---|---|---|
| `cd.yml` "Package release" job | `docker build` then `docker save | gzip` into a bundle uploaded with `scp`; checksum file `SHA256SUMS` | Build, then `docker push` to `shopnest/<environment>/backend` with an immutable tag (the commit SHA); record the **digest**. Authenticate CI through the OIDC role (ECR push permissions). Drop `docker save`/`docker load` |
| `deploy/scripts/bluegreen-deploy.sh` | verifies `RELEASE_SHA` and `SHA256SUMS`, then `docker load` and checks the image label | Replace with `aws ecr get-login-password | docker login`, `docker pull <repo>@<digest>`, and verify the pulled digest and the revision label. The scripts and compose file themselves still need to reach the instance (see below) |
| Delivery of `deploy/` scripts, nginx config and frontend files | travel inside the uploaded bundle | **Decided (Phase 4.2): a private, encrypted, versioned S3 artifact bucket per environment** (`artifacts.tf`; the instance role reads one prefix, read-only). Defined only: nothing is uploaded and no workflow or script uses it yet. Phase 4.3 must add the publisher identity (CI/deploy role, `PutObject` on that prefix), the upload step, integrity verification (checksums or digests) and the instance-side fetch |
| Promotion staging to production | the same bundle was assumed to go to both | Copy the manifest from the staging repository to production's (digest preserved) rather than rebuilding |
| Rollback | uses the image and frontend files kept on the host | Rollback targets must still exist in ECR: the lifecycle keeps only the newest `ecr_keep_images` images (30 staging, 50 production). Record the digest of every deployed release |
| Instance role | none | Created: pull-only access to this environment's repositories. No keys on the host |

## 3. Backend connection to RDS (Must)
| Where | Today | Required change |
|---|---|---|
| `deploy/docker-compose.prod.yml` | a `db` service (`postgres:16.16`), `pgdata`, `db-init` mount, `depends_on: db`, `DATABASE_URL=...@db:5432/...` for backends, `migrate`, `seed` | Remove `db`, `pgdata`, `db-init`; no database URL with a password; pass `DB_HOST` (RDS private name), `DB_PORT`, `DB_NAME`, `DB_SECRET_ID`, `AWS_REGION` (all non-secret, from Terraform outputs) |
| `backend/src/db.js`, `config.js`, `scripts/migrate.js`, `scripts/seed.js` | read `DATABASE_URL`; `new pg.Pool({ connectionString })`; no TLS | Add the AWS SDK (Secrets Manager client), read the secret at start-up, build the pool from host/port/db/user/password, and enable TLS with the RDS CA bundle (`/opt/shopnest/rds-global-bundle.pem` on the host, mounted into the container; `rds.force_ssl` is on). Keep the local development path working without AWS (a code path for `DATABASE_URL`), and add tests that mock the SDK. The same applies to `migrate.js` and `seed.js` |
| `deploy/scripts/lib/bluegreen-lib.sh` `bg_db_up` | starts the `db` container and runs `pg_isready` in it | Replace with a reachability check of the RDS endpoint; the "never recreate the database" safeguard no longer applies |
| Offline suite `deploy/tests/bluegreen-logic.test.sh` and the CI compose check | assert `--no-recreate` for `db`, `db-init` mounts, and that `c.services.db` is on the internal network | Rewrite; the CI check will throw once `db` is removed |

## 4. Runtime secret retrieval with the SDK (Must)
- **Application:** add `@aws-sdk/client-secrets-manager`, retrieve `shopnest/<environment>/db-app` once at start (and decide how to handle rotation: re-read on
  an authentication error). Only the identifier is configuration.
- **Containers and the instance role:** IMDS hop limit is 2 so the container's SDK can reach the metadata service. Any container on the host can then
  read the instance role's credentials. Decide on mitigation: block metadata for non-backend containers (iptables on the Docker bridge), run the backend with host
  networking, or accept it given the small role. Document the choice.
- **Secrets:** created by an operator out-of-band: `shopnest/<environment>/db-app` and, if migrations run from the instance, `db-owner`
  (then add it to `db_secret_names`). The IAM policy names each secret explicitly; it is not a prefix wildcard.
- **`bluegreen-lib.sh`:** the `secrets.env` mode-600 check and the three-password regex (letters and digits, 16 or more) no longer apply on the instance; keep
  `BG_ALLOW_LOOSE_SECRETS` for local rehearsals only. The "no secret in any log" offline test must be extended to the new code.

## 5. Database bootstrap and migrations (Must)
- `deploy/db/init/01-roles.sh` runs only on an empty local Postgres directory. On RDS an operator must create the roles (`shopnest_owner`, `shopnest_app`),
  ownership and revokes once, using the **RDS master secret**. The master user is not a superuser (`rds_superuser`): verify each statement and migration
  `003_app_role_grants.sql` is permitted (for example `ALTER DATABASE ... OWNER TO` requires membership of the target role).
- Migrations run as `shopnest_owner`. Decide where: on the instance (needs `db-owner` readable by the role) or from a separate, more tightly scoped step.
- With two production instances, migrations must run **once**, before either instance gets the new release, and stay backward compatible with the release that
  is still serving (already the rule). The script's lock directory is per host, not per database: add a database advisory lock (deferred finding B6).
- Rollback does not roll back the schema; recovery is a point-in-time restore or a snapshot (new instance, new endpoint). Rehearse one on staging.

## 6. Two production instances (Must)
- The blue/green scripts assume one host with local state (`state/active`, `history.log`, `last_good`) and nginx switching on that host.
- Production needs a **rolling** deploy: update one instance, wait until the ALB reports it healthy, then the second. If the first fails, stop and keep the second
  on the old release. The workflow must drive this order through SSM, and `release-status` must be read per instance.
- The ALB deregistration delay (30 s) interacts with the scripts' own drain (10 s); check the sequence so no request lands on a stopping backend.
- Release state lives on each instance's disk; rebuilding an instance loses it. Decide whether to keep it in Parameter Store or derive it from ECR tags.
- Staging has one instance and can keep the current single-host flow.

## 7. Health checks (Should)
- The target group checks `/health` through nginx. `backend/src/app.js` answers it with `SELECT 1`, so a database outage, an RDS failover or a TLS or secret
  error makes **every** target unhealthy and the ALB returns 503 (it has no healthy target). Consider separate liveness and readiness endpoints.
- `bluegreen-lib.sh` readiness (`/health` and `/version` on the idle colour, then through nginx) still works; only its database wait changes.
- SSM Run Command has its own timeout; replace the job's SSH-rule-based timeout reasoning.

## 8. Rollback (Must)
- `rollback.yml` and `rollback.sh` use the same SSH path and `bg_db_up`; they need the same SSM, ECR and RDS changes, and exit codes 0, 1 and 3 must be
  carried back through SSM.
- A manual rollback to an older release needs that image still in ECR (lifecycle) and its digest recorded.
- For production the rollback must also be rolling (section 6).

## 9. Documentation and evidence (Should)
`CLAUDE.md` ("Data: PostgreSQL (Docker, internal network only)", "one AWS EC2 instance", the SSH rule), `docs/ARCHITECTURE.md`, `docs/OIDC_DESIGN.md`,
`docs/GITHUB_SETUP.md`, `PROJECT_STATUS.md` and the checklist (Parts E, F, G) describe the earlier design. The 2026-11-17 decision "staging and production
share the single instance" is superseded. The local rehearsals (attempts 1 to 5) are evidence for the Docker-Postgres design only and must not be presented as
evidence for RDS, SSM, ECR or two-instance behaviour.

## 10. Suggested order of work (each step needs its own approval)
1. Confirm interpretations (README "Open decisions"); decide the delivery of the `deploy/` scripts and the hop-limit mitigation.
2. After you re-authenticate: a real `terraform plan` for staging; review; approval to apply staging.
3. Operator bootstrap of the database roles and the `db-app` secret (no secret in any log).
4. Backend SDK and TLS change with tests; compose and scripts for RDS and ECR; offline tests.
5. SSM- and ECR-based `cd.yml` and `rollback.yml`, the OIDC role, GitHub Environments with reviewers; then `CD_ENABLED`.
6. Rehearse deploy, failed release, rollback and a database restore on staging; record real evidence.
7. Production (two instances, Multi-AZ RDS) with a rolling deploy rehearsal.
