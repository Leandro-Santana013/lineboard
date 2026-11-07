import { describe, it, expect } from 'vitest';
import { saleDiscount } from './sale-discount.js';

describe('sale discount', () => {
  const items = Array.from({ length: 4 }, () => ({ price: 109 }));
  it('deducts percentage and fixed BRL values immediately', () => {
    expect(saleDiscount(items, 'percent', '10')).toMatchObject({ subtotal: 436, discount: 43.6, total: 392.4, valid: true });
    expect(saleDiscount(items, 'amount', '20,50')).toMatchObject({ discount: 20.5, total: 415.5, valid: true });
    expect(saleDiscount([{ price: 2000 }], 'amount', '1.000,50').total).toBe(999.5);
  });
  it('accepts no discount and a full discount, with exact cent rounding', () => {
    expect(saleDiscount(items, 'percent', '').total).toBe(436);
    expect(saleDiscount(items, 'percent', '100').total).toBe(0);
    expect(saleDiscount([{ price: 0.05 }], 'percent', '10').discount).toBe(0.01);
    expect(saleDiscount([{ price: 69.9 }], 'percent', '12,34')).toMatchObject({ discount: 8.63, total: 61.27 });
  });
  it.each(['-1', '101', 'abc', '1,234', '1.234', '1e2', 'Infinity'])('rejects an invalid percentage %s', (value) => {
    expect(saleDiscount(items, 'percent', value).valid).toBe(false);
  });
  it('rejects amounts above the cart subtotal after items are removed', () => {
    expect(saleDiscount([{ price: 109 }], 'amount', '110').valid).toBe(false);
  });
});
