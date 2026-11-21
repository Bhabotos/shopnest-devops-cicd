import { createDb } from '../src/db.js';
import { resolveDbConnection } from '../src/db-connection.js';
import { assertSeedAllowed, seedProducts } from '../src/seed.js';

// The environment guard runs first, so a refused seed never reads a secret or opens a connection.
try {
  assertSeedAllowed();
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

let connection;
try {
  connection = await resolveDbConnection({ role: 'owner' });
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

const db = createDb(connection, { statementTimeoutMs: 0 });
try {
  await seedProducts(db);
  console.log('seed complete');
} finally {
  await db.close();
}
