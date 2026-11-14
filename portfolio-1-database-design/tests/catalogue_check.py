"""Compare the live itoju schema with design/relational-schema.md: relations, columns, constraint counts, roles and views."""

import re
import sys
from pathlib import Path

import psycopg
from tabulate import tabulate

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCHEMA_DOC = HERE.parent / "design" / "relational-schema.md"
COUNT_COLUMNS = ["Columns", "PK", "FK", "UK", "CK", "EX", "UI", "TG"]


def env(key):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    raise SystemExit(f"{key} is not set in .env")


def sections(text):
    parts = re.split(r"^## ", text, flags=re.M)
    return {p.splitlines()[0].strip(): p for p in parts[1:]}


def documented(text):
    relations = {}
    for m in re.finditer(r"^\*\*([a-z_]+)\*\* \((.+)\)\s*$", text, flags=re.M):
        cols = re.sub(r"</?ins>|\*", "", m.group(2))
        relations[m.group(1)] = [c.strip() for c in cols.split(",")]

    counts = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 9 and re.fullmatch(r"`[a-z_]+`", cells[0]) and all(c.isdigit() for c in cells[1:]):
            counts[cells[0].strip("`")] = dict(zip(COUNT_COLUMNS, map(int, cells[1:])))

    by_heading = sections(text)
    roles = set(re.findall(r"^\| `(itoju_[a-z]+)`", by_heading.get("Roles and privileges", ""), flags=re.M))
    views = set(re.findall(r"^\| `([a-z_]+)`", by_heading.get("Views", ""), flags=re.M))
    return relations, counts, roles, views


def live(conn):
    rows = conn.execute("""
        SELECT c.relname,
               array(SELECT a.attname::text FROM pg_attribute a
                      WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum),
               (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p'),
               (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f'),
               (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'u'),
               (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'c'),
               (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'x'),
               (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid AND i.indisunique
                   AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)),
               (SELECT count(*) FROM pg_trigger g WHERE g.tgrelid = c.oid AND NOT g.tgisinternal)
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'itoju' AND c.relkind = 'r'
         ORDER BY c.relname""").fetchall()
    relations = {r[0]: list(r[1]) for r in rows}
    counts = {r[0]: dict(zip(COUNT_COLUMNS, [len(r[1]), *r[2:]])) for r in rows}
    roles = {r[0] for r in conn.execute(
        "SELECT rolname FROM pg_roles WHERE rolname LIKE 'itoju\\_%' AND NOT rolcanlogin").fetchall()}
    views = {r[0] for r in conn.execute(
        "SELECT viewname FROM pg_views WHERE schemaname = 'itoju'").fetchall()}
    return relations, counts, roles, views


def main():
    doc_rel, doc_counts, doc_roles, doc_views = documented(SCHEMA_DOC.read_text(encoding="utf-8"))
    with psycopg.connect(host="127.0.0.1", port=55432, dbname="itoju", user="postgres",
                         password=env("POSTGRES_PASSWORD")) as conn:
        db_rel, db_counts, db_roles, db_views = live(conn)

    rows, failures = [], 0
    for table in sorted(set(doc_rel) | set(db_rel)):
        expected, actual = doc_counts.get(table), db_counts.get(table)
        columns_match = doc_rel.get(table) == db_rel.get(table)
        counts_match = expected == actual
        ok = columns_match and counts_match
        failures += not ok
        fmt = lambda c: " ".join(f"{k}={v}" for k, v in c.items() if k != "Columns") if c else "missing"
        rows.append([table, len(doc_rel.get(table, [])), len(db_rel.get(table, [])),
                     "same" if columns_match else "DIFFERENT", fmt(expected), fmt(actual), "PASS" if ok else "FAIL"])
    print(tabulate(rows, headers=["relation", "doc cols", "db cols", "column names",
                                  "documented constraints", "live constraints", "result"]))

    print()
    for label, doc, db in [("group roles", doc_roles, db_roles), ("views", doc_views, db_views)]:
        ok = doc == db
        failures += not ok
        print(f"{label}: documented {len(doc)}, live {len(db)}, {'PASS' if ok else 'FAIL'}"
              + ("" if ok else f" (only documented: {sorted(doc - db)}, only live: {sorted(db - doc)})"))

    print(f"\nrelations compared: {len(rows)} | mismatches: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
