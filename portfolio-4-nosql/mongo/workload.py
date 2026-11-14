"""Portfolio 2's questions asked of MongoDB: results compared with PostgreSQL, explain() before and after indexes."""

import argparse
import hashlib
import json
import statistics
import sys
import time
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

from pymongo import ASCENDING, DESCENDING
from tabulate import tabulate

from common import P4, ROOT, check, log, mongo, postgres, section, summary

sys.path.insert(0, str(ROOT / "portfolio-2-query-optimisation"))
from measure import load_workload  # noqa: E402

LAGOS = timezone(timedelta(hours=1))
PHONE = "+2340100104242"
HEAVY = "HN-0100046"
TIME_LIMIT_MS = 120_000
RUNS = 3

INDEXES = [
    ("patients", [("phones.number", ASCENDING)], "patients_phone_ix"),
    ("encounters", [("patient_id", ASCENDING), ("started_at", DESCENDING)], "encounters_patient_started_ix"),
    ("encounters", [("started_at", ASCENDING)], "encounters_started_ix"),
    ("encounters", [("diagnoses.code", ASCENDING), ("started_at", ASCENDING)], "encounters_diagnosis_started_ix"),
    ("lab_results", [("ordered_at", ASCENDING)], "lab_results_ordered_ix"),
]


def norm(value):
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat(timespec="seconds")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, (Decimal, float)):
        return round(float(value), 2)
    return value


def strip(doc):
    if isinstance(doc, dict):
        return {k: strip(v) for k, v in doc.items() if k not in ("rejectedPlans", "allPlansExecution")}
    if isinstance(doc, list):
        return [strip(v) for v in doc]
    return doc


def plan_stages(doc, inside=False, found=None):
    found = [] if found is None else found
    if isinstance(doc, dict):
        for key, value in doc.items():
            if key == "rejectedPlans":
                continue
            now_inside = inside or key == "winningPlan"
            if now_inside and key == "stage" and isinstance(value, str) and value not in found:
                found.append(value)
            plan_stages(value, now_inside, found)
    elif isinstance(doc, list):
        for value in doc:
            plan_stages(value, inside, found)
    return found


def examined(doc, totals=None):
    totals = {"docs": 0, "keys": 0} if totals is None else totals
    if isinstance(doc, dict):
        if isinstance(doc.get("executionStats"), dict):
            totals["docs"] += doc["executionStats"].get("totalDocsExamined", 0)
            totals["keys"] += doc["executionStats"].get("totalKeysExamined", 0)
        elif any(k.startswith("$") for k in doc) and "totalDocsExamined" in doc:
            totals["docs"] += doc.get("totalDocsExamined", 0)
            totals["keys"] += doc.get("totalKeysExamined", 0)
        for key, value in doc.items():
            if key not in ("executionStats", "rejectedPlans", "allPlansExecution"):
                examined(value, totals)
    elif isinstance(doc, list):
        for value in doc:
            examined(value, totals)
    return totals


def pg_sql():
    p2 = ROOT / "portfolio-2-query-optimisation" / "sql"
    base = {q["id"]: q["sql"] for q in load_workload(p2 / "workload.sql")}
    rewritten = {q["id"]: q["sql"] for q in load_workload(p2 / "workload_rewritten.sql")}
    return base, rewritten


def queries(db, pg):
    base, rewritten = pg_sql()
    start_m05, end_m05 = datetime(2025, 11, 1, tzinfo=LAGOS), datetime(2026, 11, 1, tzinfo=LAGOS)
    start_30, end_30 = datetime(2026, 10, 15, tzinfo=LAGOS), datetime(2026, 11, 14, tzinfo=LAGOS)
    year_ago, quarter = datetime(2025, 11, 14, tzinfo=LAGOS), datetime(2026, 8, 16, tzinfo=LAGOS)
    heavy_id = db.patients.find_one({"hospital_no": HEAVY}, {"_id": 1})["_id"]
    latest_visit = db.encounters.find({"patient_id": heavy_id}, {"_id": 1}).sort("started_at", -1).limit(1)[0]["_id"]

    def m01():
        return [(d["hospital_no"], d["name"]["given"], d["name"]["family"], norm(d["date_of_birth"].date()), d["phones"][0]["number"])
                for d in db.patients.find({"phones.number": PHONE},
                                          {"hospital_no": 1, "name": 1, "date_of_birth": 1, "phones.$": 1},
                                          max_time_ms=TIME_LIMIT_MS)]

    def m02():
        pid = db.patients.find_one({"hospital_no": HEAVY}, {"_id": 1})["_id"]
        cursor = db.encounters.find({"patient_id": pid}, {"started_at": 1, "facility": 1, "type": 1, "diagnoses.code": 1},
                                    max_time_ms=TIME_LIMIT_MS).sort("started_at", -1).limit(20)
        return [(norm(d["started_at"]), d["facility"], d["type"], ", ".join(x["code"] for x in d["diagnoses"])) for d in cursor]

    m05_pipeline = [
        {"$match": {"started_at": {"$gte": start_m05, "$lt": end_m05}}},
        {"$project": {"_id": 0, "facility": 1, "started_at": 1, "codes": "$diagnoses.code"}},
        {"$unwind": "$codes"},
        {"$group": {"_id": {"f": "$facility",
                            "m": {"$dateToString": {"format": "%Y-%m-%d", "timezone": "Africa/Lagos",
                                                    "date": {"$dateTrunc": {"date": "$started_at", "unit": "month",
                                                                            "timezone": "Africa/Lagos"}}}},
                            "c": "$codes"},
                    "cases": {"$sum": 1}}},
        {"$match": {"cases": {"$gte": 20}}},
        {"$sort": {"_id.f": 1, "_id.m": 1, "cases": -1, "_id.c": 1}},
    ]

    def m05():
        return [(d["_id"]["f"], d["_id"]["m"], d["_id"]["c"], d["cases"])
                for d in db.encounters.aggregate(m05_pipeline, maxTimeMS=TIME_LIMIT_MS, allowDiskUse=True)]

    m07_pipeline = [
        {"$match": {"ordered_at": {"$gte": start_30, "$lt": end_30}, "supersedes": None}},
        {"$project": {"code": "$test.code", "elapsed": {"$subtract": ["$recorded_at", "$ordered_at"]},
                      "target": {"$multiply": ["$test.target_hours", 3600000]}}},
        {"$group": {"_id": "$code", "results": {"$sum": 1}, "avg_ms": {"$avg": "$elapsed"},
                    "late": {"$sum": {"$cond": [{"$gt": ["$elapsed", "$target"]}, 1, 0]}}}},
        {"$sort": {"_id": 1}},
    ]

    def m07():
        return [(d["_id"], d["results"], round(d["avg_ms"] / 3_600_000, 2), d["late"])
                for d in db.lab_results.aggregate(m07_pipeline, maxTimeMS=TIME_LIMIT_MS)]

    def m08():
        seen = db.encounters.distinct("patient_id", {"started_at": {"$gte": year_ago}}, maxTimeMS=TIME_LIMIT_MS)
        return [(d["hospital_no"],) for d in db.patients.find({"_id": {"$nin": seen}}, {"hospital_no": 1},
                                                              max_time_ms=TIME_LIMIT_MS).sort("hospital_no", 1)]

    m09_pipeline = [
        {"$match": {"started_at": {"$gte": start_30, "$lt": end_30}}},
        {"$group": {"_id": "$patient_id", "visits": {"$sum": 1}}},
        {"$match": {"visits": {"$gte": 5}}},
        {"$lookup": {"from": "patients", "localField": "_id", "foreignField": "_id", "as": "p"}},
        {"$project": {"hospital_no": {"$first": "$p.hospital_no"}, "visits": 1}},
        {"$sort": {"visits": -1, "hospital_no": 1}},
    ]

    def m09():
        return [(d["hospital_no"], d["visits"]) for d in db.encounters.aggregate(m09_pipeline, maxTimeMS=TIME_LIMIT_MS)]

    def n01():
        d = db.encounters.find_one({"_id": latest_visit})
        return [(len(d["vitals"]), len(d["diagnoses"]), sum(len(p["items"]) for p in d["prescriptions"]), len(d["notes"]))]

    n02_pipeline = [
        {"$match": {"diagnoses.code": "J45.9", "started_at": {"$gte": quarter}}},
        {"$group": {"_id": "$facility", "visits": {"$sum": 1}}},
        {"$sort": {"_id": 1}},
    ]

    def n02():
        return [(d["_id"], d["visits"]) for d in db.encounters.aggregate(n02_pipeline, maxTimeMS=TIME_LIMIT_MS)]

    pg_rows = lambda sql: [tuple(norm(v) for v in row) for row in pg.execute(sql).fetchall()]
    return [
        ("M01", "Find a patient by phone number", m01, lambda: pg_rows(base["Q01"]),
         {"find": "patients", "filter": {"phones.number": PHONE}, "projection": {"hospital_no": 1, "name": 1}}),
        ("M02", "Patient timeline: latest 20 encounters", m02, lambda: pg_rows(base["Q02"]),
         {"find": "encounters", "filter": {"patient_id": heavy_id}, "sort": {"started_at": -1}, "limit": 20,
          "projection": {"started_at": 1, "facility": 1, "type": 1, "diagnoses.code": 1}}),
        ("M05", "Monthly diagnosis counts per branch over a year", m05, lambda: pg_rows(base["Q05"]),
         {"aggregate": "encounters", "pipeline": m05_pipeline, "cursor": {}, "allowDiskUse": True}),
        ("M07", "Laboratory turnaround by test, 30 days", m07,
         lambda: [(r[0], r[1], r[2], r[4]) for r in pg_rows(base["Q07"])],
         {"aggregate": "lab_results", "pipeline": m07_pipeline, "cursor": {}}),
        ("M08", "Patients with no visit in 12 months", m08, lambda: pg_rows(rewritten["Q08"]),
         {"distinct": "encounters", "key": "patient_id", "query": {"started_at": {"$gte": year_ago}}}),
        ("M09", "Frequent attenders, 30 days", m09, lambda: pg_rows(base["Q09"]),
         {"aggregate": "encounters", "pipeline": m09_pipeline, "cursor": {}}),
        ("N01", "A whole visit in one read (counts of its parts)", n01,
         lambda: pg_rows(f"""SELECT (SELECT count(*) FROM vital_sign WHERE encounter_id = {latest_visit}),
                                    (SELECT count(*) FROM encounter_diagnosis WHERE encounter_id = {latest_visit}),
                                    (SELECT count(*) FROM prescription_item pi JOIN prescription rx USING (prescription_id)
                                      WHERE rx.encounter_id = {latest_visit}),
                                    (SELECT count(*) FROM clinical_note WHERE encounter_id = {latest_visit})"""),
         {"find": "encounters", "filter": {"_id": latest_visit}}),
        ("N02", "Asthma visits by branch, 90 days (multikey)", n02,
         lambda: pg_rows("""SELECT f.facility_code, count(*) FROM encounter e JOIN encounter_diagnosis d USING (encounter_id)
                             JOIN facility f USING (facility_id)
                            WHERE d.diagnosis_code = 'J45.9' AND e.started_at >= '2026-08-16 00:00+01'
                            GROUP BY 1 ORDER BY 1"""),
         {"aggregate": "encounters", "pipeline": n02_pipeline, "cursor": {}}),
    ]


def same(mongo_rows, pg_rows, tolerance=0.011):
    if len(mongo_rows) != len(pg_rows):
        return False
    for a, b in zip(sorted(mongo_rows, key=str), sorted(pg_rows, key=str)):
        for x, y in zip(a, b):
            if isinstance(x, float) or isinstance(y, float):
                if abs(float(x) - float(y)) > tolerance:
                    return False
            elif x != y:
                return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["before", "after"])
    args = parser.parse_args()
    db, pg = mongo().itoju, postgres()

    if args.phase == "after":
        section("Creating indexes")
        for collection, keys, name in INDEXES:
            t0 = time.perf_counter()
            db[collection].create_index(keys, name=name)
            log("idx", f"{collection}.{name} {keys}: built in {time.perf_counter() - t0:.1f} s")
        for collection in ("patients", "encounters", "lab_results"):
            stats = next(db[collection].aggregate([{"$collStats": {"storageStats": {}}}]))["storageStats"]
            sizes = ", ".join(f"{k} {v / 1048576:.1f} MB" for k, v in stats["indexSizes"].items())
            log("idx", f"{collection}: {sizes}")

    section(f"Workload ({args.phase} indexes), each MongoDB result compared with PostgreSQL's")
    out_dir = P4 / "explain" / args.phase
    out_dir.mkdir(parents=True, exist_ok=True)
    rows, record = [], {}
    for qid, title, run, pg_run, explain_cmd in queries(db, pg):
        times, result = [], None
        for _ in range(RUNS):
            t0 = time.perf_counter()
            result = run()
            times.append((time.perf_counter() - t0) * 1000)
        expected = pg_run()
        explain = db.command("explain", explain_cmd, verbosity="executionStats")
        (out_dir / f"{qid}.json").write_text(json.dumps(strip(explain), indent=1, default=str), encoding="utf-8",
                                             newline="\n")
        stages, totals = plan_stages(explain), examined(explain)
        digest = hashlib.sha256("\n".join(sorted(map(str, result))).encode()).hexdigest()[:16]
        matches = same(result, expected)
        record[qid] = {"rows": len(result), "hash": digest, "median_ms": round(statistics.median(times), 1),
                       "stages": stages, "docs": totals["docs"], "keys": totals["keys"], "matches_postgres": matches}
        rows.append([qid, title, len(result), len(expected), "yes" if matches else "NO", f"{statistics.median(times):.1f}",
                     " > ".join(stages), totals["keys"], totals["docs"]])
        log("wl", f"{qid}: {len(result)} rows, {'same as' if matches else 'DIFFERENT from'} PostgreSQL, "
                  f"{statistics.median(times):.1f} ms, {' > '.join(stages)}, keys {totals['keys']}, docs {totals['docs']}")
        check(f"{qid} returns the same rows as PostgreSQL", matches, f"{len(result)} rows")

    (P4 / "results").mkdir(exist_ok=True)
    (P4 / "results" / f"workload_{args.phase}.json").write_text(json.dumps(record, indent=2), encoding="utf-8", newline="\n")
    print()
    print(tabulate(rows, headers=["query", "question", "MongoDB rows", "PostgreSQL rows", "same rows", "median ms",
                                  "winning plan stages", "keys examined", "docs examined"], disable_numparse=True))

    if args.phase == "after":
        before = json.loads((P4 / "results" / "workload_before.json").read_text(encoding="utf-8"))
        print()
        comparison = []
        for qid, now in record.items():
            was = before[qid]
            comparison.append([qid, " > ".join(was["stages"]), " > ".join(now["stages"]), was["docs"], now["docs"],
                               was["keys"], now["keys"], was["median_ms"], now["median_ms"]])
            check(f"{qid} returns the same rows before and after indexing", was["hash"] == now["hash"])
        print(tabulate(comparison, headers=["query", "plan before", "plan after", "docs before", "docs after",
                                            "keys before", "keys after", "ms before", "ms after"], disable_numparse=True))
        (P4 / "results" / "comparison.json").write_text(json.dumps(comparison, indent=2), encoding="utf-8", newline="\n")
    summary()


if __name__ == "__main__":
    main()
