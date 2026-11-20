import { HttpError } from './errors.js';

// Merge repeated product lines so each product is locked and priced once.
export function mergeItems(items) {
  const merged = new Map();
  for (const { productId, quantity } of items) {
    merged.set(productId, (merged.get(productId) ?? 0) + quantity);
  }
  return merged;
}

export async function createOrder(db, { customer, items }) {
  const merged = mergeItems(items);
  // Sorted ids give every transaction the same lock order, which avoids deadlocks.
  const ids = [...merged.keys()].sort((a, b) => a - b);

  return db.withTransaction(async (client) => {
    const { rows: products } = await client.query(
      `SELECT id, name, price_minor, currency, stock FROM products
       WHERE id = ANY($1::int[]) ORDER BY id FOR UPDATE`,
      [ids],
    );

    if (products.length !== ids.length) {
      throw new HttpError(422, 'unknown_product', 'One or more products do not exist');
    }

    // An order has one currency, taken from the products themselves, never assumed.
    const currencies = new Set(products.map((p) => p.currency));
    if (currencies.size > 1) {
      throw new HttpError(422, 'mixed_currency', 'Products in one order must share a currency');
    }
    const [currency] = currencies;

    let total = 0;
    const lines = products.map((product) => {
      const quantity = merged.get(product.id);
      if (product.stock < quantity) {
        throw new HttpError(409, 'insufficient_stock', `Not enough stock for ${product.name}`);
      }
      total += product.price_minor * quantity;
      return { productId: product.id, name: product.name, quantity, unitPriceMinor: product.price_minor };
    });

    const { rows } = await client.query(
      `INSERT INTO orders (customer_name, customer_email, shipping_address, total_minor, currency)
       VALUES ($1, $2, $3, $4, $5) RETURNING id, status, created_at`,
      [customer.name, customer.email, customer.address, total, currency],
    );
    const order = rows[0];

    for (const line of lines) {
      await client.query(
        `INSERT INTO order_items (order_id, product_id, quantity, unit_price_minor)
         VALUES ($1, $2, $3, $4)`,
        [order.id, line.productId, line.quantity, line.unitPriceMinor],
      );
      await client.query('UPDATE products SET stock = stock - $1 WHERE id = $2', [
        line.quantity,
        line.productId,
      ]);
    }

    return {
      id: order.id,
      status: order.status,
      createdAt: order.created_at,
      total: { amountMinor: total, currency },
      items: lines,
    };
  });
}

export async function getOrder(db, id) {
  const { rows } = await db.query(
    `SELECT id, status, total_minor, currency, created_at FROM orders WHERE id = $1`,
    [id],
  );
  if (rows.length === 0) return null;

  const order = rows[0];
  const { rows: items } = await db.query(
    `SELECT oi.product_id, p.name, oi.quantity, oi.unit_price_minor
     FROM order_items oi JOIN products p ON p.id = oi.product_id
     WHERE oi.order_id = $1 ORDER BY oi.id`,
    [id],
  );

  return {
    id: order.id,
    status: order.status,
    createdAt: order.created_at,
    total: { amountMinor: order.total_minor, currency: order.currency },
    items: items.map((i) => ({
      productId: i.product_id,
      name: i.name,
      quantity: i.quantity,
      unitPriceMinor: i.unit_price_minor,
    })),
  };
}
