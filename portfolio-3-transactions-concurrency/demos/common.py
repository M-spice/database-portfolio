"""Shared helpers for the Portfolio 3 demonstrations: labelled sessions, timed logging, lock-wait detection and checks."""

import sys
import threading
import time
from pathlib import Path

import psycopg
from tabulate import tabulate

ROOT = Path(__file__).resolve().parents[2]
T0 = time.perf_counter()
CHECKS = []
_print = threading.Lock()


def env(key):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"{key} is not set in .env")


def log(who, message):
    with _print:
        print(f"{(time.perf_counter() - T0) * 1000:9.1f} ms  [{who:>3}] {message}", flush=True)


def section(title):
    with _print:
        print(f"\n=== {title}", flush=True)


def session(label, superuser_settings=()):
    """An autocommit connection: every transaction in the demos is opened and closed with explicit SQL."""
    conn = psycopg.connect(host="127.0.0.1", port=55432, dbname="itoju", user="postgres",
                           password=env("POSTGRES_PASSWORD"), autocommit=True, application_name=f"p3-{label}")
    for setting in superuser_settings:
        conn.execute(setting)
    # sys and mon keep superuser rights so pg_stat_activity shows them every session's wait events.
    if label not in ("sys", "mon"):
        conn.execute("SET ROLE itoju_owner")
    conn.execute("SET search_path = itoju, sandbox, public")
    conn.execute("SET TimeZone = 'UTC'")
    return conn


def run(conn, who, sql, params=None, show=True):
    if show:
        text = psycopg.ClientCursor(conn).mogrify(sql, params) if params else sql
        log(who, " ".join(text.split()))
    cur = conn.execute(sql, params)
    rows = cur.fetchall() if cur.description else None
    if show and rows is not None and len(rows) == 1 and len(rows[0]) == 1:
        log(who, f"  -> {rows[0][0]}")
    return rows


def attempt(conn, who, sql, params=None):
    """Run a statement and report a database error instead of raising it; returns (rows, error)."""
    try:
        return run(conn, who, sql, params), None
    except psycopg.Error as exc:
        constraint = getattr(exc.diag, "constraint_name", None)
        log(who, f"  ERROR {exc.sqlstate}{f' ({constraint})' if constraint else ''}: {exc.diag.message_primary}")
        return None, exc


def value(conn, sql, params=None):
    return conn.execute(sql, params).fetchone()[0]


def in_thread(target, *args):
    t = threading.Thread(target=target, args=args, daemon=True)
    t.start()
    return t


def wait_for_lock(monitor, label, timeout=15.0):
    """Confirm from a separate autocommit session that `label` is blocked by another backend."""
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        row = monitor.execute("""
            SELECT a.pid, a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid),
                   (SELECT string_agg(b.application_name, ',') FROM pg_stat_activity b
                     WHERE b.pid = ANY (pg_blocking_pids(a.pid)))
              FROM pg_stat_activity a
             WHERE a.application_name = %s AND a.wait_event_type = 'Lock'
               AND cardinality(pg_blocking_pids(a.pid)) > 0""", (f"p3-{label}",)).fetchone()
        if row:
            log("sys", f"{label} (pid {row[0]}) waits on {row[1]}:{row[2]}, blocked by "
                       f"{row[4].replace('p3-', '')} (pid {', '.join(map(str, row[3]))})")
            return row
        time.sleep(0.02)
    raise TimeoutError(f"{label} never blocked")


def check(name, ok, detail=""):
    CHECKS.append((name, "PASS" if ok else "FAIL", detail))
    log("chk", f"{'PASS' if ok else 'FAIL'}: {name}{f' ({detail})' if detail else ''}")


def summary():
    print()
    print(tabulate(CHECKS, headers=["check", "result", "detail"]))
    failed = sum(1 for c in CHECKS if c[1] == "FAIL")
    print(f"\nchecks: {len(CHECKS)} | passed: {len(CHECKS) - failed} | failed: {failed}")
    sys.exit(1 if failed else 0)


def ids(conn):
    one = lambda sql: value(conn, sql)
    return {
        "patient_a": one("SELECT patient_id FROM patient WHERE hospital_no = 'HN-0000002'"),
        "patient_b": one("SELECT patient_id FROM patient WHERE hospital_no = 'HN-0000012'"),
        "patient_c": one("SELECT patient_id FROM patient WHERE hospital_no = 'HN-0000001'"),
        "doctor_1": one("SELECT staff_id FROM staff WHERE staff_no = 'ST-00001'"),
        "doctor_2": one("SELECT staff_id FROM staff WHERE staff_no = 'ST-00002'"),
        "reception": one("SELECT staff_id FROM staff WHERE staff_no = 'ST-00017'"),
        "pharmacist": one("SELECT staff_id FROM staff WHERE staff_no = 'ST-00012'"),
        "billing": one("SELECT staff_id FROM staff WHERE staff_no = 'ST-00019'"),
        "gp": one("SELECT department_id FROM department WHERE department_code = 'GP'"),
        "ikeja": one("SELECT facility_id FROM facility WHERE facility_code = 'LAG-IKJ'"),
        "lekki": one("SELECT facility_id FROM facility WHERE facility_code = 'LAG-LEK'"),
        "surulere": one("SELECT facility_id FROM facility WHERE facility_code = 'LAG-SUR'"),
        "paracetamol": one("SELECT drug_id FROM drug WHERE drug_code = 'DRG-0002'"),
        "amoxicillin": one("SELECT drug_id FROM drug WHERE drug_code = 'DRG-0003'"),
        "inhaler": one("SELECT drug_id FROM drug WHERE drug_code = 'DRG-0010'"),
    }


def free_slots(conn, clinician_id, patient_ids, count=1):
    """The next free 30-minute weekday slots from January 2027, so every run of a demo books new time."""
    rows = conn.execute("""
        SELECT gs FROM generate_series(timestamptz '2027-01-04 08:00+01', timestamptz '2028-01-04 08:00+01',
                                       interval '30 minutes') gs
         WHERE extract(isodow FROM gs AT TIME ZONE 'Africa/Lagos') < 6
           AND (gs AT TIME ZONE 'Africa/Lagos')::time BETWEEN '08:00' AND '15:30'
           AND NOT EXISTS (SELECT 1 FROM appointment a
                            WHERE a.appointment_status_code <> 'CANCELLED' AND a.clinician_id = %s
                              AND a.slot && tstzrange(gs, gs + interval '30 minutes'))
           AND NOT EXISTS (SELECT 1 FROM unnest(%s::bigint[]) p (patient_id)
                             JOIN appointment a ON a.patient_id = p.patient_id
                            WHERE a.appointment_status_code <> 'CANCELLED'
                              AND a.slot && tstzrange(gs, gs + interval '30 minutes'))
         ORDER BY gs LIMIT %s""", (clinician_id, list(patient_ids), count)).fetchall()
    return [r[0] for r in rows]
