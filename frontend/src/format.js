import { CURRENCY_LOCALE } from './config/locale.js';

// `currency` is an ISO 4217 code taken from the API response (product price or order total).
export function formatMoney(amountMinor, currency) {
  return new Intl.NumberFormat(CURRENCY_LOCALE, { style: 'currency', currency }).format(amountMinor / 100);
}
