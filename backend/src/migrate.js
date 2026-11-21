import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

// One migration run at a time per database. Every runner (the CodeBuild migrator, a developer, a test) takes this
// same PostgreSQL advisory lock, so two runs can never interleave. Advisory locks are per database and per session.
export const MIGRATION_LOCK_KEY = 7357002;

async function acquireLock(client, { timeoutMs, retryMs, sleep, now }) {
  const deadline = now() + timeoutMs;
  for (;;) {
    const { rows } = await client.query('SELECT pg_try_advisory_lock($1) AS locked', [MIGRATION_LOCK_KEY]);
    if (rows[0].locked) return;
    if (now() >= deadline) {
      throw new Error('another migration is running: the migration lock was not available in time; nothing was changed');
    }
    await sleep(retryMs);
  }
}

// Applies *.sql files in name order, each in its own transaction, recording what ran.
export async function runMigrations(
  db,
  directory,
  { lockTimeoutMs = 120000, lockRetryMs = 1000, sleep = delay, now = Date.now } = {},
) {
  // The lock lives on its own connection, which is destroyed afterwards (so the lock cannot outlive this function).
  return db.withClient(
    async (lockClient) => {
      await acquireLock(lockClient, { timeoutMs: lockTimeoutMs, retryMs: lockRetryMs, sleep, now });
      try {
        await db.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    name text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
  )`);

        const { rows } = await db.query('SELECT name FROM schema_migrations');
        const applied = new Set(rows.map((r) => r.name));
        const files = (await readdir(directory)).filter((f) => f.endsWith('.sql')).sort();
        const ran = [];

        for (const file of files) {
          if (applied.has(file)) continue;
          const sql = await readFile(path.join(directory, file), 'utf8');
          await db.withTransaction(async (client) => {
            await client.query(sql);
            await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file]);
          });
          ran.push(file);
        }
        return ran;
      } finally {
        await lockClient.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK_KEY]).catch(() => {});
      }
    },
    { discard: true },
  );
}
