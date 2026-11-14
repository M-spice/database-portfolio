"""Load the volume data a second time into a scratch database and check every fingerprinted table is identical."""

import re
import subprocess
import sys

import psycopg
from tabulate import tabulate

from measure import ROOT, env

SCRATCH = "itoju_determinism"
TABLES = ["patient", "staff", "appointment", "encounter", "encounter_diagnosis", "prescription_item",
          "stock_movement", "lab_result", "invoice_line", "payment"]


def fingerprints(dbname):
    with psycopg.connect(host="127.0.0.1", port=55432, dbname=dbname, user="postgres",
                         password=env("POSTGRES_PASSWORD")) as conn:
        conn.execute("SET TimeZone = 'UTC'")
        return {t: conn.execute(f"SELECT count(*), sum(hashtext(x::text)::bigint) FROM itoju.{t} x").fetchone()
                for t in TABLES}


def psql(dbname, path):
    subprocess.run(["docker", "compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", dbname, "-X", "-q",
                    "-v", "ON_ERROR_STOP=1", "-o", "/dev/null", "-f", path], cwd=ROOT, check=True)


def main():
    with psycopg.connect(host="127.0.0.1", port=55432, dbname="postgres", user="postgres",
                         password=env("POSTGRES_PASSWORD"), autocommit=True) as admin:
        admin.execute(f"DROP DATABASE IF EXISTS {SCRATCH}")
        admin.execute(f"CREATE DATABASE {SCRATCH}")
    try:
        print(f"loading a second copy into {SCRATCH} ...", flush=True)
        psql(SCRATCH, "/workspace/portfolio-1-database-design/db/rebuild.sql")
        psql(SCRATCH, "/workspace/portfolio-2-query-optimisation/sql/volume.sql")
        first, second = fingerprints("itoju"), fingerprints(SCRATCH)
    finally:
        with psycopg.connect(host="127.0.0.1", port=55432, dbname="postgres", user="postgres",
                             password=env("POSTGRES_PASSWORD"), autocommit=True) as admin:
            admin.execute(f"DROP DATABASE IF EXISTS {SCRATCH} WITH (FORCE)")

    rows = [[t, first[t][0], second[t][0], first[t][1], second[t][1], "identical" if first[t] == second[t] else "DIFFERENT"]
            for t in TABLES]
    print(tabulate(rows, headers=["table", "rows (first load)", "rows (second load)", "fingerprint (first)",
                                  "fingerprint (second)", "result"]))
    differing = sum(r[-1] != "identical" for r in rows)
    print(f"\ntables compared: {len(rows)} | differing: {differing}")
    sys.exit(1 if differing else 0)


if __name__ == "__main__":
    main()
