"""A time-series collection of home blood-pressure readings: bucketed storage, windowed aggregation and its limits."""

import hashlib
import json
from datetime import datetime, timedelta, timezone

from pymongo.errors import OperationFailure
from tabulate import tabulate

from common import P4, check, log, mongo, section, summary

LAGOS = timezone(timedelta(hours=1))
DAYS, HOURS = 14, range(6, 24)
FIRST_DAY = datetime(2026, 10, 31, tzinfo=LAGOS)


def unit(*parts):
    """A deterministic value in [0, 1) from the given parts, so every run generates the same readings."""
    digest = hashlib.sha256("|".join(map(str, parts)).encode()).digest()
    return int.from_bytes(digest[:8], "big") / 2 ** 64


def main():
    client = mongo()
    db = client.itoju

    section("1. The remote-monitoring programme: the 100 patients with the most hypertension visits")
    cohort = list(db.encounters.aggregate([
        {"$match": {"diagnoses.code": "I10"}},
        {"$group": {"_id": "$patient_id", "visits": {"$sum": 1}}},
        {"$sort": {"visits": -1, "_id": 1}}, {"$limit": 100},
        {"$lookup": {"from": "patients", "localField": "_id", "foreignField": "_id", "as": "p"}},
        {"$project": {"visits": 1, "hospital_no": {"$first": "$p.hospital_no"}}},
    ]))
    log("ts", f"{len(cohort)} patients enrolled; the most frequent has {cohort[0]['visits']} hypertension visits")

    db.drop_collection("bp_readings")
    db.create_collection("bp_readings", timeseries={"timeField": "taken_at", "metaField": "meta", "granularity": "minutes"})
    readings = []
    for n, patient in enumerate(cohort):
        baseline = 128 + 36 * unit("base", patient["_id"])
        for d in range(DAYS):
            for h in HOURS:
                minute = int(50 * unit("minute", patient["_id"], d, h))
                taken_at = FIRST_DAY + timedelta(days=d, hours=h, minutes=minute)
                swing = 8 if 7 <= h <= 10 else -6 if h >= 21 else 0
                systolic = round(baseline + swing + 18 * (unit("sys", patient["_id"], d, h) - 0.5))
                readings.append({
                    "taken_at": taken_at,
                    "meta": {"patient_id": patient["_id"], "hospital_no": patient["hospital_no"], "device": f"cuff-{n + 1:03d}"},
                    "systolic": systolic,
                    "diastolic": round(systolic * 0.62 + 8 * (unit("dia", patient["_id"], d, h) - 0.5)),
                    "pulse": round(62 + 30 * unit("pulse", patient["_id"], d, h)),
                })
    db.bp_readings.insert_many(readings, ordered=False)
    buckets = db["system.buckets.bp_readings"].count_documents({})
    log("ts", f"{len(readings)} readings stored in {buckets} buckets ({len(readings) / buckets:.0f} readings per bucket)")
    check("every generated reading was stored", db.bp_readings.count_documents({}) == len(readings), f"{len(readings)}")
    check("readings are grouped into buckets per patient and time span", buckets < len(readings) / 10, f"{buckets} buckets")

    section("2. Hourly averages for one patient on one day")
    patient = cohort[0]
    day_start = FIRST_DAY + timedelta(days=DAYS - 1)
    hourly = [
        {"$match": {"meta.patient_id": patient["_id"], "taken_at": {"$gte": day_start, "$lt": day_start + timedelta(days=1)}}},
        {"$group": {"_id": {"$dateTrunc": {"date": "$taken_at", "unit": "hour", "timezone": "Africa/Lagos"}},
                    "systolic": {"$avg": "$systolic"}, "diastolic": {"$avg": "$diastolic"}, "readings": {"$sum": 1}}},
        {"$sort": {"_id": 1}},
    ]
    rows = list(db.bp_readings.aggregate(hourly))
    print(tabulate([[r["_id"].astimezone(LAGOS).strftime("%Y-%m-%d %H:00"), round(r["systolic"]), round(r["diastolic"]), r["readings"]]
                    for r in rows], headers=["hour (Lagos)", "systolic", "diastolic", "readings"]))
    check("one row per waking hour", len(rows) == len(HOURS), f"{len(rows)} hours for {patient['hospital_no']}")
    explain = db.command("explain", {"aggregate": "bp_readings", "pipeline": hourly, "cursor": {}}, verbosity="executionStats")
    text = json.dumps(explain, default=str)
    unpack = "_internalUnpackBucket" in text
    log("ts", f"plan reads the buckets collection and unpacks them ($_internalUnpackBucket present: {unpack})")
    (P4 / "explain" / "timeseries_hourly.json").write_text(json.dumps(explain, indent=1, default=str), encoding="utf-8",
                                                          newline="\n")
    check("the query plan unpacks buckets rather than scanning single readings", unpack)

    section("3. Who needs a call: readings at or above 160/100 in the last 7 days")
    week = [
        {"$match": {"taken_at": {"$gte": FIRST_DAY + timedelta(days=DAYS - 7)}}},
        {"$group": {"_id": "$meta.hospital_no", "readings": {"$sum": 1}, "mean_systolic": {"$avg": "$systolic"},
                    "high": {"$sum": {"$cond": [{"$or": [{"$gte": ["$systolic", 160]}, {"$gte": ["$diastolic", 100]}]}, 1, 0]}}}},
        {"$match": {"high": {"$gt": 0}}},
        {"$sort": {"high": -1, "_id": 1}}, {"$limit": 10},
    ]
    rows = list(db.bp_readings.aggregate(week))
    print(tabulate([[r["_id"], r["readings"], round(r["mean_systolic"]), r["high"]] for r in rows],
                   headers=["patient", "readings", "mean systolic", "readings >= 160/100"]))
    check("the weekly window finds patients with high readings", len(rows) > 0)

    section("4. Limits of time-series collections in MongoDB 7.0, shown")
    session = client.start_session()
    try:
        with session.start_transaction():
            db.bp_readings.insert_one({"taken_at": datetime.now(timezone.utc), "meta": {"patient_id": 0}, "systolic": 120},
                                      session=session)
        refused = False
    except OperationFailure as exc:
        log("ts", f"insert inside a transaction: {exc.details.get('codeName')} - {exc.details.get('errmsg')}")
        refused = True
    finally:
        session.end_session()
    check("a time-series collection cannot be written inside a transaction", refused)
    try:
        db.command("collMod", "bp_readings", validator={"$jsonSchema": {"required": ["systolic"]}})
        no_validator = False
    except OperationFailure as exc:
        log("ts", f"adding a validator: {exc.details.get('codeName')} - {exc.details.get('errmsg')}")
        no_validator = True
    check("a time-series collection does not accept schema validation", no_validator)
    summary()


if __name__ == "__main__":
    main()
