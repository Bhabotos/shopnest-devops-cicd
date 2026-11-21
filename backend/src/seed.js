import { CURRENCY } from './constants.js';

// Fictional demo catalogue. Prices are integer minor units (poisha), so 129900 = 1,299.00 BDT.
export const SEED_PRODUCTS = [
  { sku: 'nest-tee', name: 'Nest Cotton T-Shirt', description: 'Soft everyday cotton tee.', price: 79900, stock: 40 },
  { sku: 'nest-hoodie', name: 'Nest Zip Hoodie', description: 'Midweight fleece hoodie.', price: 219900, stock: 25 },
  { sku: 'nest-cap', name: 'Nest Canvas Cap', description: 'Adjustable canvas cap.', price: 49900, stock: 60 },
  { sku: 'nest-bottle', name: 'Nest Steel Bottle', description: 'Insulated 600 ml bottle.', price: 129900, stock: 35 },
  { sku: 'nest-notebook', name: 'Nest Dot-Grid Notebook', description: 'A5 hardcover notebook.', price: 39900, stock: 80 },
  { sku: 'nest-backpack', name: 'Nest Daypack', description: '20 litre water-resistant backpack.', price: 289900, stock: 15 },
  { sku: 'nest-mug', name: 'Nest Ceramic Mug', description: '350 ml stoneware mug.', price: 59900, stock: 50 },
  { sku: 'nest-socks', name: 'Nest Sock Pair', description: 'Breathable cotton blend socks.', price: 29900, stock: 100 },
];

// Seeding is explicit, never part of a deployment. Policy (exact string matches only: no trimming,
// no case folding):
//   - NODE_ENV "development" or "test": allowed, whatever ALLOW_PRODUCTION_SEED says.
//   - NODE_ENV "production": allowed only with ALLOW_PRODUCTION_SEED set to exactly "true".
//   - anything else (staging, an unknown name, empty or unset): refused, even with the flag. A staging
//     or unrecognised environment is not a place to opt in from; the one deliberate override is production.
const SEED_ENVIRONMENTS = new Set(['development', 'test']);

export function assertSeedAllowed(env = process.env) {
  if (SEED_ENVIRONMENTS.has(env.NODE_ENV)) return;
  if (env.NODE_ENV === 'production' && env.ALLOW_PRODUCTION_SEED === 'true') return;
  throw new Error(
    `Refusing to seed: NODE_ENV is "${env.NODE_ENV ?? 'unset'}". ` +
      'Seeding is allowed in development and test; in production it needs ALLOW_PRODUCTION_SEED=true ' +
      'and must be run manually or from an explicitly triggered workflow.',
  );
}

// Idempotent: existing SKUs are left untouched, so re-running never resets stock.
export async function seedProducts(db) {
  for (const p of SEED_PRODUCTS) {
    await db.query(
      `INSERT INTO products (sku, name, description, price_minor, currency, image_url, stock)
       VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (sku) DO NOTHING`,
      [p.sku, p.name, p.description, p.price, CURRENCY, `/images/${p.sku}.svg`, p.stock],
    );
  }
}
