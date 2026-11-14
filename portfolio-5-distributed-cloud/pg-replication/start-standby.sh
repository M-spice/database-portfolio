#!/bin/bash
# Runs as root: clone the primary once with pg_basebackup, then hand over to the image's normal entrypoint.
set -e
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h pg_primary -p 5432 -q; do sleep 1; done
  mkdir -p "$PGDATA" && chown postgres:postgres "$PGDATA" && chmod 700 "$PGDATA"
  gosu postgres env PGPASSWORD="$REPLICATION_PASSWORD" \
    pg_basebackup -h pg_primary -U replicator -D "$PGDATA" -X stream -c fast -R -C -S "$STANDBY_NAME"
  # The clone copies the primary's synchronous_standby_names; cleared so a promoted standby does not wait for itself.
  printf "%s\n" "primary_conninfo = 'host=pg_primary port=5432 user=replicator password=$REPLICATION_PASSWORD application_name=$STANDBY_NAME'" \
    "synchronous_standby_names = ''" | gosu postgres tee -a "$PGDATA/postgresql.auto.conf" > /dev/null
fi
exec docker-entrypoint.sh postgres -c hot_standby=on -c wal_level=replica -c max_wal_senders=10 \
  -c max_replication_slots=10
