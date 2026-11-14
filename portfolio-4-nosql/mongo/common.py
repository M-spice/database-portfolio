"""Connections to MongoDB and PostgreSQL, timed logging and checks for the Portfolio 4 scripts."""

import sys
import time
from pathlib import Path

import psycopg
from pymongo import MongoClient
from tabulate import tabulate

HERE = Path(__file__).resolve().parent
P4 = HERE.parent
ROOT = P4.parent
T0 = time.perf_counter()
CHECKS = []


def env(key):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"{key} is not set in .env")


def mongo(username="root", password=None, auth_source="admin"):
    # directConnection: the replica set advertises localhost:37017, but connecting directly keeps the driver on this node.
    return MongoClient("127.0.0.1", 37017, username=username, password=password or env("MONGO_ROOT_PASSWORD"),
                       authSource=auth_source, directConnection=True, tz_aware=True,
                       serverSelectionTimeoutMS=10000)


def postgres():
    conn = psycopg.connect(host="127.0.0.1", port=55432, dbname="itoju", user="postgres",
                           password=env("POSTGRES_PASSWORD"), autocommit=True)
    conn.execute("SET TimeZone = 'UTC'")
    conn.execute("SET search_path = itoju, public")
    conn.execute("SET jit = off")
    return conn


def log(who, message):
    print(f"{(time.perf_counter() - T0) * 1000:9.1f} ms  [{who:>3}] {message}", flush=True)


def section(title):
    print(f"\n=== {title}", flush=True)


def check(name, ok, detail=""):
    CHECKS.append((name, "PASS" if ok else "FAIL", detail))
    log("chk", f"{'PASS' if ok else 'FAIL'}: {name}{f' ({detail})' if detail else ''}")


def summary():
    print()
    print(tabulate(CHECKS, headers=["check", "result", "detail"]))
    failed = sum(1 for c in CHECKS if c[1] == "FAIL")
    print(f"\nchecks: {len(CHECKS)} | passed: {len(CHECKS) - failed} | failed: {failed}")
    sys.exit(1 if failed else 0)
