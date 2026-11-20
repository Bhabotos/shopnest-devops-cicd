#!/bin/sh
# Runs once, as the bootstrap superuser, on the first start of an empty data directory.
# Passwords come from the container environment and are passed to psql as variables, so they
# are never written into this file or the SQL text.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v owner_password="$DB_OWNER_PASSWORD" \
  -v app_password="$DB_APP_PASSWORD" \
  -v dbname="$POSTGRES_DB" <<'SQL'
-- Owner: runs migrations and owns every object. Not a superuser.
CREATE ROLE shopnest_owner LOGIN PASSWORD :'owner_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE;
-- Application: no DDL. Table privileges are granted explicitly by migration 003.
CREATE ROLE shopnest_app LOGIN PASSWORD :'app_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE;

ALTER DATABASE :"dbname" OWNER TO shopnest_owner;
ALTER SCHEMA public OWNER TO shopnest_owner;

REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"dbname" TO shopnest_owner, shopnest_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
