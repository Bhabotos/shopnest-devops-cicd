import { describe, expect, it } from 'vitest';
import { formatMoney } from '../src/format.js';

// Intl separates the currency code and the number with a non-breaking space (U+00A0).
// The API provides the currency code, while the en-IN locale uses lakh/crore digit grouping.
describe('formatMoney', () => {
  it('converts minor units to a major-unit amount with two decimals', () => {
    expect(formatMoney(129900, 'BDT')).toBe('BDT 1,299.00');
  });

  it('formats zero', () => {
    expect(formatMoney(0, 'BDT')).toBe('BDT 0.00');
  });

  it('uses lakh grouping for large amounts', () => {
    expect(formatMoney(123456789, 'BDT')).toBe('BDT 12,34,567.89');
  });

  // F10: another currency is formatted with its own symbol. USD has a symbol ("$"), so there is no
  // code and no non-breaking space here, unlike "BDT" above where Intl falls back to the code.
  it('formats another currency with its own symbol', () => {
    expect(formatMoney(123456, 'USD')).toBe('$1,234.56');
  });

  // F11: the currency always comes from the API, so a missing one is a bug and must fail loudly
  // instead of silently rendering a made-up currency. This pins what Intl does today.
  it('requires a currency', () => {
    expect(() => formatMoney(100)).toThrow(TypeError);
  });
});
