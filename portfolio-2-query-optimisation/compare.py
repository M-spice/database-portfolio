"""Build results/comparison.md from the baseline, indexed and tuned summaries and the write-cost runs."""

import json
from pathlib import Path

from tabulate import tabulate

HERE = Path(__file__).resolve().parent
PHASES = ["baseline", "indexed", "tuned"]

TECHNIQUE = {
    "Q01": "B+ tree index on `patient_phone (phone_no)`",
    "Q02": "multi-column index `encounter (patient_id, started_at DESC)` removes the Sort; statistics target raised",
    "Q03": "none needed: the status predicate lets the exclusion constraint's partial GiST index serve it",
    "Q03b": "none: without the status predicate the partial GiST index cannot be used",
    "Q04": "none needed: the anti-join probes the exclusion constraint's GiST index",
    "Q05": "materialised view `monthly_diagnosis`",
    "Q06": "partial covering index on dispenses, `INCLUDE (quantity)`",
    "Q07": "covering index `lab_order (ordered_at) INCLUDE (...)`",
    "Q08": "`NOT IN` rewritten as `NOT EXISTS` (anti-join)",
    "Q08b": "`NOT IN` kept, `work_mem` raised so the subquery is hashed",
    "Q09": "B+ tree on `encounter (started_at)` for the 30-day range",
    "Q10": "none: low selectivity, the planner rightly keeps the sequential scan",
    "Q11": "none: a whole-ledger aggregation",
    "Q12": "none: reads the cached stock totals",
    "Q13": "none: recomputes the same totals from the ledger",
}


def load(phase):
    path = HERE / "results" / phase / "summary.json"
    return {r["id"]: r for r in json.loads(path.read_text(encoding="utf-8"))} if path.exists() else {}


def cell(record, key):
    if not record:
        return "–"
    if record.get("timed_out"):
        return "timeout"
    return record.get(key, "–")


def main():
    data = {p: load(p) for p in PHASES}
    ids = list(dict.fromkeys(q for p in PHASES for q in data[p]))
    rows = []
    for q in ids:
        recs = [data[p].get(q) for p in PHASES]
        hashes = {r["result_hash"] for r in recs if r and not r.get("timed_out")}
        title = next(r["title"] for r in recs if r)
        rows.append([
            q, title, TECHNIQUE.get(q, ""),
            *[cell(r, "median_ms") for r in recs],
            *[cell(r, "buffers") for r in recs],
            " → ".join(dict.fromkeys(cell(r, "root") for r in recs if r)),
            " / ".join(f"{cell(r, 'worst_ratio')}" for r in recs),
            "yes" if len(hashes) == 1 else ("n/a" if not hashes else "NO"),
        ])

    headers = ["Query", "Purpose", "Technique", "Baseline ms", "Indexed ms", "Tuned ms",
               "Baseline buffers", "Indexed buffers", "Tuned buffers", "Plan root", "Worst estimate ratio (b / i / t)",
               "Same result"]
    md = ["# Before and after", "",
          "Median of five `EXPLAIN (ANALYZE, BUFFERS)` runs per query and phase. Buffers are shared blocks hit plus "
          "read for one execution. The worst estimate ratio is the largest gap, across all plan nodes, between the "
          "rows the planner expected and the rows it got (1 means exact). Same result compares a hash of every "
          "result row across the phases.", "",
          tabulate(rows, headers=headers, tablefmt="github"), ""]

    costs = {p: json.loads((HERE / "results" / f"write_cost_{p}.json").read_text(encoding="utf-8"))
             for p in ["baseline", "indexed"] if (HERE / "results" / f"write_cost_{p}.json").exists()}
    if len(costs) == 2:
        md += ["## Write cost of the new indexes", "",
               "Median of three runs of 2,000 rows each, inside transactions that were rolled back.", "",
               tabulate([[op, costs["baseline"][op]["median_s"], costs["indexed"][op]["median_s"],
                          f"{(costs['indexed'][op]['median_s'] / costs['baseline'][op]['median_s'] - 1) * 100:+.0f}%"]
                         for op in costs["baseline"]],
                        headers=["Operation", "Baseline s", "Indexed s", "Change"], tablefmt="github"), ""]

    out = HERE / "results" / "comparison.md"
    out.write_text("\n".join(md), encoding="utf-8", newline="\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
