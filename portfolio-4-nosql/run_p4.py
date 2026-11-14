"""Load MongoDB from PostgreSQL and run every Portfolio 4 demonstration, capturing the evidence."""

import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "outputs"
MONGO = HERE / "mongo"

STEPS = [
    ("p4-01-load.txt", "Load PostgreSQL's data into MongoDB documents and compare counts and totals", "load.py"),
    ("p4-02-validation.txt", "Validators, unique index, de-identified view and least-privilege role", "validation.py"),
    ("p4-03-workload-before.txt", "Workload with only the _id and unique indexes, compared with PostgreSQL", "workload.py before"),
    ("p4-04-workload-after.txt", "Workload with access-pattern indexes, compared with PostgreSQL and with before",
     "workload.py after"),
    ("p4-05-timeseries.txt", "Time-series collection of home blood-pressure readings", "timeseries.py"),
    ("p4-06-graph.txt", "Referral network traversed with $graphLookup", "graph.py"),
    ("p4-07-transactions.txt", "Multi-document transactions and write conflicts", "transactions.py"),
]


def main():
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "postgres", "mongo"], cwd=ROOT, check=True)
    shutil.rmtree(HERE / "explain", ignore_errors=True)
    (HERE / "explain").mkdir()
    started = time.perf_counter()
    for out, title, script in STEPS:
        t0 = time.perf_counter()
        command = [sys.executable, *script.split()]
        command[1] = str(MONGO / command[1])
        code = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "evidence.py"), "--out", str(OUT / out), "--title", title,
             "--target", "mongo", "--", *command],
            cwd=MONGO, stdout=subprocess.DEVNULL).returncode
        print(f"{'ok  ' if code == 0 else 'FAIL'} {out:28} {time.perf_counter() - t0:6.1f} s", flush=True)
        if code != 0:
            sys.exit(code)
    print(f"all {len(STEPS)} steps passed in {(time.perf_counter() - started) / 60:.1f} min")


if __name__ == "__main__":
    main()
