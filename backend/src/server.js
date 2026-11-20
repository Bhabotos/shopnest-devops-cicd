import { createApp } from './app.js';
import { loadConfig } from './config.js';
import { createDb } from './db.js';
import { createLogger } from './logger.js';

const config = loadConfig();
const logger = createLogger({ level: config.logLevel });

if (!config.databaseUrl) {
  logger.error('DATABASE_URL is not set');
  process.exit(1);
}

const db = createDb(config.databaseUrl, {
  logger,
  max: config.db.poolMax,
  connectionTimeoutMs: config.db.connectionTimeoutMs,
  statementTimeoutMs: config.db.statementTimeoutMs,
});
const server = createApp({ db, config, logger }).listen(config.port, config.host, () => {
  logger.info('server started', { port: config.port, version: config.version });
});

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info('shutting down', { signal });

  const forceExit = setTimeout(() => {
    logger.error('shutdown timed out, forcing exit');
    process.exit(1);
  }, config.shutdownTimeoutMs);
  forceExit.unref();

  // Stop accepting connections, let in-flight requests finish, then close the pool.
  server.close(async () => {
    await db.close();
    logger.info('shutdown complete');
    process.exit(0);
  });
  server.closeIdleConnections();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
