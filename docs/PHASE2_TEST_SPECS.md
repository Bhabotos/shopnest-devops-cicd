# Phase 2 test specifications (for you to write)

Status: specifications only. **None of the tests below exist yet.** Part B4 requires meaningful
tests "written by me", so you write and own them; Claude drafts the specs and reviews your code.
Each spec says what the test must prove, how to set it up, and what failure it would catch.
Where the behaviour was already checked once by an ad-hoc script, the evidence is in
`docs/evidence/phase2/adhoc-backend-validation.txt`; that script is not part of the repository
and is not a test suite.

How to run the database tests: `deploy/docker-compose.test.yml` (header comment), then
`TEST_DATABASE_URL=... npm test --prefix backend`.

## A. Priority 1 specs

### A1. Test-database guard (new file `backend/test/test-db-guard.test.js`)
Subject: `assertSafeTestDatabase` in `backend/test/helpers/test-db.js`. Pure function, no database.
| Case | Input | Expect |
|---|---|---|
| dev-style name | `.../shopnest` | throws, message mentions `_test` |
| remote host | `.../shopnest_test` on a non-loopback host | throws, mentions loopback |
| remote host with opt-in | same, env `ALLOW_REMOTE_TEST_DATABASE=true` | returns the database name |
| malformed / empty / non-postgres URL | `not a url`, `''`, `mysql://...` | throws |
| no password leak | URL with a password in a rejected case | `error.message` does not contain it |
| good URL | `postgres://u:p@127.0.0.1:55432/shopnest_test` | returns `{ database, host }` |
Catches: a mistyped `TEST_DATABASE_URL` reaching a development or production database.

### A2. Per-run schema isolation (integration, `db.integration.test.js` or a new file)
Subject: `createTestDatabase`. Create two test databases, migrate one: the other has zero tables;
`public` has zero tables; after `drop()` the schema is gone. Catches: tests that leak state or
touch `public`.

### A3. Pool error handling (integration)
Subject: `createDb` (`backend/src/db.js`). Arrange: a logger that records lines; run one query so
an idle connection exists; from a second connection run
`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND state = 'idle'`;
wait about 500 ms. Assert: the process did not crash, the logger received
`idle database client error`, and the next `db.query('SELECT 1')` succeeds.
Catches: the missing `pool.on('error')` listener (review finding B1).

### A4. Timeouts (integration + unit)
- Statement timeout: `createDb(url, { statementTimeoutMs: 300 })`, run `SELECT pg_sleep(3)`,
  expect a rejection matching `statement timeout`.
- Connection timeout: `createDb(url, { max: 1, connectionTimeoutMs: 300 })`, hold the only client
  inside `withTransaction`, a second `query` rejects with `timeout` in well under 2 s.
- Config: extend `config.test.js` so `DB_POOL_MAX`, `DB_CONNECTION_TIMEOUT_MS` and
  `DB_STATEMENT_TIMEOUT_MS` are read from the environment and fall back to the defaults.
- `createDb(url, { searchPath: 'bad"; DROP SCHEMA public' })` throws before any connection.

### A5. Id-range validation (unit + API)
Subject: `idSchema` and `orderSchema` in `backend/src/validation.js`.
- `idSchema` rejects `99999999999`, `2147483648`, `1e2`, `0x10`, `' 1'`, `0`, `-1`, `abc`; accepts
  `1` and `2147483647`.
- API (fake db is enough): `GET /api/products/99999999999` is 400 and the db is not queried.
- `orderSchema` rejects `productId: 2147483648` and accepts `2147483647`.
- Integration: `POST /api/orders` with `productId: 2147483647` is 422 `unknown_product`.
Catches: out-of-range ids becoming a 500 from a PostgreSQL integer error.

### A6. Product detail success (API + integration)
- API (fake db): `query` resolves one row; expect 200 and the exact public shape
  (`id, sku, name, description, price{amountMinor,currency}, imageUrl, stock`); assert the query was
  called with the parameter array `[1]` (parameterised, not interpolated).
- Integration: after seeding, look the id up **by SKU** (do not assume id 1: a failed insert burns
  a sequence value, which tripped the ad-hoc script once); expect 200, integer `amountMinor`,
  currency `BDT`, stock equal to the database value. Missing id (valid int4) is 404.

### A7. Quantity input (frontend, `QuantityInput.jsx` / `Cart.jsx`)
Use React Testing Library with `userEvent`. Add a product to the cart, open the cart, then:
1. Clear the quantity field: the line is still present and the quantity state is unchanged.
2. Clear it and type `3`: quantity becomes 3.
3. Type a number above `min(stock, 20)`: it is clamped and the message `Only N available` shows.
4. Type `0`: it clamps to 1 and the line is NOT removed.
5. Fractional or non-numeric input does not change the quantity; on blur the field shows the last
   committed value.
6. Only the `Remove <name>` button removes a line.
Reducer (`cart.test.js`): `setQuantity` ignores non-integers and unknown product ids, and clamps.

### A8. Product-detail page does not exist
The frontend has no product detail view (only the listing), so there is nothing to test there.
Decide whether the assignment needs one before writing tests for it.

## B. Priority 2 specs

### B1. Mixed currency and order currency (integration)
Place an order for a BDT product: `total.currency` is `BDT`. Set one product to another currency
with a direct `UPDATE`, order both: 422 `mixed_currency`, and stock is unchanged.

### B2. Migrations 002 and 003 (integration)
After migrating: index `order_items_product_id_idx` exists (`pg_indexes`); `products.currency` has
a null `column_default`; inserting a product without a currency fails; re-running migrations
applies nothing. Migration 003 is a no-op when `shopnest_app` does not exist. The role
privileges themselves are checked by `deploy/scripts/verify-stack.sh`, not by vitest, because the
role only exists in the Compose stack.

### B3. Seed guard (unit, new `seed.test.js`)
Subject: `assertSeedAllowed` in `backend/src/seed.js`. Table: `development` and `test` allowed;
`production`, `staging` and an unset `NODE_ENV` throw; `production` with `ALLOW_PRODUCTION_SEED`
set to `true` is allowed; any other value of that variable (`1`, `yes`) still throws.

### B4. formatMoney (frontend)
Beyond the three tests already in `format.test.js`: a second currency code formats with that code;
`currency` is required; remember `Intl` uses a non-breaking space (U+00A0). Cart: a product priced
in another currency shows that currency in the line and the total.

## C. Existing tests I had to touch (please review these first)
These changed only to follow approved behaviour, not to add coverage.
| File | Change | Why |
|---|---|---|
| `backend/test/config.test.js` | expected object now includes the `db` block | new config fields |
| `backend/test/db.integration.test.js` | setup uses `createTestDatabase` and `drop()`; no `DROP SCHEMA public` | approved test isolation |
| `frontend/test/format.test.js` | rewritten: constant check removed; exact `en-IN` strings with U+00A0 | currency now comes from the API; locale is `en-IN` |
| `frontend/test/cart.test.js` | "removes a line when quantity is set below 1" now expects a clamp to 1 | approved quantity decision |

## D. Remaining gaps from the Phase 2 review (not specified above)
- `GET /health` is asserted in both the API and integration suites; keep one or make them differ.
- Integration tests hard-code seed values (stock 40, prices 79900/49900/219900); read them from the
  seed data instead.
- `config.test.js` mirrors the implementation; decide if it earns its place.
- `mergeItems` is tested in `validation.test.js`; it belongs with the orders code.
- `validateCustomer` has two shallow tests; add whitespace-only and edge emails.
- Not tested anywhere: graceful shutdown (checked by hand once), migration rollback on a failing
  file, opposite-order concurrent locking, logger redaction.

## E. Exact test cases to implement (checklist)
Same behaviours as sections A and B, written as the test you would add. `it(...)` titles are
suggestions. IDs are for tracking only. Nothing here exists yet; tick each when you have written
it, run it, and can explain what it would catch if it failed.
Conventions: integration tests go in `backend/test/db.integration.test.js` (or a new
`*.integration.test.js` using `createTestDatabase`); never assume product id 1, look ids up by SKU;
read prices and stock from the database or `SEED_PRODUCTS` instead of hard-coding them.

### Backend, unit (no database)
| ID | File | `it(...)` | Arrange / act | Assert |
|---|---|---|---|---|
| U1 | `test/test-db-guard.test.js` | rejects a database name that does not end in `_test` | `assertSafeTestDatabase('postgres://u:p@127.0.0.1:5432/shopnest')` | throws, message contains `_test` |
| U2 | same | rejects a non-loopback host | `.../shopnest_test` on `db.example.internal`, env `{}` | throws, message contains `non-loopback` |
| U3 | same | allows a non-loopback host only with the explicit opt-in | same URL, env `{ ALLOW_REMOTE_TEST_DATABASE: 'true' }` | returns `{ database: 'shopnest_test', host }` |
| U4 | same | rejects malformed, empty and non-postgres URLs | `'not a url'`, `''`, `'mysql://u:p@127.0.0.1/x_test'` | each throws |
| U5 | same | never puts the password in the error message | rejected URL containing a recognisable password | `error.message` does not contain it |
| U6 | same | accepts a loopback `_test` URL | `postgres://u:p@127.0.0.1:55432/shopnest_test` | returns the database and host |
| U7 | `test/validation.test.js` | `idSchema` rejects out-of-range and non-decimal ids | `99999999999`, `2147483648`, `1e2`, `0x10`, `' 1'`, `0`, `-1`, `abc` | each `safeParse(...).success === false` |
| U8 | same | `idSchema` accepts the int4 bounds | `'1'`, `'2147483647'` | `parse` returns `1` and `2147483647` |
| U9 | same | `orderSchema` bounds `productId` | `2147483648` vs `2147483647` | first rejected, second accepted |
| U10 | `test/seed.test.js` | `assertSeedAllowed` allows development and test | env `{NODE_ENV:'development'}`, `{NODE_ENV:'test'}` | does not throw |
| U11 | same | blocks production, staging and an unset `NODE_ENV` | `production`, `staging`, `{}` | throws, message contains `Refusing to seed` |
| U12 | same | production needs the exact flag value | `ALLOW_PRODUCTION_SEED` = `'1'`, `'yes'`, `'TRUE'` vs `'true'` | first three throw, `'true'` does not |
| U13 | `test/config.test.js` | reads the `DB_*` variables | env with `DB_POOL_MAX`, `DB_CONNECTION_TIMEOUT_MS`, `DB_STATEMENT_TIMEOUT_MS` | `config.db` has those numbers; non-numeric values fall back to 5000/10000/10 |
| U14 | `test/api.test.js` | `GET /api/products/:id` returns the product (success path) | fake `query` resolves one row (use the existing `productRow`) | status 200; body equals the public shape; `query` was called with the id as a parameter array (`[1]`), not interpolated |
| U15 | same | `GET /api/products/99999999999` is rejected before the database | fake `query` | 400 and `query` not called |

### Backend, integration (PostgreSQL via `deploy/docker-compose.test.yml`)
| ID | `it(...)` | Arrange / act | Assert |
|---|---|---|---|
| I1 | two test databases use different schemas and leave `public` alone | `createTestDatabase(url)` twice; migrate only the first | schemas differ; second schema has 0 tables; `public` has 0 tables; after `drop()` the schema is gone |
| I2 | an idle connection dropped by the server is logged, not fatal | `createDb(url, { logger })` with a recording logger; run one query; from a second connection `pg_terminate_backend` the idle one; wait ~500 ms | no uncaught error; logger received `idle database client error`; `SELECT 1` still succeeds |
| I3 | a statement over the timeout is cancelled | `createDb(url, { statementTimeoutMs: 300 })`; `SELECT pg_sleep(3)` | rejects with a message matching `statement timeout` |
| I4 | an exhausted pool fails fast | `createDb(url, { max: 1, connectionTimeoutMs: 300 })`; hold the only client in `withTransaction`; run a second query | rejects with `timeout`, in well under 2 s |
| I5 | `createDb` rejects an unsafe `searchPath` | `createDb(url, { searchPath: 'bad"; DROP SCHEMA public' })` | throws before connecting |
| I6 | migrations 002 and 003 leave the expected schema | after `runMigrations` | `pg_indexes` has `order_items_product_id_idx`; `products.currency` has a null `column_default`; inserting a product without a currency throws; re-running applies nothing |
| I7 | `GET /api/products/:id` returns a seeded product | look the id up by SKU; GET it | 200; integer `price.amountMinor`; `price.currency` is `'BDT'`; `stock` equals the database value |
| I8 | a valid but missing id is a 404 | GET `/api/products/2147483647` | 404 |
| I9 | an order for an int4-maximum product id is an unknown product | POST with `productId: 2147483647` | 422 `unknown_product` |
| I10 | **order currency comes from the products** | order one product; read its `currency` from the database | `res.body.total.currency` equals that currency, and the `orders` row's `currency` matches |
| I11 | **mixed currencies are rejected and change nothing** | `UPDATE products SET currency = 'USD'` for one of two products; order both | 422 `mixed_currency`; stock of both products unchanged; 0 rows in `orders` |
| I12 | **`withTransaction` discards a connection whose ROLLBACK fails** (missing item 1) | inside `withTransaction`, run `SELECT pg_terminate_backend(pg_backend_pid())` so the work, and then the ROLLBACK, fail | the call rejects with the original error (not a rollback error); the next `db.query('SELECT 1')` succeeds, so the broken client was not reused. Verify while writing it: the pool may also log an idle-client error, so give it a recording logger |

### Backend, script (child process)
| ID | `it(...)` | Arrange / act | Assert |
|---|---|---|---|
| S1 | **`scripts/seed.js` refuses to run in production before touching the database** (missing item 2) | `execFileSync('node', ['scripts/seed.js'], { cwd: <backend dir>, env: { PATH, DATABASE_URL: 'postgres://u:p@127.0.0.1:9/none_test', NODE_ENV: 'production' } })` inside try/catch | exit status 1; stderr contains `Refusing to seed`; stderr has no connection error, so no connection was attempted |
| S2 | the same with `NODE_ENV` unset | same, without `NODE_ENV` | exit status 1 and `Refusing to seed` |

### Frontend
| ID | File | `it(...)` | Arrange / act | Assert |
|---|---|---|---|---|
| F1 | `test/quantity-input.test.jsx` | clearing the field does not remove the line | render `Cart` in a reducer harness with one line, quantity 2; `userEvent.clear` the field | line still rendered; committed quantity still 2 |
| F2 | same | clearing then typing 3 commits 3 | clear, `type('3')` | committed quantity 3 |
| F3 | same | a value above stock is clamped and explained | stock 5; clear, type `9` | committed 5; text `Only 5 available` visible |
| F4 | same | the per-line maximum of 20 applies when stock is larger | stock 500; type `45` | committed 20 |
| F5 | same | typing 0 clamps to 1 and keeps the line | type `0` | committed 1; product name still rendered |
| F6 | same | a fractional value is not committed and blur restores the last good value | `click` the field, `paste('1.5')` (typing character by character commits `1` first), then `tab()` | committed quantity unchanged; field shows the previous value |
| F7 | same | blur on an empty field restores the value | clear, `tab()` | field shows the committed value |
| F8 | same | only the Remove button removes a line | click `Remove <name>` | line gone |
| F9 | `test/cart.test.js` | `setQuantity` ignores non-integers and unknown product ids | actions with `NaN`, `1.5`, and `productId: 99` | state unchanged (same array reference for the first two) |
| F10 | `test/format.test.js` | formats another currency with its own code or symbol | `formatMoney(123456, 'USD')` | the exact string, noting the `$` symbol and the non-breaking space rules of `Intl` |
| F11 | `test/format.test.js` | the currency argument is required | `formatMoney(100)` | decide what you want (throws or renders `undefined`) and pin that behaviour |
| F12 | `test/app.test.jsx` or the quantity file | the cart line and total use the currency from the API data | product priced in `USD` | line and `Total:` show the USD formatting and no `BDT` |

### Not a vitest test (kept as a script)
Role privileges, including `UPDATE (stock)` only: `deploy/scripts/verify-stack.sh`
(`docs/evidence/phase2/stack-verification.txt`, 38 checks). Graceful shutdown stays a manual check
until you decide whether to automate it (section D).
