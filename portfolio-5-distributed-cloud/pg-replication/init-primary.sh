#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPLICATION_PASSWORD}';
  CREATE TABLE appointment_request (
    request_no   bigint PRIMARY KEY,
    hospital_no  text NOT NULL,
    branch       text NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT now()
  );
  ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (standby_sync)';
EOSQL
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
