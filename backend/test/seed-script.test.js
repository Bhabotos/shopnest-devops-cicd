import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

// These tests run the real executable, `node scripts/seed.js`, in a child process, so they check the
// path the guard really takes when nobody passes it an argument: it reads the child's own environment.
// The target is a closed local port that is not a database (127.0.0.1:9, name ending in _test), and the
// guard must refuse before any connection is attempted, so nothing is ever written anywhere.

const backendDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DATABASE_URL = 'postgres://u:p@127.0.0.1:9/none_test';

// Runs the seed script with exactly the environment given (plus what Node needs to start), never the
// environment of the test runner, so a NODE_ENV or DATABASE_URL on this machine cannot leak in.
function runSeedScript(extraEnv) {
  const env = { PATH: process.env.PATH, ...extraEnv };
  if (process.env.SystemRoot) env.SystemRoot = process.env.SystemRoot; // required by Node on Windows
  return spawnSync(process.execPath, ['scripts/seed.js'], {
    cwd: backendDir,
    env,
    encoding: 'utf8',
    timeout: 15000,
  });
}

describe('scripts/seed.js (child process)', () => {
  it('refuses to run in production before touching the database', () => {
    const result = runSeedScript({ DATABASE_URL, NODE_ENV: 'production' });

    expect(result.error).toBeUndefined(); // the child started and was not killed by the timeout
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('Refusing to seed');
    // A refusal happens before any connection attempt, so there is no connection error and no success line.
    expect(result.stderr).not.toMatch(/ECONNREFUSED|ETIMEDOUT|connect/i);
    expect(result.stdout).not.toContain('seed complete');
  });

  it('refuses to run when NODE_ENV is not set', () => {
    const result = runSeedScript({ DATABASE_URL });

    expect(result.error).toBeUndefined();
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('Refusing to seed');
    expect(result.stderr).toContain('NODE_ENV is "unset"');
    expect(result.stdout).not.toContain('seed complete');
  });

  it('refuses staging even when the production flag is set', () => {
    const result = runSeedScript({ DATABASE_URL, NODE_ENV: 'staging', ALLOW_PRODUCTION_SEED: 'true' });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain('Refusing to seed');
  });

  // Control: proves the two refusals above come from the guard reading the child's environment, not from
  // the script always failing. In development the guard lets it through, so the script goes on to try the
  // closed port and fails there (a connection error), without ever printing the refusal.
  it('does not refuse in development, so the refusals above come from the guard', () => {
    const result = runSeedScript({ DATABASE_URL, NODE_ENV: 'development' });

    expect(result.error).toBeUndefined();
    expect(result.stderr).not.toContain('Refusing to seed');
    expect(result.stdout).not.toContain('seed complete'); // nothing is listening on the port, so no seeding
  });
});
