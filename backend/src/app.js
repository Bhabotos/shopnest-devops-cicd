import express from 'express';
import { ZodError } from 'zod';
import { HttpError } from './errors.js';
import { createOrder, getOrder } from './orders.js';
import { getProduct, listProducts } from './products.js';
import { idSchema, orderSchema, uuidSchema } from './validation.js';

export function createApp({ db, config, logger }) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '100kb' }));

  app.use((req, res, next) => {
    const start = process.hrtime.bigint();
    res.on('finish', () => {
      const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
      logger.info('request', {
        method: req.method,
        path: req.path,
        status: res.statusCode,
        durationMs: Math.round(durationMs),
      });
    });
    next();
  });

  app.get('/health', async (_req, res) => {
    try {
      await db.query('SELECT 1');
      res.json({ status: 'ok' });
    } catch (err) {
      logger.error('health check failed', { error: err.message });
      res.status(503).json({ status: 'unavailable' });
    }
  });

  app.get('/version', (_req, res) => {
    res.json({ version: config.version, commit: config.commit });
  });

  app.get('/api/products', async (_req, res) => {
    res.json({ products: await listProducts(db) });
  });

  app.get('/api/products/:id', async (req, res) => {
    const product = await getProduct(db, idSchema.parse(req.params.id));
    if (!product) throw new HttpError(404, 'not_found', 'Product not found');
    res.json(product);
  });

  app.post('/api/orders', async (req, res) => {
    const input = orderSchema.parse(req.body);
    res.status(201).json(await createOrder(db, input));
  });

  app.get('/api/orders/:id', async (req, res) => {
    const order = await getOrder(db, uuidSchema.parse(req.params.id));
    if (!order) throw new HttpError(404, 'not_found', 'Order not found');
    res.json(order);
  });

  app.use((_req, _res, next) => next(new HttpError(404, 'not_found', 'Route not found')));

  // Express 5 forwards rejected async handlers here.
  app.use((err, _req, res, _next) => {
    if (err instanceof ZodError) {
      return res.status(400).json({
        error: { code: 'validation_error', message: 'Invalid request', details: err.issues },
      });
    }
    if (err.type === 'entity.parse.failed') {
      return res.status(400).json({ error: { code: 'invalid_json', message: 'Malformed JSON body' } });
    }
    if (err instanceof HttpError) {
      return res.status(err.status).json({ error: { code: err.code, message: err.message } });
    }
    logger.error('unhandled error', { error: err.message });
    return res.status(500).json({ error: { code: 'internal_error', message: 'Internal server error' } });
  });

  return app;
}
