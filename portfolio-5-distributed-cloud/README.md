# Portfolio 5: Distributed and Cloud Database Exercise

How Itoju Clinics would spread its database across regions and keep it in Nigeria, with two working clusters that test the parts of the design a single machine can test: PostgreSQL streaming replication with a failover, and a sharded MongoDB cluster.

## Required evidence

- [x] Distributed and cloud design based on the same case study: [architecture.md](architecture.md) (fragmentation, allocation, replication, consistency, CAP and PACELC, sharding, architecture, cloud deployment under the NDPA 2023, and limits)
- [x] Working setup: a primary with a synchronous and an asynchronous standby ([pg-replication/](pg-replication/)), and a sharded cluster with a config server, two shards and `mongos` ([mongo-sharding/](mongo-sharding/)), with reproducible commands in [setup.md](setup.md)
- [x] Replication evidence: streaming to both standbys, lag, read-only standbys and the cost of synchronous commit ([p5-01](outputs/p5-01-pg-replication.txt), sections 1, 2 and 4)
- [x] Consistency evidence: a stale read from the asynchronous standby, and a commit that waits for its synchronous standby ([p5-01](outputs/p5-01-pg-replication.txt), sections 3 and 5)
- [x] Availability evidence: a failover with no acknowledged write lost ([p5-01](outputs/p5-01-pg-replication.txt), section 6) and a cluster with one shard down ([p5-02](outputs/p5-02-mongo-sharding.txt), section 5)
- [x] Sharding evidence: hashed distribution, targeted and scatter-gather routing, and a hot spot from a ranged time key ([p5-02](outputs/p5-02-mongo-sharding.txt), sections 2 to 4)
- [x] Deployment evidence: the Compose files and start-up scripts, and the cloud deployment model in [architecture.md](architecture.md#cloud-deployment-and-the-law)
- [x] Screenshots: [synchronous and asynchronous standbys streaming](outputs/screenshots/p5-16-replication.png), [the failover](outputs/screenshots/p5-17-failover.png), [the shard distribution](outputs/screenshots/p5-18-shard-distribution.png) and [targeted against scatter-gather routing](outputs/screenshots/p5-19-routing.png)

## How I implemented it

**The design.** [architecture.md](architecture.md) fragments clinical data horizontally by region (South-West, North, South-East) and splits identity data from clinical data vertically. It places each region's primary in its own in-country data centre, with a synchronous standby in the same city and asynchronous copies in the other. It then says what consistency each kind of data gets, how the system behaves in a partition, and how it would be deployed under the NDPA 2023. Every figure in it comes from the two evidence files.

**PostgreSQL replication.** [pg-replication/compose.yaml](pg-replication/compose.yaml) runs three PostgreSQL 16 containers. [init-primary.sh](pg-replication/init-primary.sh) creates a replication role and the `appointment_request` table used by the demonstrations, and sets `synchronous_standby_names = 'FIRST 1 (standby_sync)'`. [start-standby.sh](pg-replication/start-standby.sh) clones the primary with `pg_basebackup -R` into a replication slot on each standby's first start, and names the standby in `primary_conninfo` so the primary can tell `sync` from `async`. [demos/replication.py](demos/replication.py) then runs six demonstrations against the cluster:

1. replication and lag
2. a refused write on a standby
3. a stale read with replay paused
4. commit latency for each `synchronous_commit` setting
5. a commit waiting on a stopped synchronous standby
6. a failover while a client keeps writing, with the outage measured as the longest gap between two acknowledged writes

**MongoDB sharding.** [mongo-sharding/compose.yaml](mongo-sharding/compose.yaml) runs a config server, two shards and `mongos`, each a single-member replica set authenticated by a shared keyfile. All of them share one network namespace, so they reach each other at `localhost:<port>`. [demos/sharding.py](demos/sharding.py) initiates the replica sets, creates the first user through the localhost exception and adds the shards. It loads every seventh encounter from the Portfolio 2 database (102,035 documents) into a collection sharded on a hashed `patient_id`, and then tests routing, a hot spot and the loss of a shard.

**The pipeline.** [run_p5.py](run_p5.py) rebuilds each cluster from empty volumes, runs its demonstration through the evidence script, and stops it. The main MongoDB is stopped for the duration to leave the clusters enough memory, and restarted at the end.

## How I tested it

| Demonstration | Checks | What they show | Evidence |
|---|---|---|---|
| PostgreSQL replication and failover | 16 of 16 | Sync and async standbys; a stale read; synchronous commit costs latency; a commit waits while the sync standby is down; failover with 1,008 acknowledged writes and none lost; a new timeline | [p5-01](outputs/p5-01-pg-replication.txt) |
| MongoDB sharded cluster | 10 of 10 | Even hashed distribution; `SINGLE_SHARD` against `SHARD_MERGE`; every new write on one shard under a ranged time key; partial results with a shard down | [p5-02](outputs/p5-02-mongo-sharding.txt) |

The main measurements:

| Measurement | Result |
|---|---|
| Median commit, `synchronous_commit` off / local / on / remote_apply (300 commits, median of 3 runs) | 1.734 / 3.600 / 4.033 / 4.375 ms |
| Booking read back from the asynchronous standby with replay paused | 0 rows |
| Failover: longest gap between two acknowledged writes | 2.61 s, of which 1 s was the deliberate pause before promoting |
| Writes acknowledged before and after failover; missing from the new primary | 463 + 545; 0 |
| Timeline before and after promotion | 00000001 → 00000002 |
| Encounters per shard, hashed `patient_id` | 50,576 (49.6%) and 51,459 (50.4%) |
| 5,000 new visits per shard, ranged `created_at` against hashed `patient_id` | 0 and 5,000 against 2,493 and 2,507 |
| Documents returned with one shard down, `allowPartialResults` | 53,069 |

To reproduce (about three minutes; the main PostgreSQL must hold the Portfolio 2 data):

```powershell
docker compose up -d --wait
.venv\Scripts\python portfolio-5-distributed-cloud\run_p5.py
```

## Contents

| Path | What it holds |
|---|---|
| [architecture.md](architecture.md) | The distributed and cloud design, with an architecture diagram |
| [setup.md](setup.md) | How each cluster is built, and the commands to build and inspect it by hand |
| [pg-replication/](pg-replication/) | Compose file and start-up scripts for the primary and the two standbys |
| [mongo-sharding/](mongo-sharding/) | Compose file for the sharded cluster |
| [demos/](demos/) | The replication and sharding demonstrations, and shared helpers |
| [run_p5.py](run_p5.py) | Rebuilds both clusters, runs everything and captures the evidence |
| [outputs/](outputs/) | Evidence |
