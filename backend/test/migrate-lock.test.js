import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MIGRATION_LOCK_KEY, runMigrations } from '../src/migrate.js';

// Unit tests with a fake database: they check the ORDER of the calls and what happens on every failure path.
// A real PostgreSQL run is not needed for that (and none is available here); the existing integration test
// covers real migrations, and a concurrent-run check against a real server is listed in docs/AWS_STAGING_INTEGRATION.md.

function fakeDb({ lockResults = [true], failOn } = {}) {
  const events = [];
  const results = [...lockResults];
  const lockClient = {
    query: vi.fn(async (text) => {
      if (text.includes('pg_try_advisory_lock')) {
        events.push('try-lock');
        return { rows: [{ locked: results.length > 1 ? results.shift() : results[0] }] };
      }
      if (text.includes('pg_advisory_unlock')) {
        events.push('unlock');
        if (failOn === 'unlock') throw new Error('connection lost');
        return { rows: [] };
      }
      throw new Error(`unexpected lock-client query: ${text}`);
    }),
  };
  const db = {
    events,
    withClient: vi.fn(async (work, options) => {
      events.push('client-open');
      try {
        return await work(lockClient);
      } finally {
        events.push(options?.discard ? 'client-destroyed' : 'client-released');
      }
    }),
    query: vi.fn(async (text) => {
      if (text.includes('CREATE TABLE IF NOT EXISTS schema_migrations')) {
        events.push('create-table');
        return { rows: [] };
      }
      if (text.includes('SELECT name FROM schema_migrations')) {
        events.push('read-applied');
        return { rows: [] };
      }
      throw new Error(`unexpected query: ${text}`);
    }),
    withTransaction: vi.fn(async (work) => {
      events.push('migration-start');
      await work({
        query: async (text) => {
          if (failOn === 'migration' && text.includes('BROKEN')) throw new Error('syntax error');
          return { rows: [] };
        },
      });
      events.push('migration-commit');
    }),
  };
  return { db, lockClient };
}

describe('runMigrations: advisory lock', () => {
  let dir;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'migrations-'));
    await writeFile(path.join(dir, '001_a.sql'), 'SELECT 1');
    await writeFile(path.join(dir, '002_b.sql'), 'SELECT 2');
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  it('takes the lock before it touches schema_migrations, and releases it afterwards', async () => {
    const { db, lockClient } = fakeDb();
    const ran = await runMigrations(db, dir);

    expect(ran).toEqual(['001_a.sql', '002_b.sql']);
    expect(db.events).toEqual([
      'client-open',
      'try-lock',
      'create-table',
      'read-applied',
      'migration-start',
      'migration-commit',
      'migration-start',
      'migration-commit',
      'unlock',
      'client-destroyed',
    ]);
    expect(lockClient.query).toHaveBeenCalledWith(expect.stringContaining('pg_try_advisory_lock'), [MIGRATION_LOCK_KEY]);
    expect(lockClient.query).toHaveBeenCalledWith(expect.stringContaining('pg_advisory_unlock'), [MIGRATION_LOCK_KEY]);
  });

  it('always destroys the lock connection, so the lock cannot outlive the run', async () => {
    const { db } = fakeDb();
    await runMigrations(db, dir);
    expect(db.withClient.mock.calls[0][1]).toEqual({ discard: true });
  });

  it('waits while another run holds the lock, then proceeds', async () => {
    const { db } = fakeDb({ lockResults: [false, false, true] });
    const sleep = vi.fn(async () => {});
    const ran = await runMigrations(db, dir, { sleep, lockRetryMs: 5 });

    expect(sleep).toHaveBeenCalledTimes(2);
    expect(sleep).toHaveBeenCalledWith(5);
    expect(ran).toHaveLength(2);
    expect(db.events.filter((e) => e === 'try-lock')).toHaveLength(3);
  });

  it('gives up with a clear message when the lock never becomes available, and changes nothing', async () => {
    const { db } = fakeDb({ lockResults: [false] });
    let clock = 0;
    const now = () => clock;
    const sleep = async (ms) => {
      clock += ms;
    };

    await expect(runMigrations(db, dir, { sleep, now, lockTimeoutMs: 3000, lockRetryMs: 1000 })).rejects.toThrow(
      /another migration is running/,
    );
    expect(db.events).not.toContain('create-table');
    expect(db.events).not.toContain('migration-start');
    expect(db.events.at(-1)).toBe('client-destroyed');
  });

  it('releases the lock when a migration fails, and reports the failure', async () => {
    await writeFile(path.join(dir, '003_broken.sql'), 'BROKEN');
    const { db } = fakeDb({ failOn: 'migration' });

    await expect(runMigrations(db, dir)).rejects.toThrow('syntax error');
    expect(db.events).toContain('unlock');
    expect(db.events.at(-1)).toBe('client-destroyed');
  });

  it('does not hide the migration result if unlocking fails (the connection is destroyed anyway)', async () => {
    const { db } = fakeDb({ failOn: 'unlock' });
    await expect(runMigrations(db, dir)).resolves.toHaveLength(2);
    expect(db.events.at(-1)).toBe('client-destroyed');
  });

  it('uses one fixed lock key for every runner', () => {
    expect(Number.isInteger(MIGRATION_LOCK_KEY)).toBe(true);
    expect(MIGRATION_LOCK_KEY).toBe(7357002);
  });
});
