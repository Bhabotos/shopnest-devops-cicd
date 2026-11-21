import pg from 'pg';
import { createLogger } from './logger.js';

const SCHEMA_NAME = /^[a-z_][a-z0-9_]*$/;

// `connection` is a connection string, or a node-postgres connection object ({ host, port, database,
// user, password, ssl }) as returned by resolveDbConnection for RDS.
export function createDb(
  connection,
  {
    logger = createLogger(),
    max = 10,
    connectionTimeoutMs = 5000,
    // 0 disables the limit (used for migrations, which may legitimately run long).
    statementTimeoutMs = 10000,
    idleTimeoutMs = 30000,
    // Optional single schema to work in; used by tests to isolate each run.
    searchPath,
  } = {},
) {
  if (searchPath !== undefined && !SCHEMA_NAME.test(searchPath)) {
    throw new Error('Invalid schema name for search_path');
  }

  const pool = new pg.Pool({
    ...(typeof connection === 'string' ? { connectionString: connection } : connection),
    max,
    connectionTimeoutMillis: connectionTimeoutMs,
    idleTimeoutMillis: idleTimeoutMs,
    statement_timeout: statementTimeoutMs,
    ...(searchPath ? { options: `-c search_path=${searchPath}` } : {}),
  });

  // An idle client can error when the server drops it (restart, failover, admin kill).
  // Without a listener Node treats the event as fatal and the process exits.
  pool.on('error', (err) => {
    logger.error('idle database client error', { error: err.message });
  });

  return {
    query: (text, params) => pool.query(text, params),

    async withTransaction(work) {
      const client = await pool.connect();
      let discard = false;
      try {
        await client.query('BEGIN');
        const result = await work(client);
        await client.query('COMMIT');
        return result;
      } catch (err) {
        // If the rollback itself fails the connection is in an unknown state: destroy it.
        await client.query('ROLLBACK').catch(() => {
          discard = true;
        });
        throw err;
      } finally {
        client.release(discard);
      }
    },

    // One dedicated connection for work that needs a SESSION (an advisory lock, for example). With discard the
    // connection is destroyed afterwards, so a session-level lock can never outlive the work, even if unlocking failed.
    async withClient(work, { discard = false } = {}) {
      const client = await pool.connect();
      try {
        return await work(client);
      } finally {
        client.release(discard);
      }
    },

    close: () => pool.end(),
  };
}
