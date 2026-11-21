import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

describe('loadConfig', () => {
  it('applies defaults when the environment is empty', () => {
    expect(loadConfig({})).toEqual({
      port: 3000,
      host: '0.0.0.0',
      databaseUrl: undefined,
      version: '0.1.0',
      commit: 'unknown',
      logLevel: 'info',
      shutdownTimeoutMs: 10000,
      db: { poolMax: 10, connectionTimeoutMs: 5000, statementTimeoutMs: 10000 },
    });
  });

  it('reads values from the environment', () => {
    const config = loadConfig({
      PORT: '4000',
      DATABASE_URL: 'postgres://example/db',
      APP_VERSION: '1.2.3',
      GIT_SHA: 'abc123',
    });
    expect(config).toMatchObject({
      port: 4000,
      databaseUrl: 'postgres://example/db',
      version: '1.2.3',
      commit: 'abc123',
    });
  });

  it('falls back to the default for a non-numeric port', () => {
    expect(loadConfig({ PORT: 'abc' }).port).toBe(3000);
  });

  // The database pool and timeout limits come from environment variables, as numbers.
  it('reads the DB_* pool and timeout variables', () => {
    const { db } = loadConfig({
      DB_POOL_MAX: '25',
      DB_CONNECTION_TIMEOUT_MS: '2000',
      DB_STATEMENT_TIMEOUT_MS: '7500',
    });
    expect(db).toEqual({ poolMax: 25, connectionTimeoutMs: 2000, statementTimeoutMs: 7500 });
  });

  it('falls back to the defaults for non-numeric DB_* values', () => {
    const { db } = loadConfig({
      DB_POOL_MAX: 'many',
      DB_CONNECTION_TIMEOUT_MS: 'fast',
      DB_STATEMENT_TIMEOUT_MS: '',
    });
    expect(db).toEqual({ poolMax: 10, connectionTimeoutMs: 5000, statementTimeoutMs: 10000 });
  });
});
