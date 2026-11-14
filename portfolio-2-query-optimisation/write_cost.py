"""Time typical writes inside rolled-back transactions, to measure what the workload indexes cost on insert."""

import argparse
import json
import statistics
import sys
import time
from datetime import datetime, timedelta, timezone

from tabulate import tabulate

from measure import HERE, connect

ROWS = 2000
REPEATS = 3


def ids(conn):
    one = lambda sql: conn.execute(sql).fetchone()[0]
    return {
        "facility": one("SELECT facility_id FROM facility WHERE facility_code = 'LAG-IKJ'"),
        "clinician": one("SELECT staff_id FROM staff WHERE staff_no = 'ST-00002'"),
        "pharmacist": one("SELECT staff_id FROM staff WHERE staff_no = 'ST-00012'"),
        "drug": one("SELECT drug_id FROM drug WHERE drug_code = 'DRG-0002'"),
        "patients": [r[0] for r in conn.execute(
            "SELECT patient_id FROM patient WHERE hospital_no >= 'HN-0100001' ORDER BY patient_id LIMIT %s", (ROWS,))],
        "encounters": [r[0] for r in conn.execute(
            "SELECT encounter_id FROM encounter ORDER BY encounter_id LIMIT %s", (ROWS,))],
    }


def encounters(conn, k):
    start = datetime(2026, 12, 7, 8, 0, tzinfo=timezone(timedelta(hours=1)))
    with conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO encounter (patient_id, clinician_id, facility_id, encounter_type_code, started_at) "
            "VALUES (%s, %s, %s, 'WALK_IN', %s)",
            [(p, k["clinician"], k["facility"], start + timedelta(minutes=i)) for i, p in enumerate(k["patients"])])


def phones(conn, k):
    with conn.cursor() as cur:
        cur.executemany("INSERT INTO patient_phone (patient_id, phone_no) VALUES (%s, %s)",
                        [(p, f"+23409{i:08d}") for i, p in enumerate(k["patients"])])


def receipts(conn, k):
    with conn.cursor() as cur:
        cur.executemany("SELECT receive_stock(%s, %s, 10, %s)",
                        [(k["facility"], k["drug"], k["pharmacist"])] * ROWS)


def prescribe(conn, k):
    with conn.cursor() as cur:
        cur.execute("SELECT receive_stock(%s, %s, %s, %s)", (k["facility"], k["drug"], ROWS * 2, k["pharmacist"]))
        cur.executemany("WITH rx AS (INSERT INTO prescription (encounter_id, prescriber_id) VALUES (%s, %s) "
                        "RETURNING prescription_id) "
                        "INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage) "
                        "SELECT prescription_id, %s, 1, 'As directed' FROM rx",
                        [(e, k["clinician"], k["drug"]) for e in k["encounters"]])


def dispenses(conn, k):
    rx = [r[0] for r in conn.execute(
        "SELECT prescription_id FROM prescription ORDER BY prescription_id DESC LIMIT %s", (ROWS,))]
    with conn.cursor() as cur:
        cur.executemany("SELECT dispense_prescription_item(%s, %s, %s, %s)",
                        [(p, k["drug"], k["facility"], k["pharmacist"]) for p in rx])


TOUCHED = "stock_on_hand, stock_movement, encounter, patient_phone, prescription, prescription_item"


def vacuum(conn):
    # The receipts and dispenses update one shared stock_on_hand row 2,000 times; rolled-back versions are
    # vacuumed away so they cannot slow the next block or distort later plans.
    conn.execute(f"VACUUM (ANALYZE) {TOUCHED}")


BLOCKS = [
    ("encounter inserts", None, encounters),
    ("patient phone inserts", None, phones),
    ("stock receipts (RECEIPT rows)", None, receipts),
    ("dispenses (DISPENSE rows)", prescribe, dispenses),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["baseline", "indexed"])
    args = parser.parse_args()

    rows, report = [], {}
    with connect() as conn:
        k = ids(conn)
        for name, setup, timed in BLOCKS:
            samples = []
            for _ in range(REPEATS):
                vacuum(conn)
                with conn.transaction(force_rollback=True):
                    if setup:
                        setup(conn, k)
                    t0 = time.perf_counter()
                    timed(conn, k)
                    samples.append(time.perf_counter() - t0)
            median = statistics.median(samples)
            report[name] = {"median_s": round(median, 3), "samples_s": [round(s, 3) for s in samples]}
            rows.append([name, ROWS, f"{median:.3f}", f"{median / ROWS * 1e6:.0f}",
                         ", ".join(f"{s:.3f}" for s in samples)])
            print(f"{name}: median {median:.3f} s", flush=True)
        vacuum(conn)

    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / f"write_cost_{args.phase}.json").write_text(json.dumps(report, indent=2), encoding="utf-8",
                                                                       newline="\n")
    print()
    print(tabulate(rows, headers=["operation", "rows", "median s", "µs per row", f"{REPEATS} runs (s)"]))


if __name__ == "__main__":
    sys.exit(main())
