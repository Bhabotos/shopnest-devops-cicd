const intFrom = (value, fallback) => {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
};

export function loadConfig(env = process.env) {
  return {
    port: intFrom(env.PORT, 3000),
    host: env.HOST ?? '0.0.0.0',
    databaseUrl: env.DATABASE_URL,
    version: env.APP_VERSION ?? '0.1.0',
    commit: env.GIT_SHA ?? 'unknown',
    logLevel: env.LOG_LEVEL ?? 'info',
    shutdownTimeoutMs: intFrom(env.SHUTDOWN_TIMEOUT_MS, 10000),
    db: {
      poolMax: intFrom(env.DB_POOL_MAX, 10),
      // Fail fast instead of queueing forever when the pool is exhausted or the database is down.
      connectionTimeoutMs: intFrom(env.DB_CONNECTION_TIMEOUT_MS, 5000),
      // Server-side limit per statement, so one stuck query cannot hold a connection indefinitely.
      statementTimeoutMs: intFrom(env.DB_STATEMENT_TIMEOUT_MS, 10000),
    },
  };
}
