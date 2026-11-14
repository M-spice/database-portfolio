"""Rebuild the Itoju Clinics database from empty, run every Portfolio 1 test and capture the evidence."""

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "outputs"
PSQL = ["docker", "compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "itoju", "-X", "-q",
        "-v", "ON_ERROR_STOP=1", "-f"]
WORKSPACE = "/workspace/portfolio-1-database-design"

STEPS = [
    ("p1-build.txt", "Build the schema, rules, routines, privileges and sample data from empty",
     PSQL + [f"{WORKSPACE}/db/rebuild.sql"]),
    ("p1-test-constraints.txt", "Constraint and integrity-rule tests",
     PSQL + [f"{WORKSPACE}/tests/t_constraints.sql"]),
    ("p1-test-routines.txt", "Routine tests (normal and failure paths)",
     PSQL + [f"{WORKSPACE}/tests/t_routines.sql"]),
    ("p1-test-privileges.txt", "Role and privilege tests",
     PSQL + [f"{WORKSPACE}/tests/t_privileges.sql"]),
    ("p1-test-consistency.txt", "Data consistency checks",
     PSQL + [f"{WORKSPACE}/tests/t_consistency.sql"]),
    ("p1-normalisation.txt", "Normalisation: functional dependencies, keys and lossless join",
     PSQL + [f"{WORKSPACE}/tests/t_normalisation.sql"]),
    ("p1-catalogue-check.txt", "Live catalogue compared with the relational schema document",
     [sys.executable, str(HERE / "tests" / "catalogue_check.py")]),
]


def main():
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "postgres"], cwd=ROOT, check=True)
    started = time.perf_counter()
    summary = []
    for out, title, command in STEPS:
        t0 = time.perf_counter()
        code = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "evidence.py"), "--out", str(OUT / out),
             "--title", title, "--target", "postgres", "--", *command],
            cwd=ROOT, stdout=subprocess.DEVNULL).returncode
        summary.append((out, code, time.perf_counter() - t0))
        print(f"{'ok  ' if code == 0 else 'FAIL'} {out:28} {time.perf_counter() - t0:6.1f} s")
        if code != 0:
            print(f"stopped: {out} exited with {code}")
            sys.exit(code)
    print(f"all {len(summary)} steps passed in {time.perf_counter() - started:.1f} s")


if __name__ == "__main__":
    main()
