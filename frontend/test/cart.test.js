import { describe, expect, it } from 'vitest';
import { cartCount, cartReducer, cartTotal, MAX_PER_LINE } from '../src/cart.js';

const product = (overrides = {}) => ({
  id: 1,
  name: 'Tee',
  stock: 5,
  price: { amountMinor: 1000, currency: 'BDT' },
  ...overrides,
});

describe('cartReducer', () => {
  it('adds a new product with quantity 1', () => {
    const lines = cartReducer([], { type: 'add', product: product() });
    expect(lines).toEqual([{ product: product(), quantity: 1 }]);
  });

  it('increments quantity when the product is added again', () => {
    const once = cartReducer([], { type: 'add', product: product() });
    const twice = cartReducer(once, { type: 'add', product: product() });
    expect(twice[0].quantity).toBe(2);
  });

  it('never exceeds available stock', () => {
    let lines = [];
    for (let i = 0; i < 10; i += 1) lines = cartReducer(lines, { type: 'add', product: product({ stock: 3 }) });
    expect(lines[0].quantity).toBe(3);
  });

  it('never exceeds the per-line maximum', () => {
    const big = product({ stock: 500 });
    const lines = cartReducer([{ product: big, quantity: 1 }], { type: 'setQuantity', productId: 1, quantity: 999 });
    expect(lines[0].quantity).toBe(MAX_PER_LINE);
  });

  it('does not add an out-of-stock product', () => {
    expect(cartReducer([], { type: 'add', product: product({ stock: 0 }) })).toEqual([]);
  });

  it('clamps quantity to a minimum of 1 instead of removing the line', () => {
    const lines = cartReducer([{ product: product(), quantity: 2 }], {
      type: 'setQuantity',
      productId: 1,
      quantity: 0,
    });
    expect(lines).toEqual([{ product: product(), quantity: 1 }]);
  });

  it('F9: setQuantity ignores non-integers and unknown product ids', () => {
    const lines = [{ product: product(), quantity: 2 }];

    // A non-integer quantity returns the very same array: nothing was even rebuilt.
    expect(cartReducer(lines, { type: 'setQuantity', productId: 1, quantity: Number.NaN })).toBe(lines);
    expect(cartReducer(lines, { type: 'setQuantity', productId: 1, quantity: 1.5 })).toBe(lines);
    // An unknown product id leaves every line as it was.
    expect(cartReducer(lines, { type: 'setQuantity', productId: 99, quantity: 3 })).toEqual(lines);
  });

  it('removes and clears lines', () => {
    const start = [
      { product: product({ id: 1 }), quantity: 1 },
      { product: product({ id: 2 }), quantity: 1 },
    ];
    expect(cartReducer(start, { type: 'remove', productId: 1 })).toHaveLength(1);
    expect(cartReducer(start, { type: 'clear' })).toEqual([]);
  });
});

describe('cart totals', () => {
  it('sums price times quantity and counts items', () => {
    const lines = [
      { product: product({ id: 1, price: { amountMinor: 1000 } }), quantity: 2 },
      { product: product({ id: 2, price: { amountMinor: 250 } }), quantity: 3 },
    ];
    expect(cartTotal(lines)).toBe(2750);
    expect(cartCount(lines)).toBe(5);
  });
});
