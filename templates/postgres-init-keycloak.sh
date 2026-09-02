#!/bin/sh
# Creates the Keycloak database on first postgres init (used by the
# production compose override). Runs only while the data volume is empty;
# to re-run it later, create the user/database manually with psql.
set -e

if [ -z "${KEYCLOAK_DB_PASSWORD:-}" ]; then
  echo "KEYCLOAK_DB_PASSWORD not set; skipping keycloak database"
  exit 0
fi

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
CREATE USER keycloak WITH PASSWORD '$KEYCLOAK_DB_PASSWORD';
CREATE DATABASE keycloak OWNER keycloak;
SQL
