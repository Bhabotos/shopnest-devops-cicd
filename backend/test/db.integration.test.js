import { fileURLToPath } from 'node:url';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { createLogger } from '../src/logger.js';
import { runMigrations } from '../src/migrate.js';
import { seedProducts } from '../src/seed.js';
import { createTestDatabase } from './helpers/test-db.js';

// These tests need a real PostgreSQL. TEST_DATABASE_URL must name a disposable database whose
// name ends in "_test"; each run works inside its own throw-away schema (see helpers/test-db.js).
const url = process.env.TEST_DATABASE_URL;
const migrationsDir = fileURLToPath(new URL('../migrations', import.meta.url));

describe.skipIf(!url)('database integration', () => {
  let testDb;
  let db;
  let app;

  beforeAll(async () => {
    testDb = await createTestDatabase(url);
    db = testDb.db;
    await runMigrations(db, migrationsDir);
    const logger = createLogger({ level: 'error', write: () => {} });
    app = createApp({ db, config: { version: 't', commit: 't' }, logger });
  });

  afterAll(() => testDb?.drop());

  beforeEach(async () => {
    await db.query('TRUNCATE order_items, orders, products RESTART IDENTITY CASCADE');
    await seedProducts(db);
  });

  const customer = { name: 'Rahim', email: 'rahim@example.com', address: '12 Lake Road, Dhaka' };
  const stockOf = async (id) => (await db.query('SELECT stock FROM products WHERE id=$1', [id])).rows[0].stock;

  it('migrations are idempotent', async () => {
    expect(await runMigrations(db, migrationsDir)).toEqual([]);
  });

  it('seeding twice does not duplicate products or reset stock', async () => {
    await db.query('UPDATE products SET stock = 1 WHERE id = 1');
    await seedProducts(db);
    const { rows } = await db.query('SELECT count(*)::int AS n FROM products');
    expect(rows[0].n).toBe(8);
    expect(await stockOf(1)).toBe(1);
  });

  it('enforces non-negative stock and price at the database level', async () => {
    await expect(db.query('UPDATE products SET stock = -1 WHERE id = 1')).rejects.toThrow();
    await expect(db.query('UPDATE products SET price_minor = -5 WHERE id = 1')).rejects.toThrow();
  });

  it('lists seeded products over HTTP', async () => {
    const res = await request(app).get('/api/products');
    expect(res.body.products).toHaveLength(8);
    expect(res.body.products[0].price.currency).toBe('BDT');
  });

  it('creates an order, totals it on the server and decrements stock', async () => {
    const before = await stockOf(1);
    const res = await request(app)
      .post('/api/orders')
      .send({ customer, items: [{ productId: 1, quantity: 2 }, { productId: 3, quantity: 1 }] });
    expect(res.status).toBe(201);
    expect(res.body.total).toEqual({ amountMinor: 79900 * 2 + 49900, currency: 'BDT' });
    expect(await stockOf(1)).toBe(before - 2);
  });

  it('merges repeated product lines into one', async () => {
    const res = await request(app)
      .post('/api/orders')
      .send({ customer, items: [{ productId: 1, quantity: 1 }, { productId: 1, quantity: 2 }] });
    expect(res.status).toBe(201);
    expect(res.body.items).toHaveLength(1);
    expect(res.body.items[0].quantity).toBe(3);
  });

  it('returns 409 and changes nothing when stock is insufficient', async () => {
    await db.query('UPDATE products SET stock = 1 WHERE id = 3');
    const res = await request(app)
      .post('/api/orders')
      .send({ customer, items: [{ productId: 1, quantity: 2 }, { productId: 3, quantity: 5 }] });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('insufficient_stock');
    expect(await stockOf(1)).toBe(40);
    expect((await db.query('SELECT count(*)::int AS n FROM orders')).rows[0].n).toBe(0);
  });

  it('returns 422 for an unknown product', async () => {
    const res = await request(app)
      .post('/api/orders')
      .send({ customer, items: [{ productId: 9999, quantity: 1 }] });
    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('unknown_product');
  });

  it('never oversells under concurrent orders', async () => {
    await db.query('UPDATE products SET stock = 3 WHERE id = 1');
    const results = await Promise.all(
      Array.from({ length: 6 }, () =>
        request(app).post('/api/orders').send({ customer, items: [{ productId: 1, quantity: 1 }] }),
      ),
    );
    expect(results.filter((r) => r.status === 201)).toHaveLength(3);
    expect(results.filter((r) => r.status === 409)).toHaveLength(3);
    expect(await stockOf(1)).toBe(0);
  });

  it('fetches a placed order back by id', async () => {
    const created = await request(app)
      .post('/api/orders')
      .send({ customer, items: [{ productId: 2, quantity: 1 }] });
    const res = await request(app).get(`/api/orders/${created.body.id}`);
    expect(res.status).toBe(200);
    expect(res.body.items[0]).toMatchObject({ productId: 2, quantity: 1, unitPriceMinor: 219900 });
  });

  it('GET /health reports ok against a real database', async () => {
    expect((await request(app).get('/health')).status).toBe(200);
  });
});
