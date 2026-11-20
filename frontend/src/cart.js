export const MAX_PER_LINE = 20;

export const maxQuantity = (product) => Math.min(product.stock, MAX_PER_LINE);

export function cartReducer(lines, action) {
  switch (action.type) {
    case 'add': {
      const { product } = action;
      const limit = maxQuantity(product);
      const existing = lines.find((l) => l.product.id === product.id);
      if (existing) {
        return lines.map((l) =>
          l.product.id === product.id ? { ...l, quantity: Math.min(l.quantity + 1, limit) } : l,
        );
      }
      return limit < 1 ? lines : [...lines, { product, quantity: 1 }];
    }
    case 'setQuantity': {
      // Quantity is clamped to 1..max. Lines are removed only by the explicit 'remove' action.
      if (!Number.isInteger(action.quantity)) return lines;
      return lines.map((l) =>
        l.product.id === action.productId
          ? { ...l, quantity: Math.min(Math.max(action.quantity, 1), maxQuantity(l.product)) }
          : l,
      );
    }
    case 'remove':
      return lines.filter((l) => l.product.id !== action.productId);
    case 'clear':
      return [];
    default:
      return lines;
  }
}

export const cartTotal = (lines) =>
  lines.reduce((sum, l) => sum + l.product.price.amountMinor * l.quantity, 0);

export const cartCount = (lines) => lines.reduce((sum, l) => sum + l.quantity, 0);
