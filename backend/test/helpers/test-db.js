import { randomBytes } from 'node:crypto';
import { createDb } from '../../src/db.js';
import { createLogger } from '../../src/logger.js';

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

// Gatekeeper for every destructive database test. Throws unless the target is clearly a
// disposable test database. The error text never includes the password.
export function assertSafeTestDatabase(rawUrl, env = process.env) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error('TEST_DATABASE_URL is not a valid URL');
  }
  if (!['postgres:', 'postgresql:'].includes(url.protocol)) {
    throw new Error('TEST_DATABASE_URL must be a postgres:// URL');
  }

  const database = decodeURIComponent(url.pathname.replace(/^\//, ''));
  if (!database.endsWith('_test')) {
    throw new Error(
      `Refusing to run destructive tests: database name must end with "_test" (got "${database}")`,
    );
  }

  if (!LOOPBACK_HOSTS.has(url.hostname) && env.ALLOW_REMOTE_TEST_DATABASE !== 'true') {
    throw new Error(
      `Refusing to run destructive tests on non-loopback host "${url.hostname}". ` +
        'Set ALLOW_REMOTE_TEST_DATABASE=true only for a disposable CI database.',
    );
  }

  return { database, host: url.hostname };
}

export const createTestSchemaName = () => `test_${randomBytes(6).toString('hex')}`;

// Creates a uniquely named schema in the test database, points a pool at it, and returns a
// drop() that removes only that schema. Nothing here ever touches the `public` schema.
export async function createTestDatabase(rawUrl) {
  assertSafeTestDatabase(rawUrl);
  const logger = createLogger({ level: 'error', write: () => {} });

  const admin = createDb(rawUrl, { logger, max: 2 });
  try {
    // Second check against what the server reports, not just what the URL claims.
    const { rows } = await admin.query('SELECT current_database() AS name');
    if (!rows[0].name.endsWith('_test')) {
      throw new Error(`Refusing to run: connected database "${rows[0].name}" does not end with "_test"`);
    }

    const schema = createTestSchemaName();
    await admin.query(`CREATE SCHEMA "${schema}"`);
    const db = createDb(rawUrl, { logger, searchPath: schema, statementTimeoutMs: 0 });

    return {
      db,
      schema,
      async drop() {
        await db.close();
        await admin.query(`DROP SCHEMA "${schema}" CASCADE`);
        await admin.close();
      },
    };
  } catch (err) {
    await admin.close();
    throw err;
  }
}
