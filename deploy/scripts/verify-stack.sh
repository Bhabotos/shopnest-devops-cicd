#!/usr/bin/env bash
# Verifies the local dev stack end to end in a THROWAWAY Compose project:
#   health checks reach "healthy", the database is isolated, roles are least-privilege,
#   and data survives a stop/start (named volume persistence).
#
# Safety: the project name is fixed below and differs from the dev project (shopnest-dev), so
# `down -v` here can never delete your development volume. Passwords are random, exist only in
# this process, and are never printed. Before anything is created, a preflight refuses to run
# unless Docker is the local engine (no DOCKER_HOST, local unix socket or local named pipe), and
# the db container's Compose project is confirmed before its first start and again once it is
# healthy, in both cases before migrate, seed or any other database write.
set -euo pipefail

PROJECT="shopnest-verify"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/deploy/docker-compose.dev.yml")

POSTGRES_PASSWORD="$(openssl rand -hex 12)"
DB_OWNER_PASSWORD="$(openssl rand -hex 12)"
DB_APP_PASSWORD="$(openssl rand -hex 12)"
export POSTGRES_PASSWORD DB_OWNER_PASSWORD DB_APP_PASSWORD
export BACKEND_HOST_PORT=3199 FRONTEND_HOST_PORT=8099 APP_VERSION=verify GIT_SHA=verify
API="http://127.0.0.1:${FRONTEND_HOST_PORT}"

PASSED=0
pass() { PASSED=$((PASSED + 1)); echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# Runs before the cleanup trap is installed: if Docker is not provably the local engine, nothing is
# created, nothing is removed, and no `down -v` is ever sent to an unexpected daemon.
# It never switches contexts (no `docker context use`, no --context flag): it only reports the
# active context and refuses to continue unless that context's endpoint is local.
docker_preflight() {
  step "docker safety preflight"
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    fail "refusing: DOCKER_HOST is set and overrides the Docker context. Unset it and run again"
  fi
  pass "DOCKER_HOST is not set"

  local context endpoint
  context="$(docker context show)" || fail "cannot read the active Docker context"
  echo "Docker context (active): $context"
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    echo "note: DOCKER_CONTEXT is set in this shell and selects the context above; this script never switches contexts"
  fi

  endpoint="$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}')" \
    || fail "cannot inspect Docker context '$context'"
  case "$endpoint" in
    unix://* | npipe:////./pipe/*)
      # Local engine only: a unix socket, or a named pipe on this machine ("." is the local host).
      echo "Docker endpoint: $endpoint"
      pass "Docker endpoint is local (${endpoint%%://*})"
      ;;
    "")
      fail "refusing: context '$context' has no Docker endpoint"
      ;;
    *)
      # tcp://, ssh://, or a named pipe on another host: not provably local, so fail closed.
      echo "Docker endpoint scheme: ${endpoint%%://*} (host not printed)"
      fail "refusing: the endpoint is not provably local; only unix:// sockets and local npipe:////./pipe/ names are accepted"
      ;;
  esac
}
docker_preflight

cleanup() {
  step "cleanup (throwaway project $PROJECT only)"
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

json_get() { node -p "JSON.parse(process.argv[1]).$2" "$1"; }
cid() { "${COMPOSE[@]}" ps -a -q "$1"; }
health_of() { docker inspect -f '{{.State.Health.Status}}' "$(cid "$1")"; }

wait_healthy() {
  local service="$1" limit="${2:-150}" start=$SECONDS status=""
  while (( SECONDS - start < limit )); do
    status="$(health_of "$service" 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then
      pass "$service healthy after $((SECONDS - start))s"
      return 0
    fi
    sleep 2
  done
  fail "$service did not become healthy within ${limit}s (last status: ${status:-unknown})"
}

psql_as() { # psql_as <role> <sql>   (local socket inside the db container; no password needed)
  "${COMPOSE[@]}" exec -T db psql -U "$1" -d shopnest -v ON_ERROR_STOP=1 -tA -c "$2"
}

expect_denied() { # expect_denied <description> <sql>
  if psql_as shopnest_app "$2" >/dev/null 2>&1; then
    fail "app role was ALLOWED to: $1"
  fi
  pass "app role denied: $1"
}

assert_throwaway_db() { # refuse to attempt destructive-looking statements anywhere but the throwaway project
  local label
  label="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(cid db)")"
  [[ "$PROJECT" == "shopnest-verify" && "$label" == "$PROJECT" ]] \
    || fail "refusing: the db container belongs to project '${label:-unknown}', not the throwaway '$PROJECT'"
}

expect_permission_denied() { # like expect_denied, but the failure must be a privilege error
  local out
  if out="$(psql_as shopnest_app "$2" 2>&1)"; then
    fail "app role was ALLOWED to: $1"
  fi
  [[ "$out" == *"permission denied"* ]] || fail "app role was refused for the wrong reason ($1): $out"
  pass "app role permission denied: $1"
}

step "start (fresh throwaway project)"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
# Stage 1: create ONLY the database container. It is not running, so nothing can write to it yet.
# Confirm it belongs to the throwaway project before its first start, because that first start runs
# the role-creation init script (deploy/db/init/01-roles.sh), which is itself a database write.
"${COMPOSE[@]}" create db >/dev/null
assert_throwaway_db
pass "target is the throwaway project $PROJECT (db container created, not started)"
# Stage 2: start ONLY the database and wait until it is healthy, then confirm the target again.
# migrate, seed, backend and frontend do not exist yet; stage 3 starts them.
"${COMPOSE[@]}" up -d db >/dev/null
wait_healthy db
assert_throwaway_db
pass "target re-confirmed after the db became healthy, before migrate, seed or any other write"
# Stage 3: everything else. This is what starts the migrate and seed one-shot jobs, then the API.
"${COMPOSE[@]}" up --build -d >/dev/null
pass "stack started"

step "health checks"
wait_healthy db
wait_healthy backend
wait_healthy frontend
for job in migrate seed; do
  code="$(docker inspect -f '{{.State.ExitCode}}' "$(cid "$job")")"
  [[ "$code" == "0" ]] || fail "$job exited with $code"
  pass "$job one-shot job exited 0"
done

step "database isolation"
ports="$(docker inspect -f '{{json .NetworkSettings.Ports}}' "$(cid db)")"
[[ "$ports" != *HostPort* ]] || fail "db has a published port: $ports"
pass "db publishes no host port"
[[ "$(docker network inspect -f '{{.Internal}}' "${PROJECT}_internal")" == "true" ]] \
  || fail "internal network is not internal"
pass "internal network is internal:true"
nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(cid db)")"
[[ "$nets" == "${PROJECT}_internal " ]] || fail "db is attached to: $nets"
pass "db attached only to the internal network"

step "non-root containers"
[[ "$("${COMPOSE[@]}" exec -T backend id -un)" == "node" ]] || fail "backend not running as node"
pass "backend runs as node"
[[ "$("${COMPOSE[@]}" exec -T frontend id -un)" == "nginx" ]] || fail "frontend not running as nginx"
pass "frontend runs as nginx"

step "database roles"
[[ "$(psql_as shopnest_admin "SELECT rolsuper FROM pg_roles WHERE rolname='shopnest_app'")" == "f" ]] || fail "app role is superuser"
[[ "$(psql_as shopnest_admin "SELECT rolsuper FROM pg_roles WHERE rolname='shopnest_owner'")" == "f" ]] || fail "owner role is superuser"
pass "app and owner roles are not superusers"
[[ "$(psql_as shopnest_app "SELECT count(*) FROM products")" == "8" ]] || fail "app role cannot read 8 seeded products"
pass "app role can read products"
expect_denied "CREATE TABLE" "CREATE TABLE verify_probe(i int)"
expect_denied "DROP TABLE products" "DROP TABLE products"
expect_denied "ALTER TABLE products" "ALTER TABLE products ADD COLUMN probe int"
expect_denied "DELETE FROM products" "DELETE FROM products"
expect_denied "UPDATE orders" "UPDATE orders SET status='cancelled'"
expect_denied "read schema_migrations" "SELECT 1 FROM schema_migrations"
# Column-level UPDATE: only products.stock is writable by the API.
psql_as shopnest_app "UPDATE products SET stock = stock WHERE id = (SELECT min(id) FROM products)" >/dev/null \
  || fail "app role cannot update products.stock"
pass "app role can update products.stock"
expect_permission_denied "UPDATE products.price_minor" "UPDATE products SET price_minor = 1"
expect_permission_denied "UPDATE products.name" "UPDATE products SET name = 'x'"
expect_permission_denied "UPDATE products.currency" "UPDATE products SET currency = 'USD'"
expect_permission_denied "UPDATE products.sku" "UPDATE products SET sku = 'x'"
expect_permission_denied "UPDATE products.description" "UPDATE products SET description = 'x'"
expect_permission_denied "UPDATE products.image_url" "UPDATE products SET image_url = 'x'"
expect_permission_denied "INSERT INTO products" "INSERT INTO products (sku,name,price_minor,currency,image_url) VALUES ('x','x',1,'BDT','/x')"
[[ "$(psql_as shopnest_admin "SELECT tableowner FROM pg_tables WHERE tablename='products'")" == "shopnest_owner" ]] \
  || fail "products is not owned by shopnest_owner"
pass "tables are owned by shopnest_owner"
# G3: every application table is owned by the owner role, so the app role owns nothing it could alter.
for table in products orders order_items schema_migrations; do
  [[ "$(psql_as shopnest_admin "SELECT tableowner FROM pg_tables WHERE schemaname='public' AND tablename='$table'")" == "shopnest_owner" ]] \
    || fail "$table is not owned by shopnest_owner"
  pass "$table is owned by shopnest_owner"
done

# G1 and G2: DELETE and TRUNCATE are denied on every table the API touches. Each table is checked
# twice: from the catalog (reads privileges, changes nothing) and by attempting the statement.
# The attempts are written so that, even if a privilege were wrongly present, no data is lost:
# DELETE uses "WHERE false" (privilege is checked before any row is touched) and TRUNCATE runs
# inside BEGIN ... ROLLBACK. They only run against the throwaway project: assert_throwaway_db has
# already confirmed that twice during startup, before migrate, seed or any other write.
step "destructive statements are denied (DELETE, TRUNCATE)"
for table in products orders order_items; do
  for privilege in DELETE TRUNCATE; do
    [[ "$(psql_as shopnest_admin "SELECT has_table_privilege('shopnest_app', '$table', '$privilege')")" == "f" ]] \
      || fail "catalog: shopnest_app HAS $privilege on $table"
    pass "catalog: shopnest_app has no $privilege privilege on $table"
  done
  expect_permission_denied "DELETE FROM $table" "DELETE FROM $table WHERE false"
  expect_permission_denied "TRUNCATE $table" "BEGIN; TRUNCATE $table; ROLLBACK"
done

step "functional check through the frontend proxy"
before="$(json_get "$(curl -fsS "$API/api/products/1")" stock)"
order="$(curl -fsS -X POST "$API/api/orders" -H 'Content-Type: application/json' \
  -d '{"customer":{"name":"Verify","email":"verify@example.com","address":"1 Test Street"},"items":[{"productId":1,"quantity":2}]}')"
order_id="$(json_get "$order" id)"
after="$(json_get "$(curl -fsS "$API/api/products/1")" stock)"
[[ "$after" == "$((before - 2))" ]] || fail "stock $before -> $after, expected $((before - 2))"
pass "order placed through the proxy; stock $before -> $after"

step "roles actually in use (read from the server's own session list)"
runtime_roles="$(psql_as shopnest_admin "SELECT string_agg(DISTINCT usename, ',') FROM pg_stat_activity WHERE datname='shopnest' AND backend_type='client backend' AND pid <> pg_backend_pid()")"
[[ "$runtime_roles" == "shopnest_app" ]] || fail "client sessions use role(s): ${runtime_roles:-none}, expected only shopnest_app"
pass "the running API holds connections as shopnest_app only (not shopnest_owner or shopnest_admin)"
[[ "$(psql_as shopnest_admin "SELECT tableowner FROM pg_tables WHERE tablename='schema_migrations'")" == "shopnest_owner" ]] \
  || fail "schema_migrations is not owned by shopnest_owner, so migrations did not run as the owner"
pass "schema_migrations is owned by shopnest_owner (migrations ran as the owner)"

step "persistence: stop and start WITHOUT deleting the volume"
"${COMPOSE[@]}" down >/dev/null
docker volume inspect "${PROJECT}_pgdata" >/dev/null 2>&1 || fail "named volume was removed by down"
pass "named volume ${PROJECT}_pgdata still exists after down"
# Restart: the db container is recreated (same project, same volume) and migrate and seed run
# again, which are database writes. Use the same staged start and confirm the target before them.
"${COMPOSE[@]}" create db >/dev/null
assert_throwaway_db
pass "restart: target confirmed (db container recreated, not started)"
"${COMPOSE[@]}" up -d db >/dev/null
wait_healthy db
assert_throwaway_db
pass "restart: target re-confirmed after the db became healthy, before migrate and seed run again"
"${COMPOSE[@]}" up -d >/dev/null
wait_healthy db
wait_healthy backend
wait_healthy frontend
got="$(curl -fsS "$API/api/orders/$order_id")"
[[ "$(json_get "$got" id)" == "$order_id" ]] || fail "order lost after restart"
pass "order survived the restart"
[[ "$(json_get "$(curl -fsS "$API/api/products/1")" stock)" == "$after" ]] \
  || fail "stock reset by re-seeding after restart"
pass "stock unchanged; the idempotent seed did not reset it"
count="$(json_get "$(curl -fsS "$API/api/products")" products.length)"
[[ "$count" == "8" ]] || fail "expected 8 products after restart, found $count"
pass "no duplicate products after re-seeding"

step "result"
echo "ALL CHECKS PASSED ($PASSED)"
