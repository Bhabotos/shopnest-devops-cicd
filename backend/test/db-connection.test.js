import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createDb } from '../src/db.js';
import { DbConfigError, resolveDbConnection } from '../src/db-connection.js';

// The AWS SDK is mocked: no test here (or anywhere in the suite) calls AWS. The mock replaces the module the
// resolver imports lazily, so the default secret reader is exercised without a network or credentials.
const sdk = vi.hoisted(() => ({ send: vi.fn(), destroy: vi.fn(), clientConfig: undefined, command: undefined }));
vi.mock('@aws-sdk/client-secrets-manager', () => ({
  SecretsManagerClient: class {
    constructor(config) {
      sdk.clientConfig = config;
    }
    send(command) {
      return sdk.send(command);
    }
    destroy() {
      sdk.destroy();
    }
  },
  GetSecretValueCommand: class {
    constructor(input) {
      this.input = input;
    }
  },
}));

const CA_PEM = '-----BEGIN CERTIFICATE-----\nfake-ca-for-tests\n-----END CERTIFICATE-----\n';
// Generated per run, never a literal: a hard-coded password-looking string would (rightly) trip the secret scanner.
const PASSWORD = randomBytes(12).toString('hex');

const rdsEnv = (extra = {}) => ({
  DB_HOST: 'db.example.internal',
  DB_NAME: 'shopnest',
  DB_SECRET_ID: 'shopnest/staging/db-app',
  DB_OWNER_SECRET_ID: 'shopnest/staging/db-owner',
  AWS_REGION: 'ap-south-1',
  DB_SSL_CA_FILE: '/etc/ssl/rds/global-bundle.pem',
  ...extra,
});

const secretJson = (username = 'shopnest_app', password = PASSWORD) => JSON.stringify({ username, password });

function deps(overrides = {}) {
  return {
    getSecret: vi.fn(async () => secretJson()),
    readCaFile: vi.fn(async () => CA_PEM),
    ...overrides,
  };
}

describe('resolveDbConnection: DATABASE_URL mode (local development, tests, CI)', () => {
  it('returns the connection string and never touches Secrets Manager or the CA file', async () => {
    const d = deps();
    const result = await resolveDbConnection({ env: { DATABASE_URL: 'postgres://u:p@localhost/db' }, ...d });

    expect(result).toBe('postgres://u:p@localhost/db');
    expect(d.getSecret).not.toHaveBeenCalled();
    expect(d.readCaFile).not.toHaveBeenCalled();
  });

  it('ignores an AWS_REGION or DB_NAME that happens to be set on a developer machine', async () => {
    const result = await resolveDbConnection({
      env: { DATABASE_URL: 'postgres://u:p@localhost/db', AWS_REGION: 'ap-south-1', DB_NAME: 'x', DB_PORT: '5432' },
      ...deps(),
    });
    expect(result).toBe('postgres://u:p@localhost/db');
  });

  it('refuses to start when nothing is configured, with the established message', async () => {
    await expect(resolveDbConnection({ env: {}, ...deps() })).rejects.toThrow('DATABASE_URL is not set');
  });

  it('refuses an ambiguous configuration: DATABASE_URL together with an RDS setting', async () => {
    const promise = resolveDbConnection({ env: { DATABASE_URL: 'postgres://u:p@localhost/db', DB_HOST: 'h' }, ...deps() });
    await expect(promise).rejects.toBeInstanceOf(DbConfigError);
    await expect(promise).rejects.toThrow(/either DATABASE_URL or the RDS settings.*DB_HOST/);
  });
});

describe('resolveDbConnection: RDS mode', () => {
  it('builds a verified-TLS connection object for the API role from the secret', async () => {
    const d = deps();
    const result = await resolveDbConnection({ env: rdsEnv(), role: 'app', ...d });

    expect(result).toEqual({
      host: 'db.example.internal',
      port: 5432,
      database: 'shopnest',
      user: 'shopnest_app',
      password: PASSWORD,
      ssl: { ca: CA_PEM, rejectUnauthorized: true, minVersion: 'TLSv1.2' },
    });
    expect(d.getSecret).toHaveBeenCalledWith('shopnest/staging/db-app', 'ap-south-1');
    expect(d.readCaFile).toHaveBeenCalledWith('/etc/ssl/rds/global-bundle.pem');
  });

  it('defaults the role to the API role', async () => {
    const d = deps();
    await resolveDbConnection({ env: rdsEnv(), ...d });
    expect(d.getSecret).toHaveBeenCalledWith('shopnest/staging/db-app', 'ap-south-1');
  });

  it('uses the owner secret for migrations and seeding', async () => {
    const d = deps({ getSecret: vi.fn(async () => secretJson('shopnest_owner')) });
    const result = await resolveDbConnection({ env: rdsEnv(), role: 'owner', ...d });

    expect(d.getSecret).toHaveBeenCalledWith('shopnest/staging/db-owner', 'ap-south-1');
    expect(result.user).toBe('shopnest_owner');
  });

  it('never verifies less than the full certificate chain and host name', async () => {
    const { ssl } = await resolveDbConnection({ env: rdsEnv(), ...deps() });
    expect(ssl.rejectUnauthorized).toBe(true);
    expect(ssl.ca).toBe(CA_PEM);
    expect(ssl.minVersion).toBe('TLSv1.2');
  });

  it('reads a custom port, and rejects a malformed one', async () => {
    const custom = await resolveDbConnection({ env: rdsEnv({ DB_PORT: '6543' }), ...deps() });
    expect(custom.port).toBe(6543);

    for (const bad of ['abc', '0', '65536', '5432x', '-1', '1e3']) {
      await expect(resolveDbConnection({ env: rdsEnv({ DB_PORT: bad }), ...deps() })).rejects.toThrow('DB_PORT');
    }
  });

  it('lists every missing setting (for the API role)', async () => {
    const promise = resolveDbConnection({ env: { DB_HOST: 'h' }, ...deps() });
    await expect(promise).rejects.toThrow(/missing database settings: DB_NAME, DB_SECRET_ID, AWS_REGION, DB_SSL_CA_FILE/);
  });

  it('needs the owner secret id only for the owner role', async () => {
    const env = rdsEnv();
    delete env.DB_OWNER_SECRET_ID;

    await expect(resolveDbConnection({ env, role: 'app', ...deps() })).resolves.toMatchObject({ user: 'shopnest_app' });
    await expect(resolveDbConnection({ env, role: 'owner', ...deps() })).rejects.toThrow(/DB_OWNER_SECRET_ID/);
  });

  it('uses the master secret only for the master role (the CodeBuild bootstrap job)', async () => {
    const env = rdsEnv({ DB_MASTER_SECRET_ID: 'rds!db-example-master' });
    const d = deps({ getSecret: vi.fn(async () => secretJson('shopnest_admin')) });
    const result = await resolveDbConnection({ env, role: 'master', ...d });

    expect(d.getSecret).toHaveBeenCalledWith('rds!db-example-master', 'ap-south-1');
    expect(result.user).toBe('shopnest_admin');
    expect(result.ssl.rejectUnauthorized).toBe(true);
  });

  it('refuses the master role without its secret id, and never falls back to another secret', async () => {
    const d = deps();
    await expect(resolveDbConnection({ env: rdsEnv(), role: 'master', ...d })).rejects.toThrow(/DB_MASTER_SECRET_ID/);
    expect(d.getSecret).not.toHaveBeenCalled();
  });

  it('the app role never reads the master or owner secret, even when their ids are set', async () => {
    const d = deps();
    await resolveDbConnection({ env: rdsEnv({ DB_MASTER_SECRET_ID: 'rds!db-example-master' }), role: 'app', ...d });
    expect(d.getSecret).toHaveBeenCalledTimes(1);
    expect(d.getSecret).toHaveBeenCalledWith('shopnest/staging/db-app', 'ap-south-1');
  });

  it('rejects an unknown role', async () => {
    await expect(resolveDbConnection({ env: rdsEnv(), role: 'admin', ...deps() })).rejects.toThrow('role must be');
  });
});

describe('resolveDbConnection: fail closed', () => {
  it('does not connect without a CA bundle, and does not even read the secret', async () => {
    const d = deps({
      readCaFile: vi.fn(async () => {
        throw new Error('ENOENT');
      }),
    });
    await expect(resolveDbConnection({ env: rdsEnv(), ...d })).rejects.toThrow(/cannot read the CA bundle/);
    expect(d.getSecret).not.toHaveBeenCalled();
  });

  it('rejects an empty CA bundle', async () => {
    const d = deps({ readCaFile: vi.fn(async () => '') });
    await expect(resolveDbConnection({ env: rdsEnv(), ...d })).rejects.toThrow(/CA bundle.*empty/);
  });

  it('reports a failed secret read by error name, without the SDK message', async () => {
    const failure = Object.assign(new Error(`not allowed to read ${PASSWORD}`), { name: 'AccessDeniedException' });
    const d = deps({ getSecret: vi.fn(async () => Promise.reject(failure)) });

    const error = await resolveDbConnection({ env: rdsEnv(), ...d }).catch((e) => e);
    expect(error).toBeInstanceOf(DbConfigError);
    expect(error.message).toContain('shopnest/staging/db-app');
    expect(error.message).toContain('AccessDeniedException');
    expect(error.message).not.toContain(PASSWORD);
  });

  it('never echoes secret text that is not valid JSON', async () => {
    const d = deps({ getSecret: vi.fn(async () => `username=shopnest_app password=${PASSWORD}`) });
    const error = await resolveDbConnection({ env: rdsEnv(), ...d }).catch((e) => e);

    expect(error.message).toMatch(/not valid JSON/);
    expect(error.message).not.toContain(PASSWORD);
  });

  it.each([
    ['no password', JSON.stringify({ username: 'u' })],
    ['no username', JSON.stringify({ password: 'p' })],
    ['an empty password', JSON.stringify({ username: 'u', password: '' })],
    ['a numeric password', JSON.stringify({ username: 'u', password: 12345 })],
    ['JSON null', 'null'],
  ])('rejects a secret with %s', async (_label, value) => {
    const d = deps({ getSecret: vi.fn(async () => value) });
    await expect(resolveDbConnection({ env: rdsEnv(), ...d })).rejects.toThrow(/non-empty "username" and "password"|not valid JSON/);
  });

  it.each([[undefined], [''], [Buffer.from('binary')]])('rejects a secret without a string value (%s)', async (value) => {
    const d = deps({ getSecret: vi.fn(async () => value) });
    await expect(resolveDbConnection({ env: rdsEnv(), ...d })).rejects.toThrow(/no string value/);
  });
});

describe('default secret reader (AWS SDK mocked)', () => {
  beforeEach(() => {
    sdk.send.mockReset();
    sdk.destroy.mockReset();
    sdk.clientConfig = undefined;
  });

  it('asks Secrets Manager for the named secret in the configured region and releases the client', async () => {
    sdk.send.mockResolvedValue({ SecretString: secretJson() });

    const result = await resolveDbConnection({ env: rdsEnv(), readCaFile: async () => CA_PEM });

    expect(result).toMatchObject({ user: 'shopnest_app', password: PASSWORD });
    expect(sdk.clientConfig).toEqual({ region: 'ap-south-1' });
    expect(sdk.send).toHaveBeenCalledTimes(1);
    expect(sdk.send.mock.calls[0][0].input).toEqual({ SecretId: 'shopnest/staging/db-app' });
    expect(sdk.destroy).toHaveBeenCalledTimes(1);
  });

  it('releases the client even when the call fails', async () => {
    sdk.send.mockRejectedValue(Object.assign(new Error('boom'), { name: 'ResourceNotFoundException' }));

    await expect(resolveDbConnection({ env: rdsEnv(), readCaFile: async () => CA_PEM })).rejects.toThrow(
      /ResourceNotFoundException/,
    );
    expect(sdk.destroy).toHaveBeenCalledTimes(1);
  });

  it('is not used at all in DATABASE_URL mode', async () => {
    await resolveDbConnection({ env: { DATABASE_URL: 'postgres://u:p@localhost/db' } });
    expect(sdk.send).not.toHaveBeenCalled();
    expect(sdk.clientConfig).toBeUndefined();
  });
});

describe('createDb with a connection object', () => {
  it('accepts the object that resolveDbConnection returns (no connection is opened until a query)', async () => {
    const connection = await resolveDbConnection({ env: rdsEnv(), ...deps() });
    const db = createDb(connection, { logger: { error: () => {} } });
    await expect(db.close()).resolves.not.toThrow();
  });
});

describe('scripts and the server entry point (child processes, nothing connects)', () => {
  const backendDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');

  function run(script, extraEnv) {
    const env = { PATH: process.env.PATH, ...extraEnv };
    if (process.env.SystemRoot) env.SystemRoot = process.env.SystemRoot; // required by Node on Windows
    return spawnSync(process.execPath, [script], { cwd: backendDir, env, encoding: 'utf8', timeout: 15000 });
  }

  it('migrate.js refuses to start without any database setting', () => {
    const result = run('scripts/migrate.js', {});
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('DATABASE_URL is not set');
  });

  it('migrate.js refuses an ambiguous configuration', () => {
    const result = run('scripts/migrate.js', { DATABASE_URL: 'postgres://u:p@127.0.0.1:9/x_test', DB_HOST: 'h' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('either DATABASE_URL or the RDS settings');
  });

  it('migrate.js in RDS mode refuses to continue without the CA file, before any secret is read', () => {
    const result = run('scripts/migrate.js', {
      ...rdsEnv({ DB_SSL_CA_FILE: resolve(backendDir, 'does-not-exist.pem') }),
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('cannot read the CA bundle');
    expect(result.stderr).not.toMatch(/Secrets Manager|credentials/i);
  });

  it('server.js refuses to start in RDS mode without the CA file and logs no secret', () => {
    const result = run('src/server.js', {
      ...rdsEnv({ DB_SSL_CA_FILE: resolve(backendDir, 'does-not-exist.pem') }),
    });
    expect(result.status).toBe(1);
    expect(result.stdout + result.stderr).toContain('database configuration error');
    expect(result.stdout + result.stderr).toContain('cannot read the CA bundle');
  });
});
