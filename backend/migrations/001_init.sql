-- Initial schema. Later migrations are additive (new files); never edit an applied one.
CREATE TABLE products (
  id           serial PRIMARY KEY,
  sku          text NOT NULL UNIQUE,
  name         text NOT NULL,
  description  text NOT NULL DEFAULT '',
  price_minor  integer NOT NULL CHECK (price_minor >= 0),
  currency     char(3) NOT NULL DEFAULT 'BDT',
  image_url    text NOT NULL,
  stock        integer NOT NULL DEFAULT 0 CHECK (stock >= 0),
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Guest checkout: orders carry contact details instead of a user account.
CREATE TABLE orders (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name     text NOT NULL,
  customer_email    text NOT NULL,
  shipping_address  text NOT NULL,
  total_minor       integer NOT NULL CHECK (total_minor >= 0),
  currency          char(3) NOT NULL,
  status            text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'cancelled')),
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
  id                serial PRIMARY KEY,
  order_id          uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id        integer NOT NULL REFERENCES products(id),
  quantity          integer NOT NULL CHECK (quantity > 0),
  unit_price_minor  integer NOT NULL CHECK (unit_price_minor >= 0)
);

CREATE INDEX order_items_order_id_idx ON order_items(order_id);
