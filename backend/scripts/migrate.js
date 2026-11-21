import { fileURLToPath } from 'node:url';
import { createDb } from '../src/db.js';
import { resolveDbConnection } from '../src/db-connection.js';
import { runMigrations } from '../src/migrate.js';

let connection;
try {
  // Migrations run as the owner role: DATABASE_URL locally, DB_OWNER_SECRET_ID on AWS.
  connection = await resolveDbConnection({ role: 'owner' });
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

// Migrations may take longer than a request, so no statement timeout.
const db = createDb(connection, { statementTimeoutMs: 0 });
try {
  const ran = await runMigrations(db, fileURLToPath(new URL('../migrations', import.meta.url)));
  console.log(ran.length ? `applied: ${ran.join(', ')}` : 'no pending migrations');
} finally {
  await db.close();
}
