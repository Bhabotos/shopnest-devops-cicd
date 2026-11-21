import { MIGRATION_LOCK_KEY } from './migrate.js';

// One-time, idempotent creation of the two application roles on the private RDS instance. It runs ONLY in the
// CodeBuild "bootstrap" job (see scripts/bootstrap-roles.js and docs/AWS_STAGING_INTEGRATION.md): that job is the one
// place that holds the RDS master credentials. The application container never has them, and neither does the EC2
// instance role or the GitHub deployment role.
//
// UNVERIFIED ON RDS: the master user is `rds_superuser`, not a real superuser. Whether every statement below is
// permitted (notably ALTER DATABASE ... OWNER TO, which needs the master to act as the new owner) is only provable
// against a real instance. The whole run is one transaction, so a refusal leaves nothing half-done.

export const OWNER_ROLE = 'shopnest_owner';
export const APP_ROLE = 'shopnest_app';

const PASSWORD_PATTERN = /^[A-Za-z0-9]{24,}$/;

export class BootstrapError extends Error {
  constructor(message) {
    super(message);
    this.name = 'BootstrapError';
  }
}

/**
 * Checks the two secrets BEFORE anything is changed. The messages never contain a password.
 * @param {{username: string, password: string}} owner
 * @param {{username: string, password: string}} app
 */
export function validateRoleCredentials(owner, app) {
  if (owner.username !== OWNER_ROLE) throw new BootstrapError(`the owner secret must have username ${OWNER_ROLE}`);
  if (app.username !== APP_ROLE) throw new BootstrapError(`the app secret must have username ${APP_ROLE}`);
  if (!PASSWORD_PATTERN.test(owner.password)) throw new BootstrapError('the owner password must be 24 or more letters and digits');
  if (!PASSWORD_PATTERN.test(app.password)) throw new BootstrapError('the app password must be 24 or more letters and digits');
  if (owner.password === app.password) throw new BootstrapError('the owner and app passwords must differ');
}

// A utility statement cannot take bind parameters, so the SERVER builds it: format() quotes identifiers (%I) and
// literals (%L). A password is passed to format() as a parameter and only ever appears inside the server-built text.
async function runBuilt(client, selectStatement, params = []) {
  const { rows } = await client.query(selectStatement, params);
  await client.query(rows[0].statement);
}

/**
 * @param {{query: (text: string, params?: unknown[]) => Promise<{rows: any[]}>}} client  a connection of the master user
 * @param {{ownerPassword: string, appPassword: string}} passwords
 * @returns {Promise<{roles: object[], databaseOwner: string}>}  attributes only, never a secret value
 */
export async function bootstrapRoles(client, { ownerPassword, appPassword }) {
  await client.query('BEGIN');
  try {
    // The same lock as the migrations: a bootstrap never runs while a migration does, or the other way round.
    await client.query('SELECT pg_advisory_xact_lock($1)', [MIGRATION_LOCK_KEY]);

    for (const [role, password] of [
      [OWNER_ROLE, ownerPassword],
      [APP_ROLE, appPassword],
    ]) {
      const existing = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [role]);
      const verb = existing.rows.length > 0 ? 'ALTER ROLE %I WITH' : 'CREATE ROLE %I';
      await runBuilt(
        client,
        `SELECT format('${verb} LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE', $1::text, $2::text) AS statement`,
        [role, password],
      );
    }

    // The master must be able to act as the new owner to hand the database over; the membership is removed at the end.
    await client.query(`GRANT ${OWNER_ROLE} TO CURRENT_USER WITH INHERIT TRUE, SET TRUE`);
    await runBuilt(client, `SELECT format('ALTER DATABASE %I OWNER TO ${OWNER_ROLE}', current_database()) AS statement`);

    // PostgreSQL 15 and later: the public schema belongs to pg_database_owner, which IS the database owner after the
    // statement above. Only a schema with some other owner needs an explicit change.
    const schema = await client.query(
      "SELECT nspowner::regrole::text <> 'pg_database_owner' AS needed FROM pg_namespace WHERE nspname = 'public'",
    );
    if (schema.rows[0]?.needed) await client.query(`ALTER SCHEMA public OWNER TO ${OWNER_ROLE}`);

    await runBuilt(client, "SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) AS statement");
    await runBuilt(
      client,
      `SELECT format('GRANT CONNECT ON DATABASE %I TO ${OWNER_ROLE}, ${APP_ROLE}', current_database()) AS statement`,
    );
    await client.query('REVOKE CREATE ON SCHEMA public FROM PUBLIC');
    await client.query(`REVOKE ${OWNER_ROLE} FROM CURRENT_USER`);

    const roles = await client.query(
      'SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolcanlogin FROM pg_roles WHERE rolname = ANY($1) ORDER BY rolname',
      [[OWNER_ROLE, APP_ROLE]],
    );
    const owner = await client.query('SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = current_database()');
    await client.query('COMMIT');
    return { roles: roles.rows, databaseOwner: owner.rows[0].owner };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  }
}
