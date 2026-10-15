#!/bin/bash
# Creates one database + owner per service on first boot of the shared Postgres.
# Runs only when the data volume is empty (docker-entrypoint-initdb.d semantics).
set -euo pipefail

create_db() {
  local db="$1" user="$2" password="$3"
  echo "Creating database '${db}' owned by '${user}'"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE USER ${user} WITH PASSWORD '${password}';
    CREATE DATABASE ${db} OWNER ${user};
SQL
}

create_db airflow      "$AIRFLOW_DB_USER"      "$AIRFLOW_DB_PASSWORD"
create_db ducklake     "$DUCKLAKE_DB_USER"     "$DUCKLAKE_DB_PASSWORD"
create_db polaris      "$POLARIS_DB_USER"      "$POLARIS_DB_PASSWORD"
create_db openmetadata "$OPENMETADATA_DB_USER" "$OPENMETADATA_DB_PASSWORD"

# Polaris's bootstrap script cannot create its schema as a non-superuser; pre-create it.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname polaris   -c "CREATE SCHEMA polaris_schema AUTHORIZATION ${POLARIS_DB_USER};"
