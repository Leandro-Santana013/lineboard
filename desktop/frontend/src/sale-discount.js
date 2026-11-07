export function saleDiscount(items, type, input) {
  const subtotalCents = items.reduce((sum, item) => sum + Math.round((Number(item.price) + Number.EPSILON) * 100), 0);
  const raw = String(input ?? '').trim();
  const normalized = raw.includes(',') ? raw.replace(/\./g, '').replace(',', '.') : raw;
  const validFormat = !raw || /^\d+(?:[.,]\d{0,2})?$/.test(raw) || /^[1-9]\d{0,2}(?:\.\d{3})+,\d{0,2}$/.test(raw);
  const value = normalized ? Number(normalized) : 0;
  const valid = validFormat && Number.isFinite(value) && value >= 0 && (type === 'percent' ? value <= 100 : value * 100 <= subtotalCents + 0.000001);
  const discountCents = valid ? (type === 'percent' ? Math.round(subtotalCents * Math.round(value * 100) / 10000) : Math.round(value * 100)) : 0;
  return { subtotal: subtotalCents / 100, value, discount: discountCents / 100, total: (subtotalCents - discountCents) / 100, valid };
}
