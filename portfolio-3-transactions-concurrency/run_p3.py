"""Run every Portfolio 3 demonstration against the live database, each followed by the consistency checks."""

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "outputs"
PSQL = ["docker", "compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "itoju", "-X", "-q",
        "-v", "ON_ERROR_STOP=1", "-f"]
CONSISTENCY = PSQL + ["/workspace/portfolio-1-database-design/tests/t_consistency.sql"]

STEPS = [
    ("p3-01-sandbox.txt", "Sandbox schema for the demonstrations that break a rule",
     PSQL + ["/workspace/portfolio-3-transactions-concurrency/sql/sandbox.sql"], False),
    ("p3-02-atomicity.txt", "Commit, rollback, savepoint, statement atomicity, idempotency and durability",
     [sys.executable, str(HERE / "demos" / "atomicity.py")], True),
    ("p3-03-isolation.txt", "Isolation levels: non-repeatable read, phantom, READ UNCOMMITTED, write skew",
     [sys.executable, str(HERE / "demos" / "isolation.py")], True),
    ("p3-04-locking.txt", "Lost update, row locks, exclusion, deadlock and a hot row",
     [sys.executable, str(HERE / "demos" / "locking.py")], True),
]


def evidence(out, title, command, append=False):
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "evidence.py"), "--out", str(OUT / out), "--title", title,
         "--target", "postgres", *(["--append"] if append else []), "--", *command],
        cwd=ROOT, stdout=subprocess.DEVNULL).returncode


def main():
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "postgres"], cwd=ROOT, check=True)
    started = time.perf_counter()
    for out, title, command, then_check in STEPS:
        t0 = time.perf_counter()
        code = evidence(out, title, command)
        if code == 0 and then_check:
            code = evidence(out, "Consistency checks after the demonstrations", CONSISTENCY, append=True)
        print(f"{'ok  ' if code == 0 else 'FAIL'} {out:24} {time.perf_counter() - t0:6.1f} s", flush=True)
        if code != 0:
            sys.exit(code)
    print(f"all {len(STEPS)} steps passed in {(time.perf_counter() - started) / 60:.1f} min")


if __name__ == "__main__":
    main()
