const toProduct = (row) => ({
  id: row.id,
  sku: row.sku,
  name: row.name,
  description: row.description,
  price: { amountMinor: row.price_minor, currency: row.currency },
  imageUrl: row.image_url,
  stock: row.stock,
});

const COLUMNS = 'id, sku, name, description, price_minor, currency, image_url, stock';

export async function listProducts(db) {
  const { rows } = await db.query(`SELECT ${COLUMNS} FROM products ORDER BY id`);
  return rows.map(toProduct);
}

export async function getProduct(db, id) {
  const { rows } = await db.query(`SELECT ${COLUMNS} FROM products WHERE id = $1`, [id]);
  return rows.length === 0 ? null : toProduct(rows[0]);
}
