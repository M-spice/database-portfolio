"""Rebuild Itoju Clinics at volume, then measure the workload at baseline, indexed and tuned, capturing all evidence."""

import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "outputs"
PSQL = ["docker", "compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "itoju", "-X", "-q",
        "-v", "ON_ERROR_STOP=1", "-f"]
P1 = "/workspace/portfolio-1-database-design"
P2 = "/workspace/portfolio-2-query-optimisation"
PY = [sys.executable]

STEPS = [
    ("p2-01-rebuild.txt", "Rebuild the Portfolio 1 schema and sample data", PSQL + [f"{P1}/db/rebuild.sql"]),
    ("p2-02-volume-load.txt", "Load the deterministic volume data", PSQL + [f"{P2}/sql/volume.sql"]),
    ("p2-03-consistency-at-volume.txt", "Portfolio 1 consistency checks at volume", PSQL + [f"{P1}/tests/t_consistency.sql"]),
    ("p2-04-sizes-baseline.txt", "Table and index sizes with key indexes only", PSQL + [f"{P2}/sql/sizes.sql"]),
    ("p2-05-measure-baseline.txt", "Workload at baseline (key indexes only)",
     PY + [str(HERE / "measure.py"), "baseline", "sql/workload.sql"]),
    ("p2-06-write-cost-baseline.txt", "Write cost with key indexes only", PY + [str(HERE / "write_cost.py"), "baseline"]),
    ("p2-07-indexing.txt", "Create the workload indexes", PSQL + [f"{P2}/sql/indexing.sql"]),
    ("p2-08-sizes-indexed.txt", "Table and index sizes with the workload indexes", PSQL + [f"{P2}/sql/sizes.sql"]),
    ("p2-09-measure-indexed.txt", "Workload with the workload indexes",
     PY + [str(HERE / "measure.py"), "indexed", "sql/workload.sql"]),
    ("p2-10-write-cost-indexed.txt", "Write cost with the workload indexes", PY + [str(HERE / "write_cost.py"), "indexed"]),
    ("p2-11-tuning.txt", "Statistics, materialised view and refresh cost", PSQL + [f"{P2}/sql/tuning.sql"]),
    ("p2-12-measure-tuned.txt", "Workload after rewriting and tuning",
     PY + [str(HERE / "measure.py"), "tuned", "sql/workload_rewritten.sql"]),
    ("p2-13-comparison.txt", "Before-and-after comparison", PY + [str(HERE / "compare.py")]),
    ("p2-14-determinism.txt", "A second load in a scratch database matches the first, row for row",
     PY + [str(HERE / "determinism.py")]),
    ("p2-15-data-profile.txt", "Skew of the volume data and the query parameters", PSQL + [f"{P2}/sql/profile.sql"]),
]


def main():
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "postgres"], cwd=ROOT, check=True)
    subprocess.run(["docker", "compose", "stop", "mongo"], cwd=ROOT, check=True)
    for folder in ("plans", "results"):
        shutil.rmtree(HERE / folder, ignore_errors=True)
    started = time.perf_counter()
    try:
        for out, title, command in STEPS:
            t0 = time.perf_counter()
            code = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "evidence.py"), "--out", str(OUT / out), "--title", title,
                 "--target", "postgres", "--", *command],
                cwd=HERE, stdout=subprocess.DEVNULL).returncode
            print(f"{'ok  ' if code == 0 else 'FAIL'} {out:34} {time.perf_counter() - t0:7.1f} s", flush=True)
            if code != 0:
                sys.exit(code)
    finally:
        subprocess.run(["docker", "compose", "start", "mongo"], cwd=ROOT)
    print(f"all {len(STEPS)} steps passed in {(time.perf_counter() - started) / 60:.1f} min")


if __name__ == "__main__":
    main()
