"""Run one phase of the Portfolio 2 workload: plans, median timings, buffers, estimates and result hashes."""

import argparse
import hashlib
import json
import re
import statistics
import sys
from pathlib import Path

import psycopg
from tabulate import tabulate

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
RUNS = 5
TIMEOUT_MS = 120_000


def env(key):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"{key} is not set in .env")


def connect():
    conn = psycopg.connect(host="127.0.0.1", port=55432, dbname="itoju", user="postgres",
                           password=env("POSTGRES_PASSWORD"), autocommit=True)
    conn.execute("SET jit = off")
    conn.execute("SET TimeZone = 'UTC'")
    conn.execute("SET ROLE itoju_owner")
    conn.execute("SET search_path = itoju, public")
    return conn


def load_workload(path):
    queries, current = [], None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        header = re.match(r"^-- (Q\d+[a-z]?) \| (.+)$", line)
        setting = re.match(r"^-- set (\w+) = (.+)$", line)
        if header:
            current = {"id": header.group(1), "title": header.group(2).strip(), "settings": [], "sql": []}
            queries.append(current)
        elif setting and current:
            current["settings"].append((setting.group(1), setting.group(2).strip()))
        elif current and not line.startswith("--"):
            current["sql"].append(line)
    for q in queries:
        q["sql"] = "\n".join(q["sql"]).strip().rstrip(";")
    return queries


def nodes(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from nodes(child)


def shape(plan):
    children = ",".join(shape(c) for c in plan.get("Plans", []))
    name = plan["Node Type"] + (f"[{plan['Index Name']}]" if "Index Name" in plan else "")
    return f"{name}({children})" if children else name


def worst_estimate(plan):
    worst = (1.0, plan["Node Type"], plan["Plan Rows"], plan.get("Actual Rows", 0))
    for n in nodes(plan):
        if not n.get("Actual Loops"):
            continue
        est, act = n["Plan Rows"], n["Actual Rows"]
        ratio = max(est, act) / max(1, min(est, act))
        if ratio > worst[0]:
            worst = (ratio, n["Node Type"], est, act)
    return worst


def apply_settings(conn, settings, reset=False):
    for name, value in settings:
        conn.execute(f"RESET {name}" if reset else f"SET {name} = {value}")


def run_query(conn, q, phase):
    conn.execute(f"SET statement_timeout = {TIMEOUT_MS}")
    record = {"id": q["id"], "title": q["title"], "settings": q["settings"]}
    try:
        cur = conn.execute(q["sql"])
        rows = cur.fetchall()
        columns = [d.name for d in cur.description]
    except psycopg.errors.QueryCanceled:
        record.update(timed_out=True)
        plan_text = "\n".join(r[0] for r in conn.execute(f"EXPLAIN {q['sql']}").fetchall())
        return record, plan_text, None

    lines = sorted("|".join("" if v is None else str(v) for v in row) for row in rows)
    record.update(timed_out=False, rows=len(rows),
                  result_hash=hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16])

    plan_text = "\n".join(r[0] for r in conn.execute(f"EXPLAIN (ANALYZE, BUFFERS, SETTINGS) {q['sql']}").fetchall())

    samples = []
    for _ in range(RUNS):
        doc = conn.execute(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {q['sql']}").fetchone()[0][0]
        top = doc["Plan"]
        samples.append({
            "ms": doc["Execution Time"],
            "planning_ms": doc["Planning Time"],
            "hit": top.get("Shared Hit Blocks", 0),
            "read": top.get("Shared Read Blocks", 0),
            "temp": top.get("Temp Read Blocks", 0) + top.get("Temp Written Blocks", 0),
            "est": top["Plan Rows"],
            "act": top["Actual Rows"],
            "shape": shape(top),
            "worst": worst_estimate(top),
            "root": top["Node Type"],
        })
    times = [s["ms"] for s in samples]
    last = samples[-1]
    record.update(
        median_ms=round(statistics.median(times), 3),
        min_ms=round(min(times), 3),
        max_ms=round(max(times), 3),
        planning_ms=round(statistics.median(s["planning_ms"] for s in samples), 3),
        shared_hit=last["hit"],
        shared_read=last["read"],
        buffers=last["hit"] + last["read"],
        temp_blocks=last["temp"],
        est_rows=last["est"],
        actual_rows=last["act"],
        worst_ratio=round(last["worst"][0], 1),
        worst_node=f"{last['worst'][1]} est {last['worst'][2]} / actual {last['worst'][3]}",
        plan_stable=len({s["shape"] for s in samples}) == 1,
        shape=last["shape"],
        root=last["root"],
    )
    return record, plan_text, (columns, rows)


def write_files(phase, q, record, plan_text, result):
    plan_dir, result_dir = HERE / "plans" / phase, HERE / "results" / phase
    plan_dir.mkdir(parents=True, exist_ok=True)
    result_dir.mkdir(parents=True, exist_ok=True)
    settings = "".join(f"SET {n} = {v};\n" for n, v in q["settings"])
    (plan_dir / f"{q['id']}.txt").write_text(
        f"-- {q['id']}: {q['title']} ({phase})\n{settings}{q['sql']};\n\n{plan_text}\n", encoding="utf-8", newline="\n")
    if result is None:
        body = "timed out after 120 s; no result\n"
    else:
        columns, rows = result
        body = (f"rows: {record['rows']} | sha256 of sorted rows (first 16 hex): {record['result_hash']}\n\n"
                + tabulate(rows[:25], headers=columns) + ("\n... (first 25 rows shown)\n" if len(rows) > 25 else "\n"))
    (result_dir / f"{q['id']}.txt").write_text(f"-- {q['id']}: {q['title']} ({phase})\n{body}", encoding="utf-8", newline="\n")


def index_usage(conn):
    return conn.execute("""
        SELECT s.relname, s.indexrelname, s.idx_scan, pg_size_pretty(pg_relation_size(s.indexrelid))
          FROM pg_stat_user_indexes s
         WHERE s.schemaname = 'itoju'
           AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid)
           AND s.indexrelname NOT LIKE '%\\_uk'
         ORDER BY s.relname, s.indexrelname""").fetchall()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["baseline", "indexed", "tuned"])
    parser.add_argument("workload")
    args = parser.parse_args()

    queries = load_workload(HERE / args.workload)
    with connect() as conn:
        conn.execute("RESET ROLE")
        conn.execute("SELECT pg_stat_reset()")
        conn.execute("SET ROLE itoju_owner")
        summary = []
        for q in queries:
            apply_settings(conn, q["settings"])
            record, plan_text, result = run_query(conn, q, args.phase)
            apply_settings(conn, q["settings"], reset=True)
            write_files(args.phase, q, record, plan_text, result)
            summary.append(record)
            if record.get("timed_out"):
                print(f"{q['id']} timed out after {TIMEOUT_MS // 1000} s", flush=True)
            else:
                print(f"{q['id']} median {record['median_ms']:>10.3f} ms  buffers {record['buffers']:>9}  "
                      f"rows {record['rows']:>6}  root {record['root']}", flush=True)
        usage = index_usage(conn)

    (HERE / "results" / args.phase / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8", newline="\n")

    print()
    print(tabulate([[r["id"], r["title"][:44],
                     "timeout" if r.get("timed_out") else r["median_ms"],
                     "" if r.get("timed_out") else f"{r['min_ms']}–{r['max_ms']}",
                     r.get("buffers", ""), r.get("est_rows", ""), r.get("actual_rows", ""),
                     r.get("worst_ratio", ""), "yes" if r.get("plan_stable") else "", r.get("rows", ""),
                     r.get("result_hash", "")] for r in summary],
                   headers=["query", "title", "median ms", "range ms", "buffers", "est rows", "actual rows",
                            "worst est ratio", "plan stable", "result rows", "result hash"]))
    print(f"\nindex usage during the {args.phase} workload (indexes not backing a key):")
    print(tabulate(usage, headers=["table", "index", "scans", "size"]) if usage else "none")


if __name__ == "__main__":
    sys.exit(main())
