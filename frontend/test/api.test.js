import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, fetchProducts, placeOrder } from '../src/api.js';

const respond = (status, body) =>
  vi.fn().mockResolvedValue({ ok: status < 400, status, json: async () => body });

afterEach(() => vi.unstubAllGlobals());

describe('api client', () => {
  it('fetchProducts unwraps the products array', async () => {
    vi.stubGlobal('fetch', respond(200, { products: [{ id: 1 }] }));
    expect(await fetchProducts()).toEqual([{ id: 1 }]);
    expect(fetch).toHaveBeenCalledWith('/api/products', expect.any(Object));
  });

  it('placeOrder POSTs JSON and returns the order', async () => {
    vi.stubGlobal('fetch', respond(201, { id: 'abc' }));
    const order = await placeOrder({ items: [] });
    expect(order).toEqual({ id: 'abc' });
    const [, options] = fetch.mock.calls[0];
    expect(options.method).toBe('POST');
    expect(options.body).toBe(JSON.stringify({ items: [] }));
  });

  it('throws an ApiError carrying the server message and code', async () => {
    vi.stubGlobal('fetch', respond(409, { error: { code: 'insufficient_stock', message: 'Not enough stock' } }));
    await expect(placeOrder({})).rejects.toMatchObject({
      name: 'ApiError',
      status: 409,
      code: 'insufficient_stock',
      message: 'Not enough stock',
    });
  });

  it('uses a generic message when the error body is not JSON', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false,
      status: 502,
      json: async () => {
        throw new Error('not json');
      },
    }));
    const err = await fetchProducts().catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err.message).toBe('Request failed');
  });
});
