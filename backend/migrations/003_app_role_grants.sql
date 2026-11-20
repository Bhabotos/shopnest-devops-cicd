-- Explicit, per-table privileges for the least-privilege application role.
-- Convention: every migration that adds a table or sequence also grants what the API needs here
-- or in its own file; nothing is granted implicitly through default privileges.
--
-- The role itself is created outside migrations (deploy/db/init/01-roles.sh) because roles are
-- cluster-wide and need a superuser. Where it does not exist (for example a disposable CI or
-- test database) this migration is a no-op, so the same migrations run everywhere.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shopnest_app') THEN
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO shopnest_app', current_schema());

    -- Catalogue: read everything; the only column the API may change is stock (the order
    -- decrement in backend/src/orders.js). A column-level UPDATE also satisfies
    -- SELECT ... FOR UPDATE, which needs UPDATE on at least one column. Name, price, currency,
    -- sku and the rest stay read-only for the API.
    GRANT SELECT ON products TO shopnest_app;
    GRANT UPDATE (stock) ON products TO shopnest_app;
    -- Guest checkout: create and read orders and their lines. No UPDATE or DELETE.
    GRANT SELECT, INSERT ON orders TO shopnest_app;
    GRANT SELECT, INSERT ON order_items TO shopnest_app;
    GRANT USAGE ON SEQUENCE order_items_id_seq TO shopnest_app;
    -- Deliberately not granted: schema_migrations, any DDL, and DELETE anywhere.
  END IF;
END
$$;
