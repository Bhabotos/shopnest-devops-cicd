import { fileURLToPath } from 'node:url';
import { createDb } from '../src/db.js';
import { runMigrations } from '../src/migrate.js';

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set');
  process.exit(1);
}

// Migrations run as the owner role and may take longer than a request, so no statement timeout.
const db = createDb(process.env.DATABASE_URL, { statementTimeoutMs: 0 });
try {
  const ran = await runMigrations(db, fileURLToPath(new URL('../migrations', import.meta.url)));
  console.log(ran.length ? `applied: ${ran.join(', ')}` : 'no pending migrations');
} finally {
  await db.close();
}
