"""Build both clusters from empty volumes and run the replication and sharding demonstrations, capturing the evidence."""

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "outputs"
sys.path.insert(0, str(HERE / "demos"))

from common import compose  # noqa: E402


def evidence(out, title, script):
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "evidence.py"), "--out", str(OUT / out), "--title", title,
         "--target", "none", "--", sys.executable, str(HERE / "demos" / script)],
        cwd=HERE / "demos", stdout=subprocess.DEVNULL).returncode


STEPS = [
    ("pg-replication", "p5-01-pg-replication.txt",
     "PostgreSQL primary with synchronous and asynchronous standbys: replication, consistency, failover", "replication.py",
     ["up", "-d", "--wait"]),
    ("mongo-sharding", "p5-02-mongo-sharding.txt",
     "MongoDB sharded cluster: distribution, routing, hot spot and a failed shard", "sharding.py", ["up", "-d"]),
]


def main():
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "postgres"], cwd=ROOT, check=True)
    subprocess.run(["docker", "compose", "stop", "mongo"], cwd=ROOT, check=True)
    started = time.perf_counter()
    try:
        for directory, out, title, script, up in STEPS:
            t0 = time.perf_counter()
            compose(directory, "down", "-v", check=False)
            created = compose(directory, *up, check=False)
            if created.returncode != 0:
                print(created.stdout, created.stderr)
                sys.exit(created.returncode)
            code = evidence(out, title, script)
            compose(directory, "stop", check=False)
            print(f"{'ok  ' if code == 0 else 'FAIL'} {out:28} {time.perf_counter() - t0:6.1f} s", flush=True)
            if code != 0:
                sys.exit(code)
    finally:
        subprocess.run(["docker", "compose", "start", "mongo"], cwd=ROOT)
    print(f"all {len(STEPS)} steps passed in {(time.perf_counter() - started) / 60:.1f} min")


if __name__ == "__main__":
    main()
