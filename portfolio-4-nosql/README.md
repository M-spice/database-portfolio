# Portfolio 4: NoSQL and Advanced Data Models

The same clinical data modelled as MongoDB documents, shaped around how clinicians and branches actually read it, with an account of where the document model suits Itoju Clinics better than the relational one and where it does not.

## Required evidence

- [x] NoSQL model based on the same case study: [document-model.md](document-model.md) (access patterns, collections, the embed-or-reference decision for every relationship, and real sample documents)
- [x] Document, key-value, column or graph example: a document model ([p4-01](outputs/p4-01-load.txt), [p4-04](outputs/p4-04-workload-after.txt)), a time-series collection ([p4-05](outputs/p4-05-timeseries.txt)) and a graph traversal ([p4-06](outputs/p4-06-graph.txt)); key-value and wide-column stores are discussed in [suitability.md](suitability.md)
- [x] Implementation evidence: [outputs/](outputs/), the `explain()` output in [explain/](explain/), and the scripts in [mongo/](mongo/)
- [x] Explanation of suitability: [suitability.md](suitability.md)

## How I implemented it

**The model.** [document-model.md](document-model.md) starts from nine access patterns and derives seven collections and a view from them. A visit embeds everything written during it: vital signs, diagnoses, prescriptions, notes and amendments. Patients embed their bounded lists (phones, allergies, next of kin, consents) and reference their unbounded visits. Laboratory results live in their own collection with a polymorphic `result`. Invoices embed their lines and payments. Stock is kept in small separate documents, because every dispense updates it.

**The data.** [mongo/load.py](mongo/load.py) builds every document inside PostgreSQL from the Portfolio 2 database, using set-based JSON aggregation, and streams the documents into MongoDB in batches of 5,000. Loading all 60,012 patients, 714,247 encounters, 241,675 lab results and 87,477 invoices takes about five and a half minutes. It then compares 13 counts and totals between the two databases, from the number of diagnoses and clinical notes to the kobo invoiced and paid; all 13 match ([p4-01](outputs/p4-01-load.txt)). MongoDB runs as a single-node replica set, because multi-document transactions need one.

**Rules.** [mongo/model.py](mongo/model.py) gives each collection a `$jsonSchema` validator and `$expr` checks for rules that compare fields within a document. [mongo/validation.py](mongo/validation.py) shows a valid document accepted and then one bad document per rule rejected, each with MongoDB's `errInfo`. It also shows a unique index refusing a duplicate hospital number, and an analyst user who can read a de-identified view but gets `Unauthorized` on the collections behind it ([p4-02](outputs/p4-02-validation.txt)).

**Queries.** [mongo/workload.py](mongo/workload.py) asks MongoDB the Portfolio 2 questions that make sense for documents, plus two document-native ones. For each query it runs the matching PostgreSQL SQL from Portfolio 2's workload files and compares the rows. `explain("executionStats")` is captured before and after five indexes chosen from the access patterns.

**Time series, graph, transactions.**
- [mongo/timeseries.py](mongo/timeseries.py) enrols the 100 patients with the most hypertension visits in a home-monitoring programme, generates two weeks of hourly blood-pressure readings deterministically, and aggregates them by hour and by week.
- [mongo/graph.py](mongo/graph.py) builds a referral network from the clinicians' departments and branches, and follows it with `$graphLookup`.
- [mongo/transactions.py](mongo/transactions.py) dispenses and invoices inside multi-document transactions.

## How I tested it

| Demonstration | Checks | What they show | Evidence |
|---|---|---|---|
| Load | 13 of 13 | Patients, phones, encounters, vital signs, diagnoses, notes, prescribed units, lab results, invoices, kobo invoiced and paid, clinicians and stock all equal PostgreSQL's | [p4-01](outputs/p4-01-load.txt) |
| Validation and access control | 16 of 16 | 10 kinds of bad document or update rejected; duplicate key refused; the analyst reads only the view | [p4-02](outputs/p4-02-validation.txt) |
| Workload before indexes | 8 of 8 | Every MongoDB result identical to PostgreSQL's | [p4-03](outputs/p4-03-workload-before.txt) |
| Workload after indexes | 16 of 16 | Identical to PostgreSQL's and to the results before indexing | [p4-04](outputs/p4-04-workload-after.txt) |
| Time series | 7 of 7 | Bucketed storage, hourly and weekly windows, and two documented limits shown failing as documented | [p4-05](outputs/p4-05-timeseries.txt) |
| Graph | 3 of 3 | `$graphLookup` reaches exactly the referrals a breadth-first search finds, with and without a date restriction | [p4-06](outputs/p4-06-graph.txt) |
| Transactions | 8 of 8 | Commit, abort, the inconsistency left without a transaction, an immediate write conflict, and a retry | [p4-07](outputs/p4-07-transactions.txt) |

What the indexes changed, from [p4-04](outputs/p4-04-workload-after.txt):

| Query | Plan before → after | Documents examined before → after | Median ms before → after |
|---|---|---|---|
| M01 patient by phone | COLLSCAN → IXSCAN | 60,012 → 1 | 109.9 → 3.3 |
| M02 latest 20 visits | SORT over COLLSCAN → IXSCAN under LIMIT | 714,247 → 20 | 1,428.7 → 6.6 |
| M05 monthly diagnoses, one year | COLLSCAN → IXSCAN | 714,247 → 349,504 | 5,130.9 → 3,361.5 |
| M07 lab turnaround, 30 days | COLLSCAN → IXSCAN | 241,675 → 10,018 | 427.6 → 57.5 |
| M08 no visit in a year | COLLSCAN → IXSCAN | 714,247 → 350,778 | 2,525.2 → 1,943.9 |
| M09 frequent attenders | COLLSCAN → IXSCAN | 714,597 → 29,914 | 1,246.7 → 182.7 |
| N01 one whole visit | IDHACK → IDHACK | 1 → 1 | 2.4 → 2.7 |
| N02 asthma by branch (multikey) | COLLSCAN → IXSCAN | 714,247 → 4,149 | 1,929.1 → 17.0 |

Selective queries now read only the documents they return. M05 and M08 still read half the collection, because their date ranges cover half of it. MongoDB's planner nevertheless took the index, which is part of the comparison in [suitability.md](suitability.md).

To reproduce (five to eight minutes; it rebuilds the MongoDB database from the current PostgreSQL data):

```powershell
docker compose up -d --wait
.venv\Scripts\python portfolio-4-nosql\run_p4.py
```

## Contents

| Path | What it holds |
|---|---|
| [document-model.md](document-model.md) | Access patterns, collections, embedding decisions, rules and sample documents |
| [suitability.md](suitability.md) | Relational against document for this organisation; ACID, DBASE and CAP; key-value, wide-column and graph; conclusion |
| [mongo/](mongo/) | Model and validators, load, validation, workload, time series, graph and transactions |
| [run_p4.py](run_p4.py) | Runs everything and captures the evidence |
| [explain/](explain/) | `explain("executionStats")` per query before and after indexing, and for the time-series query |
| [results/](results/) | Per-phase workload summaries and the before/after comparison |
| [outputs/](outputs/) | Evidence |
