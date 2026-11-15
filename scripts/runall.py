"""Run every portfolio's pipeline in order, each rebuilding its own state and rewriting its evidence."""

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PIPELINES = [
    "portfolio-1-database-design/run_p1.py",
    "portfolio-2-query-optimisation/run_p2.py",
    "portfolio-3-transactions-concurrency/run_p3.py",
    "portfolio-4-nosql/run_p4.py",
    "portfolio-5-distributed-cloud/run_p5.py",
]


def main():
    started = time.perf_counter()
    for pipeline in PIPELINES:
        t0 = time.perf_counter()
        print(f"\n##### {pipeline}", flush=True)
        code = subprocess.run([sys.executable, str(ROOT / pipeline)], cwd=ROOT).returncode
        print(f"##### {'ok  ' if code == 0 else 'FAIL'} {pipeline} in {(time.perf_counter() - t0) / 60:.1f} min",
              flush=True)
        if code != 0:
            sys.exit(code)
    print(f"\nall {len(PIPELINES)} pipelines passed in {(time.perf_counter() - started) / 60:.1f} min")


if __name__ == "__main__":
    main()
