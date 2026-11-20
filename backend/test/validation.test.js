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
});

describe('id schemas', () => {
  it('coerces numeric path ids and rejects junk', () => {
    expect(idSchema.parse('7')).toBe(7);
    expect(idSchema.safeParse('abc').success).toBe(false);
    expect(idSchema.safeParse('0').success).toBe(false);
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
