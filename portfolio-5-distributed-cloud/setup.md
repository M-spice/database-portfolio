# Building the two clusters

Both clusters run in Docker on one machine, alongside the main stack, and read their passwords from the repository's `.env` (`POSTGRES_PASSWORD`, `MONGO_ROOT_PASSWORD` and `P5_REPLICATION_PASSWORD`). Run every command from the repository root in PowerShell. [run_p5.py](run_p5.py) does all of this automatically and captures the evidence. The steps below are for building and inspecting a cluster by hand.

The sharded cluster loads its encounters from the main PostgreSQL database, so the main stack must be running with the Portfolio 2 data loaded. The two clusters need about 3 GB of the Docker VM between them, so stop the main MongoDB while they run:

```powershell
docker compose up -d --wait postgres
docker compose stop mongo
```

## PostgreSQL streaming replication

| Container | Role | Host port |
|---|---|---|
| `pg_primary` | Primary; `synchronous_standby_names = 'FIRST 1 (standby_sync)'` | 127.0.0.1:55441 |
| `pg_standby_sync` | Hot standby, synchronous | 127.0.0.1:55442 |
| `pg_standby_async` | Hot standby, asynchronous (reporting) | 127.0.0.1:55443 |

```powershell
$pgc = "portfolio-5-distributed-cloud/pg-replication/compose.yaml"
docker compose -f $pgc --env-file .env down -v          # start from empty volumes
docker compose -f $pgc --env-file .env up -d --wait
"SELECT application_name, state, sync_state FROM pg_stat_replication;" | docker compose -f $pgc --env-file .env exec -T pg_primary psql -U postgres -d itoju
```

The last command must show `standby_sync` as `sync` and `standby_async` as `async`, both `streaming`.

How it is put together:

- **The primary** ([init-primary.sh](pg-replication/init-primary.sh)) creates a `replicator` role with the `REPLICATION` attribute, adds a `pg_hba.conf` line allowing it to stream, creates the `appointment_request` table used by the demonstrations, and turns on synchronous replication with `ALTER SYSTEM`. Doing that in the init script rather than on the command line matters: the image's own initialisation commits while no standby exists yet, so a command-line setting would make it wait forever.
- **Each standby** ([start-standby.sh](pg-replication/start-standby.sh)), on first start, waits for the primary, clones it with `pg_basebackup -R -X stream` into its own replication slot, and sets `application_name` in `primary_conninfo`, so the primary can tell the two apart. It also clears the `synchronous_standby_names` it inherited from the clone, so that a promoted standby does not wait for a synchronous partner it does not have.
- **The primary keeps 256 MB of WAL** (`wal_keep_size`), so that two standbys cloning at the same moment cannot have a segment recycled under them before their slots exist.

To replay the failover by hand once the demonstration has run (or after `docker compose -f $pgc --env-file .env kill pg_primary`):

```powershell
"SELECT pg_promote();" | docker compose -f $pgc --env-file .env exec -T pg_standby_sync psql -U postgres -d itoju
"SELECT pg_is_in_recovery(), substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS timeline;" | docker compose -f $pgc --env-file .env exec -T pg_standby_sync psql -U postgres -d itoju
```

Stop the cluster with `docker compose -f $pgc --env-file .env stop`; remove it, data included, with `down -v`.

## MongoDB sharded cluster

| Container | Role | Port |
|---|---|---|
| `net` | Owns the network namespace and publishes the ports; generates the shared keyfile | – |
| `config` | Config-server replica set `cfg` | 37031 |
| `shard_a` | Shard replica set `shard_a` | 37032 |
| `shard_b` | Shard replica set `shard_b` | 37033 |
| `router` | `mongos` | 127.0.0.1:37030 |

```powershell
$mc = "portfolio-5-distributed-cloud/mongo-sharding/compose.yaml"
docker compose -f $mc --env-file .env down -v
docker compose -f $mc --env-file .env up -d
```

Every member runs with `network_mode: service:net`. All five processes therefore share one network namespace and can address each other as `localhost:<port>`, which is also the address the host uses. Stopping a member does not remove the network the others depend on. Members authenticate to each other with a keyfile that the `net` container generates on first start and keeps in a Docker volume.

The cluster is initialised by [demos/sharding.py](demos/sharding.py), which runs these steps in order:

1. `rs.initiate()` on the config server (`configsvr: true`) and on each shard, each with a single member at `localhost:<port>`, run through `docker compose exec` inside the namespace.
2. The first user, `root`, created on `mongos` through the **localhost exception**. That is the only way to create a user while none exists, and it closes as soon as one does. The script simply attempts `createUser`, because `getUsers` is not allowed under the exception.
3. `addShard` for `shard_a/localhost:37032` and `shard_b/localhost:37033`, then `shardCollection` for `itoju.encounters` on a hashed `patient_id`.

To look at the cluster afterwards, with `.env` closed on screen:

```powershell
docker compose -f $mc --env-file .env exec router mongosh --port 37030 -u root -p
```

then `sh.status()` or `use itoju; db.encounters.getShardDistribution()`.

## Afterwards

```powershell
docker compose -f $mc --env-file .env stop
docker compose start mongo
```

A single machine has no real network between these containers. Stopping a container is the closest it can come to losing a server or a link, and nothing here measures network latency between cities. [architecture.md](architecture.md) says what that leaves undemonstrated.
