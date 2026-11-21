import { describe, expect, it } from 'vitest';
import { mergeItems } from '../src/orders.js';
import { idSchema, orderSchema, uuidSchema } from '../src/validation.js';

const validOrder = () => ({
  customer: { name: 'Rahim Uddin', email: 'rahim@example.com', address: '12 Lake Road, Dhaka' },
  items: [{ productId: 1, quantity: 2 }],
});

describe('orderSchema', () => {
  it('accepts a valid order', () => {
    expect(orderSchema.safeParse(validOrder()).success).toBe(true);
  });

  it('trims whitespace from customer fields', () => {
    const order = validOrder();
    order.customer.name = '  Rahim  ';
    expect(orderSchema.parse(order).customer.name).toBe('Rahim');
  });

  it('rejects an invalid email', () => {
    const order = validOrder();
    order.customer.email = 'not-an-email';
    expect(orderSchema.safeParse(order).success).toBe(false);
  });

  it('rejects an empty item list', () => {
    expect(orderSchema.safeParse({ ...validOrder(), items: [] }).success).toBe(false);
  });

  it('rejects zero, negative, fractional and oversized quantities', () => {
    for (const quantity of [0, -1, 1.5, 21]) {
      const order = validOrder();
      order.items[0].quantity = quantity;
      expect(orderSchema.safeParse(order).success).toBe(false);
    }
  });

  it('rejects a missing address', () => {
    const order = validOrder();
    delete order.customer.address;
    expect(orderSchema.safeParse(order).success).toBe(false);
  });

  // 2147483647 is the largest PostgreSQL integer. One more would fail inside the database
  // as a server error, so the schema has to stop it first.
  it('bounds productId at the PostgreSQL integer maximum', () => {
    const tooBig = validOrder();
    tooBig.items[0].productId = 2147483648;
    const rejected = orderSchema.safeParse(tooBig);
    expect(rejected.success).toBe(false);
    // Make sure it was productId that failed, not some other field.
    expect(rejected.error.issues[0].path).toEqual(['items', 0, 'productId']);

    const atLimit = validOrder();
    atLimit.items[0].productId = 2147483647;
    expect(orderSchema.safeParse(atLimit).success).toBe(true);
  });
});

describe('id schemas', () => {
  it('coerces numeric path ids and rejects junk', () => {
    expect(idSchema.parse('7')).toBe(7);
    expect(idSchema.safeParse('abc').success).toBe(false);
    expect(idSchema.safeParse('0').success).toBe(false);
  });

  // idSchema reads the id from the URL, so it receives text. It must accept plain decimal digits
  // within the PostgreSQL integer range and nothing else.
  it.each(['99999999999', '2147483648', '1e2', '0x10', ' 1', '0', '-1', 'abc'])(
    'rejects the path id %j',
    (value) => {
      expect(idSchema.safeParse(value).success).toBe(false);
    },
  );

  it('accepts the smallest and largest valid ids', () => {
    expect(idSchema.parse('1')).toBe(1);
    expect(idSchema.parse('2147483647')).toBe(2147483647);
  });

  it('accepts only UUIDs for order ids', () => {
    expect(uuidSchema.safeParse('3f2504e0-4f89-41d3-9a0c-0305e82c3301').success).toBe(true);
    expect(uuidSchema.safeParse('123').success).toBe(false);
  });
});

describe('mergeItems', () => {
  it('sums quantities for repeated products', () => {
    const merged = mergeItems([
      { productId: 1, quantity: 2 },
      { productId: 2, quantity: 1 },
      { productId: 1, quantity: 3 },
    ]);
    expect(merged.get(1)).toBe(5);
    expect(merged.get(2)).toBe(1);
    expect(merged.size).toBe(2);
  });
});
