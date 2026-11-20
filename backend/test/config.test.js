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
});
