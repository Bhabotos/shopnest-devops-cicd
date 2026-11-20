export class ApiError extends Error {
  constructor(status, message, code) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }
}

async function request(path, options = {}) {
  const res = await fetch(path, { headers: { 'Content-Type': 'application/json' }, ...options });
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    throw new ApiError(res.status, body?.error?.message ?? 'Request failed', body?.error?.code);
  }
  return body;
}

export async function fetchProducts() {
  return (await request('/api/products')).products;
}

export function placeOrder(payload) {
  return request('/api/orders', { method: 'POST', body: JSON.stringify(payload) });
}
