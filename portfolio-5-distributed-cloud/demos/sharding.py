"""A sharded MongoDB cluster: set-up, hashed distribution, targeted and scatter-gather queries, a hot spot, a shard failure."""

import time
from datetime import datetime, timezone

import psycopg
from pymongo import MongoClient
from pymongo.errors import OperationFailure, PyMongoError
from tabulate import tabulate

from common import check, compose, env, log, section, summary

MEMBERS = {"config": ("cfg", 37031, True), "shard_a": ("shard_a", 37032, False), "shard_b": ("shard_b", 37033, False)}
SPLIT = datetime(2025, 11, 1, tzinfo=timezone.utc)


def mongosh(service, port, script, extra_env=None):
    args = ["exec", "-T"]
    for key, val in (extra_env or {}).items():
        args += ["-e", f"{key}={val}"]
    return compose("mongo-sharding", *args, service, "mongosh", "--port", str(port), "--quiet", "--eval", script,
                   check=False)


def wait_primary(service, port, timeout=120):
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < timeout:
        out = mongosh(service, port, "db.hello().isWritablePrimary").stdout.strip()
        if out.endswith("true"):
            return time.perf_counter() - t0
        time.sleep(1)
    raise TimeoutError(f"{service} has no primary")


def router():
    return MongoClient("127.0.0.1", 37030, username="root", password=env("MONGO_ROOT_PASSWORD"), authSource="admin",
                       tz_aware=True, serverSelectionTimeoutMS=30000)


def set_up():
    section("1. Building the cluster: config server, two shards, mongos")
    for service, (name, port, configsvr) in MEMBERS.items():
        script = (f"try {{ rs.status().ok }} catch (e) {{ rs.initiate({{_id: '{name}', "
                  f"{'configsvr: true, ' if configsvr else ''}members: [{{_id: 0, host: 'localhost:{port}'}}]}}).ok }}")
        mongosh(service, port, script)
        log("set", f"{name}: primary after {wait_primary(service, port):.1f} s")
    created = mongosh("router", 37030,
                      "db.getSiblingDB('admin').createUser({user: 'root', pwd: process.env.ROOT_PWD, roles: ['root']}).ok",
                      {"ROOT_PWD": env("MONGO_ROOT_PASSWORD")})
    log("set", "first user created through the localhost exception" if created.returncode == 0
        else "root user already exists (localhost exception closed)")
    admin = router().admin
    log("set", f"mongos {admin.command('buildInfo')['version']}")
    for name, port in (("shard_a", 37032), ("shard_b", 37033)):
        admin.command("addShard", f"{name}/localhost:{port}", name=name)
    shards = admin.command("listShards")["shards"]
    log("set", "shards: " + ", ".join(f"{s['_id']} ({s['host']})" for s in shards))
    check("both shards joined the cluster", {s["_id"] for s in shards} == {"shard_a", "shard_b"})


def per_shard(coll):
    return {d["shard"]: d["count"] for d in coll.aggregate([{"$collStats": {"count": {}}}])}


def load(db):
    section("2. Encounters sharded on a hashed patient_id")
    client = db.client
    client.admin.command("shardCollection", "itoju.encounters", key={"patient_id": "hashed"})
    with psycopg.connect(host="127.0.0.1", port=55432, dbname="itoju", user="postgres",
                         password=env("POSTGRES_PASSWORD")) as pg:
        rows = pg.execute("""SELECT e.encounter_id, e.patient_id, f.facility_code, e.started_at, e.encounter_type_code
                               FROM itoju.encounter e JOIN itoju.facility f USING (facility_id)
                              WHERE e.encounter_id % 7 = 0 ORDER BY e.encounter_id""").fetchall()
    docs = [{"_id": r[0], "patient_id": r[1], "facility": r[2], "started_at": r[3], "type": r[4], "created_at": r[3]}
            for r in rows]
    for i in range(0, len(docs), 5000):
        db.encounters.insert_many(docs[i:i + 5000], ordered=False)
    counts = per_shard(db.encounters)
    uuid = client.config.collections.find_one({"_id": "itoju.encounters"})["uuid"]
    chunks = {c["_id"]: c["n"] for c in client.config.chunks.aggregate(
        [{"$match": {"uuid": uuid}}, {"$group": {"_id": "$shard", "n": {"$sum": 1}}}])}
    print(tabulate([[s, counts.get(s, 0), f"{100 * counts.get(s, 0) / len(docs):.1f}%", chunks.get(s, 0)]
                    for s in sorted(counts)], headers=["shard", "encounters", "share", "chunks"]))
    log("shd", f"{len(docs)} encounters (every seventh from PostgreSQL) loaded through mongos")
    check("a hashed patient_id spreads encounters evenly", all(0.4 < c / len(docs) < 0.6 for c in counts.values()),
          ", ".join(f"{s} {c}" for s, c in sorted(counts.items())))
    return docs


def routing(db, docs):
    section("3. Targeted against scatter-gather queries, explained at mongos")
    patient = docs[0]["patient_id"]
    targeted = db.command("explain", {"find": "encounters", "filter": {"patient_id": patient}}, verbosity="queryPlanner")
    scatter = db.command("explain", {"find": "encounters", "filter": {"facility": "LAG-IKJ",
                                                                      "started_at": {"$gte": SPLIT}}},
                         verbosity="queryPlanner")
    for label, plan in (("one patient's visits", targeted), ("one branch's visits", scatter)):
        wp = plan["queryPlanner"]["winningPlan"]
        log("shd", f"{label}: {wp['stage']} on {', '.join(s['shardName'] for s in wp['shards'])}")
    check("a query on the shard key is routed to one shard", targeted["queryPlanner"]["winningPlan"]["stage"] == "SINGLE_SHARD")
    check("a query without the shard key is sent to every shard and merged",
          scatter["queryPlanner"]["winningPlan"]["stage"] == "SHARD_MERGE"
          and len(scatter["queryPlanner"]["winningPlan"]["shards"]) == 2)
    return targeted["queryPlanner"]["winningPlan"]["shards"][0]["shardName"], patient


def hot_spot(db, docs):
    section("4. A monotonically increasing shard key: every new write lands on one shard")
    admin = db.client.admin
    admin.command("shardCollection", "itoju.encounters_by_time", key={"created_at": 1})
    admin.command("split", "itoju.encounters_by_time", middle={"created_at": SPLIT})
    owner = db.client.config.chunks.find_one({"uuid": db.client.config.collections.find_one(
        {"_id": "itoju.encounters_by_time"})["uuid"], "min.created_at": SPLIT})["shard"]
    other = "shard_b" if owner == "shard_a" else "shard_a"
    admin.command("moveChunk", "itoju.encounters_by_time", find={"created_at": datetime(2025, 1, 1, tzinfo=timezone.utc)},
                  to=other)
    log("shd", f"ranged key created_at: chunk before {SPLIT:%Y-%m-%d} on {other}, chunk from {SPLIT:%Y-%m-%d} onwards on {owner}")
    history = [d for d in docs if d["created_at"] < datetime(2026, 11, 1, tzinfo=timezone.utc)]
    db.encounters_by_time.insert_many(history, ordered=False)
    before_ranged, before_hashed = per_shard(db.encounters_by_time), per_shard(db.encounters)
    new = [{"_id": 10_000_000 + i, "patient_id": 900_000 + (i * 7919) % 60_000, "facility": "LAG-IKJ",
            "started_at": datetime(2026, 11, 14, 8, tzinfo=timezone.utc), "type": "CONSULTATION",
            "created_at": datetime(2026, 11, 14, 8, tzinfo=timezone.utc).replace(second=i % 60, microsecond=i)}
           for i in range(5000)]
    db.encounters_by_time.insert_many([dict(d) for d in new], ordered=False)
    db.encounters.insert_many([dict(d) for d in new], ordered=False)
    after_ranged, after_hashed = per_shard(db.encounters_by_time), per_shard(db.encounters)
    rows = []
    for label, before, after in (("ranged created_at", before_ranged, after_ranged),
                                 ("hashed patient_id", before_hashed, after_hashed)):
        for shard in ("shard_a", "shard_b"):
            rows.append([label, shard, before.get(shard, 0), after.get(shard, 0), after.get(shard, 0) - before.get(shard, 0)])
    print(tabulate(rows, headers=["shard key", "shard", "documents before", "after 5,000 new visits", "new writes received"]))
    ranged_new = {r[1]: r[4] for r in rows if r[0].startswith("ranged")}
    hashed_new = {r[1]: r[4] for r in rows if r[0].startswith("hashed")}
    check("with a ranged time key all 5,000 new writes went to one shard", max(ranged_new.values()) == 5000,
          ", ".join(f"{s} {n}" for s, n in sorted(ranged_new.items())))
    check("with a hashed key the same writes were shared", all(1500 < n < 3500 for n in hashed_new.values()),
          ", ".join(f"{s} {n}" for s, n in sorted(hashed_new.items())))


def shard_down(db, healthy_shard, patient):
    section("5. One shard down")
    down = "shard_b" if healthy_shard == "shard_a" else "shard_a"
    port = 37033 if down == "shard_b" else 37032
    compose("mongo-sharding", "stop", down)
    log("sys", f"docker compose stop {down}")
    visits = list(db.encounters.find({"patient_id": patient}, max_time_ms=15000))
    log("shd", f"patient {patient} (on {healthy_shard}): {len(visits)} visits returned")
    try:
        total = db.encounters.count_documents({}, maxTimeMS=15000)
        whole_failed, total_detail = False, f"returned {total}"
    except PyMongoError as exc:
        whole_failed, total_detail = True, type(exc).__name__
        log("shd", f"count of all encounters: {type(exc).__name__}: {str(exc)[:150]}")
    partial = sum(1 for _ in db.encounters.find({}, {"_id": 1}, allow_partial_results=True, max_time_ms=30000))
    log("shd", f"the same query with allowPartialResults: {partial} encounters, from {healthy_shard} only")
    check("queries for data on the healthy shard still work", len(visits) > 0)
    check("a query that needs every shard fails", whole_failed, total_detail)
    check("allowPartialResults returns the healthy shard's share", partial > 0)
    compose("mongo-sharding", "start", down)
    log("sys", f"docker compose start {down}: primary again after {wait_primary(down, port):.1f} s")
    total = db.encounters.count_documents({}, maxTimeMS=30000)
    check("with both shards back the whole collection is readable", total > partial, f"{total} encounters")


def main():
    set_up()
    db = router().itoju
    db.drop_collection("encounters")
    db.drop_collection("encounters_by_time")
    docs = load(db)
    healthy, patient = routing(db, docs)
    hot_spot(db, docs)
    shard_down(db, healthy, patient)
    summary()


if __name__ == "__main__":
    main()
