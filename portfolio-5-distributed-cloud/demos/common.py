"""Shared helpers for the Portfolio 5 demonstrations: connections, compose commands, timed logging and checks."""

import os
import subprocess
import sys
import time
from pathlib import Path

import psycopg
from tabulate import tabulate

HERE = Path(__file__).resolve().parent
P5 = HERE.parent
ROOT = P5.parent
T0 = time.perf_counter()
CHECKS = []
PORTS = {"primary": 55441, "standby_sync": 55442, "standby_async": 55443}
PROJECTS = {"pg-replication": "p5-pg", "mongo-sharding": "p5-mongo"}


def env(key):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"{key} is not set in .env")


def log(who, message):
    print(f"{(time.perf_counter() - T0) * 1000:9.1f} ms  [{who:>3}] {message}", flush=True)


def section(title):
    print(f"\n=== {title}", flush=True)


def pg(node, autocommit=True, timeout=3, statement_timeout_ms=None):
    # tcp_user_timeout drops a connection whose server has died instead of waiting on it indefinitely.
    options = f"-c statement_timeout={statement_timeout_ms}" if statement_timeout_ms else None
    return psycopg.connect(host="127.0.0.1", port=PORTS[node], dbname="itoju", user="postgres",
                           password=env("POSTGRES_PASSWORD"), autocommit=autocommit, connect_timeout=timeout,
                           application_name=f"p5-{node}", tcp_user_timeout=2000, keepalives=1, keepalives_idle=1,
                           keepalives_interval=1, keepalives_count=2, options=options)


def compose(project_dir, *args, check=True):
    # Named after the main stack's project, so a second copy of the repository gets clusters of its own.
    project = f"{os.environ.get('COMPOSE_PROJECT_NAME', 'itoju')}-{PROJECTS[project_dir]}"
    command = ["docker", "compose", "-p", project, "-f", str(P5 / project_dir / "compose.yaml"), "--env-file",
               str(ROOT / ".env"), *args]
    return subprocess.run(command, cwd=ROOT, check=check, capture_output=True, text=True)


def check(name, ok, detail=""):
    CHECKS.append((name, "PASS" if ok else "FAIL", detail))
    log("chk", f"{'PASS' if ok else 'FAIL'}: {name}{f' ({detail})' if detail else ''}")


def summary():
    print()
    print(tabulate(CHECKS, headers=["check", "result", "detail"]))
    failed = sum(1 for c in CHECKS if c[1] == "FAIL")
    print(f"\nchecks: {len(CHECKS)} | passed: {len(CHECKS) - failed} | failed: {failed}")
    sys.exit(1 if failed else 0)
