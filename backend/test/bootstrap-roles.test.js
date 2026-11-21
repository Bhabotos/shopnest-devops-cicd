import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { APP_ROLE, bootstrapRoles, BootstrapError, OWNER_ROLE, validateRoleCredentials } from '../src/bootstrap-roles.js';
import { MIGRATION_LOCK_KEY } from '../src/migrate.js';

// Generated per run: a hard-coded password-like literal would trip the secret scanner.
const strong = () => randomBytes(16).toString('hex');
const OWNER_PW = strong();
const APP_PW = strong();

// A fake master connection: it records every query and lets a test decide what the server answers. The statements the
// SERVER builds with format() are represented by a marker, which is why no password can appear in this program's SQL.
function fakeClient({ existingRoles = [], schemaOwner = 'pg_database_owner', failAt } = {}) {
  const queries = [];
  const client = {
    queries,
    async query(text, params = []) {
      queries.push({ text, params });
      if (failAt && text.includes(failAt)) throw new Error('permission denied');
      if (text.startsWith('SELECT 1 FROM pg_roles')) return { rows: existingRoles.includes(params[0]) ? [{ '?column?': 1 }] : [] };
      if (text.startsWith('SELECT format(')) return { rows: [{ statement: '<statement built by the server>' }] };
      if (text.includes('nspowner::regrole')) return { rows: [{ needed: schemaOwner !== 'pg_database_owner' }] };
      if (text.includes('FROM pg_roles WHERE rolname = ANY')) {
        return { rows: [{ rolname: APP_ROLE, rolsuper: false, rolcreatedb: false, rolcreaterole: false, rolcanlogin: true }] };
      }
      if (text.includes('pg_get_userbyid')) return { rows: [{ owner: OWNER_ROLE }] };
      return { rows: [] };
    },
  };
  return client;
}
const texts = (client) => client.queries.map((q) => q.text);

describe('validateRoleCredentials', () => {
  const ok = { owner: { username: OWNER_ROLE, password: OWNER_PW }, app: { username: APP_ROLE, password: APP_PW } };

  it('accepts two correct credentials', () => {
    expect(() => validateRoleCredentials(ok.owner, ok.app)).not.toThrow();
  });

  it.each([
    ['the owner user name is wrong', { owner: { ...ok.owner, username: 'postgres' } }, /owner secret must have username/],
    ['the app user name is wrong', { app: { ...ok.app, username: 'shopnest_owner' } }, /app secret must have username/],
    ['the owner password is short', { owner: { ...ok.owner, password: 'short1' } }, /owner password must be 24/],
    ['the app password has symbols', { app: { ...ok.app, password: `${APP_PW}!!` } }, /app password must be 24/],
    ['the passwords are identical', { app: { ...ok.app, password: OWNER_PW } }, /must differ/],
  ])('refuses when %s', (_label, change, message) => {
    const input = { ...ok, ...change };
    expect(() => validateRoleCredentials(input.owner, input.app)).toThrow(message);
    expect(() => validateRoleCredentials(input.owner, input.app)).toThrow(BootstrapError);
  });

  it('never puts a password in an error message', () => {
    try {
      validateRoleCredentials({ username: OWNER_ROLE, password: 'short1' }, { username: APP_ROLE, password: APP_PW });
    } catch (err) {
      expect(err.message).not.toContain(APP_PW);
      expect(err.message).not.toContain('short1');
    }
  });
});

describe('bootstrapRoles', () => {
  it('runs in one transaction, under the same advisory lock as the migrations', async () => {
    const client = fakeClient();
    await bootstrapRoles(client, { ownerPassword: OWNER_PW, appPassword: APP_PW });

    expect(texts(client)[0]).toBe('BEGIN');
    expect(client.queries[1]).toEqual({ text: 'SELECT pg_advisory_xact_lock($1)', params: [MIGRATION_LOCK_KEY] });
    expect(texts(client).at(-1)).toBe('COMMIT');
    expect(texts(client)).not.toContain('ROLLBACK');
  });

  it('never puts a password into SQL text: it is only ever a bound parameter', async () => {
    const client = fakeClient();
    await bootstrapRoles(client, { ownerPassword: OWNER_PW, appPassword: APP_PW });

    for (const text of texts(client)) {
      expect(text).not.toContain(OWNER_PW);
      expect(text).not.toContain(APP_PW);
    }
    const withPassword = client.queries.filter((q) => q.params.includes(OWNER_PW) || q.params.includes(APP_PW));
    expect(withPassword).toHaveLength(2);
    for (const q of withPassword) expect(q.text).toMatch(/format\(.*PASSWORD %L/s);
  });

  it('creates missing roles and re-synchronises existing ones (idempotent)', async () => {
    const fresh = fakeClient();
    await bootstrapRoles(fresh, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    expect(texts(fresh).filter((t) => t.includes("'CREATE ROLE %I"))).toHaveLength(2);
    expect(texts(fresh).filter((t) => t.includes('ALTER ROLE'))).toHaveLength(0);

    const again = fakeClient({ existingRoles: [OWNER_ROLE, APP_ROLE] });
    await bootstrapRoles(again, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    expect(texts(again).filter((t) => t.includes("'ALTER ROLE %I WITH"))).toHaveLength(2);
    expect(texts(again).filter((t) => t.includes('CREATE ROLE'))).toHaveLength(0);
  });

  it('creates neither role as a superuser, and the roles cannot create databases or roles', async () => {
    const client = fakeClient();
    await bootstrapRoles(client, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    for (const text of texts(client).filter((t) => /CREATE ROLE|ALTER ROLE/.test(t))) {
      expect(text).toContain('NOSUPERUSER NOCREATEDB NOCREATEROLE');
    }
  });

  it('gives the master a temporary membership and removes it again before committing', async () => {
    const client = fakeClient();
    await bootstrapRoles(client, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    const t = texts(client);
    const grant = t.findIndex((x) => x.startsWith('GRANT shopnest_owner TO CURRENT_USER'));
    const handOver = t.findIndex((x) => x.includes('ALTER DATABASE %I OWNER TO'));
    const revoke = t.findIndex((x) => x === 'REVOKE shopnest_owner FROM CURRENT_USER');
    expect(grant).toBeGreaterThan(-1);
    expect(handOver).toBeGreaterThan(grant);
    expect(revoke).toBeGreaterThan(handOver);
    expect(t.indexOf('COMMIT')).toBeGreaterThan(revoke);
  });

  it('closes the database to PUBLIC and opens it to the two roles only', async () => {
    const client = fakeClient();
    await bootstrapRoles(client, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    const t = texts(client).join('\n');
    expect(t).toContain('REVOKE ALL ON DATABASE %I FROM PUBLIC');
    expect(t).toContain('GRANT CONNECT ON DATABASE %I TO shopnest_owner, shopnest_app');
    expect(t).toContain('REVOKE CREATE ON SCHEMA public FROM PUBLIC');
  });

  it('changes the public schema owner only when it is not already pg_database_owner', async () => {
    const standard = fakeClient({ schemaOwner: 'pg_database_owner' });
    await bootstrapRoles(standard, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    expect(texts(standard)).not.toContain('ALTER SCHEMA public OWNER TO shopnest_owner');

    const custom = fakeClient({ schemaOwner: 'someone_else' });
    await bootstrapRoles(custom, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    expect(texts(custom)).toContain('ALTER SCHEMA public OWNER TO shopnest_owner');
  });

  it('rolls everything back when any statement is refused, and reports the refusal', async () => {
    const client = fakeClient({ failAt: 'GRANT shopnest_owner' });
    await expect(bootstrapRoles(client, { ownerPassword: OWNER_PW, appPassword: APP_PW })).rejects.toThrow('permission denied');
    expect(texts(client).at(-1)).toBe('ROLLBACK');
    expect(texts(client)).not.toContain('COMMIT');
  });

  it('returns attributes only: no secret value is in the report', async () => {
    const client = fakeClient();
    const report = await bootstrapRoles(client, { ownerPassword: OWNER_PW, appPassword: APP_PW });
    const printed = JSON.stringify(report);
    expect(printed).not.toContain(OWNER_PW);
    expect(printed).not.toContain(APP_PW);
    expect(report.databaseOwner).toBe(OWNER_ROLE);
  });
});

describe('scripts/bootstrap-roles.js (child process, nothing connects)', () => {
  const backendDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  function run(extraEnv) {
    const env = { PATH: process.env.PATH, ...extraEnv };
    if (process.env.SystemRoot) env.SystemRoot = process.env.SystemRoot; // required by Node on Windows
    return spawnSync(process.execPath, ['scripts/bootstrap-roles.js'], { cwd: backendDir, env, encoding: 'utf8', timeout: 15000 });
  }

  it('refuses to run outside CodeBuild', () => {
    const result = run({ BOOTSTRAP_ENVIRONMENT: 'staging', BOOTSTRAP_CONFIRM: 'bootstrap-staging' });
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('runs only inside the CodeBuild bootstrap project');
  });

  it('refuses without the operator confirmation', () => {
    const result = run({ CODEBUILD_BUILD_ID: 'x:1', BOOTSTRAP_ENVIRONMENT: 'staging' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('BOOTSTRAP_CONFIRM=bootstrap-staging');
  });

  it('refuses a confirmation for a different environment', () => {
    const result = run({ CODEBUILD_BUILD_ID: 'x:1', BOOTSTRAP_ENVIRONMENT: 'staging', BOOTSTRAP_CONFIRM: 'bootstrap-production' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('BOOTSTRAP_CONFIRM=bootstrap-staging');
  });

  it('refuses without the environment name', () => {
    const result = run({ CODEBUILD_BUILD_ID: 'x:1' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('BOOTSTRAP_ENVIRONMENT is not set');
  });

  it('refuses when a secret id is missing, before reading or connecting to anything', () => {
    const result = run({ CODEBUILD_BUILD_ID: 'x:1', BOOTSTRAP_ENVIRONMENT: 'staging', BOOTSTRAP_CONFIRM: 'bootstrap-staging' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('DB_SECRET_ID is not set');
  });
});
