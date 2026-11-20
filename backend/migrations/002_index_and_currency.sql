-- Additive follow-up to 001; 001 stays untouched because it may already be applied.

-- Foreign-key lookups and joins on order_items.product_id.
CREATE INDEX order_items_product_id_idx ON order_items(product_id);

-- The currency is always set by the application (backend/src/constants.js and the seed).
-- Removing the default stops the database from silently assuming one.
ALTER TABLE products ALTER COLUMN currency DROP DEFAULT;
