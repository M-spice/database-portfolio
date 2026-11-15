# Portfolio 2: Query Processing and Optimisation

How Itoju Clinics' most important questions are answered at realistic volume: the SQL, the plans PostgreSQL chooses for it, and what indexing, rewriting and better statistics change, measured rather than assumed.

## Required evidence

- [x] SQL queries: [sql/workload.sql](sql/workload.sql) and the rewritten forms in [sql/workload_rewritten.sql](sql/workload_rewritten.sql)
- [x] Query results: [results/baseline/](results/baseline/), [results/indexed/](results/indexed/), [results/tuned/](results/tuned/), with a hash of every result row
- [x] Execution plans: [plans/baseline/](plans/baseline/), [plans/indexed/](plans/indexed/), [plans/tuned/](plans/tuned/), one `EXPLAIN (ANALYZE, BUFFERS)` per query per phase
- [x] Indexing and optimisation evidence: [sql/indexing.sql](sql/indexing.sql), [sql/tuning.sql](sql/tuning.sql), [results/comparison.md](results/comparison.md), index sizes and write cost in [outputs/](outputs/)
- [x] Brief performance analysis: [analysis.md](analysis.md)
- [x] Screenshots: [Q06 before and after its index](outputs/screenshots/p2-06-q06-before-after.png), [a low-selectivity index declined](outputs/screenshots/p2-07-low-selectivity.png) and [the comparison table](outputs/screenshots/p2-08-comparison.png)

## The data

The Portfolio 1 database is rebuilt and then loaded with 24 months of activity, from November 2024 to November 2026 ([sql/volume.sql](sql/volume.sql)): 60,012 patients, 302 clinicians, 911,050 appointments, 714,247 encounters, 907,089 diagnoses, 772,593 prescription items, 241,675 lab results and 722,227 stock movements ([p2-02-volume-load.txt](outputs/p2-02-volume-load.txt)).

It is skewed the way a real network is. Ikeja sees 135,749 encounters and New Haven 15,173. The median patient visited 5 times, the 90th percentile 27 times and the busiest 138 times, while 5,802 patients came only once ([p2-15-data-profile.txt](outputs/p2-15-data-profile.txt)). Chronic patients return for chronic conditions, and diagnoses, prescriptions and tests follow each other (malaria leads to a rapid test and artemether-lumefantrine).

Every value is derived from a hash of its row number and a seed (`hashint8extended`), never from `random()`, so every rebuild produces the same rows and the same query results. The pipeline proves this by loading a second copy into a scratch database and comparing a hash of every row of ten tables: all ten identical ([p2-14-determinism.txt](outputs/p2-14-determinism.txt)).

## The workload

| Query | Key operation | What it exercises |
|---|---|---|
| Q01 | Find a patient by phone number | point lookup |
| Q02 | Patient timeline: latest 20 encounters with diagnoses | `ORDER BY … LIMIT`, correlated subquery |
| Q03, Q03b | A clinician's schedule for one day | range predicate on a `tstzrange`; partial index |
| Q04 | Free General Practice slots at Ikeja on one day | anti-join (`NOT EXISTS`) against a generated grid |
| Q05 | Monthly diagnosis counts per branch over a year | joins, `GROUP BY … HAVING` |
| Q06 | Pharmacy reorder report with 30 days of dispensing | join and aggregate, correlated subquery |
| Q07 | Laboratory turnaround by test | join, aggregate, percentile |
| Q08, Q08b | Patients with no visit in 12 months | `NOT IN` as a rewrite candidate |
| Q09 | Frequent attenders (five or more visits in 30 days) | range, `GROUP BY … HAVING` |
| Q10 | Average length of a consultation | a low-selectivity filter |
| Q11 | Reconcile every stock line against the ledger | full aggregation |
| Q12, Q13 | Stock at Ikeja from the cache, then from the ledger | the cost of the stock denormalisation |

## How I implemented it

**Loading.** The volume script runs as one transaction. It drops the 64 foreign keys and two exclusion constraints, disables user triggers, loads each table set-based in key order, derives the appointment status history and stock on hand from the loaded rows, and then re-adds every constraint. Re-adding a constraint re-validates all of its rows in a single pass, which is far faster than a trigger call per row. The load takes about four and a half minutes, and the Portfolio 1 consistency checks then run against the full volume: 15 of 15 pass, including no overlapping bookings among the active appointments and a replay of the whole ledger in time order that never goes below zero ([p2-03-consistency-at-volume.txt](outputs/p2-03-consistency-at-volume.txt)).

**Measuring.** [`measure.py`](measure.py) runs each query once to capture its result, once to save a readable plan, and then five times as `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`. From those five runs it records the median time and range, the buffers, the estimated and actual rows, the worst estimate anywhere in the plan, and whether the plan shape stayed the same. JIT compilation is off, so short queries are not dominated by compile time. MongoDB is stopped during the measurements. Any query still running after 120 seconds is stopped and recorded as a timeout.

**Three phases, one change at a time.**
1. **Baseline:** only the indexes that keys and exclusion constraints need.
2. **Indexed:** [sql/indexing.sql](sql/indexing.sql) adds six indexes, each named by its technique and the query it targets: a B+ tree, a multi-column index in sort order, a partial covering index with `INCLUDE`, a covering range index, a range index, and an index on a low-selectivity column. A `VACUUM` follows, so index-only scans can skip the table.
3. **Tuned:** [sql/tuning.sql](sql/tuning.sql) raises the statistics target where an estimate was badly off and creates a materialised view with its refresh cost measured. [sql/workload_rewritten.sql](sql/workload_rewritten.sql) rewrites `NOT IN` as `NOT EXISTS` and reads the view.

**Costs as well as gains.** [sql/sizes.sql](sql/sizes.sql) records table and index sizes before and after. [`write_cost.py`](write_cost.py) times 2,000 encounter inserts, phone inserts, stock receipts and dispenses three times, inside transactions that are rolled back, with and without the new indexes. Index usage counters show which indexes the planner actually used.

## How I tested it

| Check | Result | Evidence |
|---|---|---|
| Consistency of the volume data | 15 of 15 rules hold | [p2-03](outputs/p2-03-consistency-at-volume.txt) |
| Same answer after every change | every query's sorted-row hash identical across baseline, indexed and tuned (Q08's `NOT EXISTS` and `NOT IN` forms both return the same 8,583 patients) | [comparison.md](results/comparison.md) |
| Plan stability | the plan shape was identical in all five runs of every measured query | [p2-05](outputs/p2-05-measure-baseline.txt), [p2-09](outputs/p2-09-measure-indexed.txt), [p2-12](outputs/p2-12-measure-tuned.txt) |
| Index usage | five new indexes used; `encounter_type_ix` used 0 times | [p2-09](outputs/p2-09-measure-indexed.txt) |
| Reproducible data | a second load matched the first in all 10 fingerprinted tables | [p2-14](outputs/p2-14-determinism.txt) |
| Pipeline | all steps exit 0; any failing step stops it | [run_p2.py](run_p2.py) |

The results are summarised in [analysis.md](analysis.md). The largest gains were the reorder report, from 1.8 s to about 1 ms with a partial covering index; the patients-without-a-visit report, from a 120-second timeout to about 200 ms once `NOT IN` was rewritten; and the monthly report, from about a second to 7 ms with a materialised view. The analysis also shows where an index was ignored, where one made a query slower, and what the indexes cost on writes.

To reproduce (about 20 minutes, including the second load for the determinism check):

```powershell
docker compose up -d --wait
.venv\Scripts\python portfolio-2-query-optimisation\run_p2.py
```

## Contents

| Path | What it holds |
|---|---|
| [sql/](sql/) | Volume data, workload, rewritten workload, indexes, tuning, sizes and data profile |
| [measure.py](measure.py), [write_cost.py](write_cost.py), [compare.py](compare.py), [determinism.py](determinism.py) | Measurement, write cost, the comparison table and the reproducibility check |
| [run_p2.py](run_p2.py) | The pipeline |
| [plans/](plans/) | Execution plans per phase |
| [results/](results/) | Query results with hashes, per-phase summaries, write costs and [comparison.md](results/comparison.md) |
| [outputs/](outputs/) | Evidence files p2-01 to p2-15 |
| [analysis.md](analysis.md) | Before/after table, analysis, and Q05 as relational algebra and a query tree |
