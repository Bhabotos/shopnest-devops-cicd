import { createDb } from '../src/db.js';
import { assertSeedAllowed, seedProducts } from '../src/seed.js';

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set');
  process.exit(1);
}

try {
  assertSeedAllowed();
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

const db = createDb(process.env.DATABASE_URL, { statementTimeoutMs: 0 });
try {
  await seedProducts(db);
  console.log('seed complete');
} finally {
  await db.close();
}
