import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { createLogger } from '../src/logger.js';

const productRow = {
  id: 1,
  sku: 'nest-tee',
  name: 'Nest Cotton T-Shirt',
  description: 'Soft tee.',
  price_minor: 79900,
  currency: 'BDT',
  image_url: '/images/nest-tee.svg',
  stock: 10,
};

function makeApp(query = vi.fn().mockResolvedValue({ rows: [] })) {
  const db = { query, withTransaction: vi.fn() };
  const config = { version: '9.9.9', commit: 'deadbeef' };
  const logger = createLogger({ level: 'error', write: () => {} });
  return { app: createApp({ db, config, logger }), db };
}

describe('health and version', () => {
  it('GET /health returns ok when the database answers', async () => {
    const { app } = makeApp();
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });

  it('GET /health returns 503 when the database fails', async () => {
    const { app } = makeApp(vi.fn().mockRejectedValue(new Error('connection refused')));
    const res = await request(app).get('/health');
    expect(res.status).toBe(503);
    expect(res.body).toEqual({ status: 'unavailable' });
  });

  it('GET /version reports the configured version and commit', async () => {
    const { app } = makeApp();
    const res = await request(app).get('/version');
    expect(res.body).toEqual({ version: '9.9.9', commit: 'deadbeef' });
  });
});

describe('products', () => {
  it('GET /api/products maps rows to the public shape', async () => {
    const { app } = makeApp(vi.fn().mockResolvedValue({ rows: [productRow] }));
    const res = await request(app).get('/api/products');
    expect(res.status).toBe(200);
    expect(res.body.products[0]).toEqual({
      id: 1,
      sku: 'nest-tee',
      name: 'Nest Cotton T-Shirt',
      description: 'Soft tee.',
      price: { amountMinor: 79900, currency: 'BDT' },
      imageUrl: '/images/nest-tee.svg',
      stock: 10,
    });
  });

  // The id reaches the database as a bound parameter ($1 plus a values array), never pasted into the SQL text.
  it('GET /api/products/:id returns the product in the public shape', async () => {
    const { app, db } = makeApp(vi.fn().mockResolvedValue({ rows: [productRow] }));
    const res = await request(app).get('/api/products/1');

    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      id: 1,
      sku: 'nest-tee',
      name: 'Nest Cotton T-Shirt',
      description: 'Soft tee.',
      price: { amountMinor: 79900, currency: 'BDT' },
      imageUrl: '/images/nest-tee.svg',
      stock: 10,
    });
    const [sql, params] = db.query.mock.calls[0];
    expect(params).toEqual([1]);
    expect(sql).toContain('$1');
  });

  // 99999999999 is far beyond the PostgreSQL integer range. It must be refused at the edge, because
  // sending it to the database would come back as a server error instead of a clean 400.
  it.each(['99999999999', '2147483648'])(
    'GET /api/products/%s is rejected before the database is queried',
    async (id) => {
      const { app, db } = makeApp();
      const res = await request(app).get(`/api/products/${id}`);

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('validation_error');
      expect(db.query).not.toHaveBeenCalled();
    },
  );

  it('GET /api/products/:id returns 404 for an unknown product', async () => {
    const { app } = makeApp();
    const res = await request(app).get('/api/products/99');
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('not_found');
  });

  it('GET /api/products/:id returns 400 for a non-numeric id', async () => {
    const { app, db } = makeApp();
    const res = await request(app).get('/api/products/abc');
    expect(res.status).toBe(400);
    expect(db.query).not.toHaveBeenCalled();
  });
});

describe('orders', () => {
  it('POST /api/orders rejects an invalid body with details', async () => {
    const { app, db } = makeApp();
    const res = await request(app).post('/api/orders').send({ customer: {}, items: [] });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('validation_error');
    expect(res.body.error.details.length).toBeGreaterThan(0);
    expect(db.withTransaction).not.toHaveBeenCalled();
  });

  it('POST /api/orders rejects malformed JSON', async () => {
    const { app } = makeApp();
    const res = await request(app)
      .post('/api/orders')
      .set('Content-Type', 'application/json')
      .send('{not json');
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('invalid_json');
  });

  it('GET /api/orders/:id rejects a non-UUID id', async () => {
    const { app } = makeApp();
    const res = await request(app).get('/api/orders/123');
    expect(res.status).toBe(400);
  });

  it('GET /api/orders/:id returns 404 when the order does not exist', async () => {
    const { app } = makeApp();
    const res = await request(app).get('/api/orders/3f2504e0-4f89-41d3-9a0c-0305e82c3301');
    expect(res.status).toBe(404);
  });
});

describe('error handling', () => {
  it('returns a JSON 404 for unknown routes', async () => {
    const { app } = makeApp();
    const res = await request(app).get('/nope');
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('not_found');
  });

  it('hides internal error details behind a generic 500', async () => {
    const { app } = makeApp(vi.fn().mockRejectedValue(new Error('secret table name leaked')));
    const res = await request(app).get('/api/products');
    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toContain('secret table name');
  });
});
