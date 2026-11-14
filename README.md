# Itoju Clinics: Advanced Database Systems Portfolio

Mariam Folashade Arogundade · MIT 8103 Advanced Database Systems · Master of Information Technology, Miva Open University · 2026/2027 first semester

> Itoju Clinics is a fictional organisation and every record in this repository is synthetic. Patient and clinician names come from a small generated list, national-ID-like numbers begin with 999 and phone numbers sit in an obviously fake range. Any resemblance to a real provider or person is unintended.

## The organisation

**Organisation.** Itoju Clinics (*ìtọ́jú* is Yoruba for care) is a simulated network of twelve outpatient clinics and diagnostic laboratories in Lagos, Abuja, Ibadan, Enugu and Kano. Every branch sees walk-in and booked patients and runs its own pharmacy and laboratory.

**Nature of the business and system.** The database is the network's clinical and operational system of record. It registers patients, books appointments against clinicians' time slots, records consultations with their vital signs, diagnoses and clinical notes, handles prescribing and dispensing from each branch pharmacy, orders laboratory tests and records their results, moves stock between branches, invoices and takes payment by cash, card or HMO, and keeps an audit trail of who opened which patient record.

**Users of the database.**

| User | What they do with the data |
|---|---|
| Patients | Book and manage appointments through the booking app or the front desk; they never query the database directly |
| Receptionists | Register patients; book, reschedule and cancel appointments; no access to clinical detail |
| Clinicians (doctors and nurses) | Record encounters, vital signs, diagnoses and notes; prescribe; order tests; read the patient timeline |
| Pharmacists | Dispense prescriptions; receive, adjust and transfer stock |
| Laboratory scientists | Record results against lab orders |
| Billing officers | Raise invoices and record payments |
| Medical-records and data-protection officers | Manage consent and corrections; review who accessed a record |
| Analysts | Report on de-identified data only |
| Internal auditors | Read-only access, including the record-access log |
| Clinic application service account | The identity the booking and clinic applications connect as |
| Database administrator | Owns the schema, roles, backups and maintenance |

**Major data stored.**

- Patients, with a composite name and address, several phone numbers, allergies, next of kin and consent records
- Facilities, departments and clinicians (a clinician can work in several departments), with schedules and bookable slots
- Appointments and their status history
- Encounters with vital signs, diagnoses (synthetic ICD-10-style codes) and append-only clinical notes with amendments
- The drug catalogue, prescriptions and prescription items
- Pharmacy stock per facility, with a ledger of every receipt, dispense, transfer and adjustment
- The lab test catalogue, lab orders and results
- Invoices, invoice lines and payments, held in kobo
- A log of every staff read of a patient record

**Key operations.**

- Register a patient
- Book, reschedule or cancel an appointment without ever double-booking a clinician
- Record an encounter: vital signs, diagnoses and notes
- Prescribe and dispense, with stock never going negative
- Order a lab test and record its result
- Transfer stock between branches
- Invoice and take payment
- Show a clinician a patient's timeline
- Produce the daily clinic schedule, the monthly diagnosis report per facility, the pharmacy reorder report and the lab turnaround report
- Reconcile stock on hand against the movement ledger
- Show who viewed a patient's record

I chose an outpatient network because it gives every topic in the course a real job to do. Clinical records need strict integrity and an audit trail. Booking clinicians' time creates genuine concurrency. Pharmacy stock is naturally a ledger. Lab results change shape from test to test. And twelve branches in five cities, holding health data that the Nigeria Data Protection Act 2023 treats as sensitive, make distribution and data residency design questions rather than exercises.

## Repository map

```
.
├── README.md
├── compose.yaml                           PostgreSQL 16 and MongoDB 7.0 (single-node replica set)
├── requirements.txt                       pinned Python packages
├── .env.example                           variables to copy into .env
├── scripts/
│   ├── evidence.py                        runs a command and saves its output under a standard header
│   └── environment/                       server environment checks
├── portfolio-1-database-design/
│   ├── design/                            requirements, Chen ER model, relational schema, normalisation
│   ├── db/                                PostgreSQL build scripts
│   ├── tests/                             constraint, routine, privilege, consistency and normalisation tests
│   ├── run_p1.py                          rebuilds, tests and captures the evidence
│   └── outputs/                           evidence
├── portfolio-2-query-optimisation/
│   ├── sql/                               volume data, workload, indexes, tuning
│   ├── measure.py, write_cost.py          plans, timings, buffers, result hashes; write cost of indexes
│   ├── run_p2.py                          loads the volume data and measures every phase
│   ├── plans/, results/                   execution plans and results per phase, comparison table
│   ├── analysis.md                        performance analysis
│   └── outputs/                           evidence
├── portfolio-3-transactions-concurrency/
│   ├── demos/                             concurrent-session demonstrations with automated checks
│   ├── run_p3.py                          runs every demonstration, then the consistency checks
│   ├── concurrency.md, replay-guide.md    what the results mean; two-terminal scripts
│   └── outputs/                           evidence
├── portfolio-4-nosql/
│   ├── mongo/                             model and validators, load from PostgreSQL, workload, time series, graph, transactions
│   ├── document-model.md, suitability.md  the document design; where MongoDB fits and where it does not
│   ├── run_p4.py                          loads MongoDB and runs every demonstration
│   └── explain/, results/, outputs/       explain() output, comparisons, evidence
├── portfolio-5-distributed-cloud/
└── docs/
    ├── ai-assistance-log.md
    └── references.md
```

## Status

| Part | Scope | Status |
|---|---|---|
| [Portfolio 1: Database Design and Modelling](portfolio-1-database-design/README.md) | Requirements, Chen ER model, relational schema, normalisation to BCNF, a PostgreSQL build with its rules tested | Complete |
| [Portfolio 2: Query Processing and Optimisation](portfolio-2-query-optimisation/README.md) | Volume data, a workload of key queries, execution plans before and after indexing and tuning | Complete |
| [Portfolio 3: Transactions and Concurrency](portfolio-3-transactions-concurrency/README.md) | Commit, rollback, isolation anomalies, locking, deadlock and crash recovery with live concurrent sessions | Complete |
| [Portfolio 4: NoSQL and Advanced Data Models](portfolio-4-nosql/README.md) | MongoDB document model with validation, time-series and graph examples, and transactions | Complete |
| [Portfolio 5: Distributed and Cloud Database Exercise](portfolio-5-distributed-cloud/README.md) | Distribution design, PostgreSQL streaming replication with failover, a MongoDB sharded cluster | Not started |
| Final documentation | LMS summary, technical reflection, AI-use declaration, references | Not started |

## Technology

| Component | Version | Role |
|---|---|---|
| PostgreSQL | 16.15 (`postgres:16`, pinned by image digest) | Relational system of record |
| MongoDB | 7.0.45 (`mongo:7.0`, pinned by image digest) | Document model |
| Docker and Compose | 28.4.0 and 2.39.2 | Runs both servers, bound to 127.0.0.1 only |
| Python | 3.13.5 with psycopg 3.3.6, pymongo 4.19.0, tabulate 0.10.0, tzdata 2026.6 | Pipelines, demonstrations and evidence capture |
| Graphviz | 16.1.1 | Draws the ER diagrams from their DOT sources |

PostgreSQL is initialised with UTF-8 encoding, the `C.UTF-8` collation and data checksums. The collation sorts by code point, so it cannot drift when the operating system's locale library is updated, and plain B-tree indexes can serve prefix searches. Data checksums let the server detect a corrupted page when it reads it.

MongoDB runs as a one-member replica set because multi-document transactions need one, and members authenticate with a keyfile generated inside the container when it first starts, so no key is ever stored in the repository. The server listens on port 37017 inside its container as well as on the host, and the replica set advertises itself as `localhost:37017`. A driver that follows the advertised address therefore always reaches this container and never a MongoDB service installed on the default port.

## How to run

Requirements: Docker Desktop, Python 3.11 or later, and Windows PowerShell (the commands below) or any POSIX shell with the equivalent paths.

```powershell
Copy-Item .env.example .env          # then replace both placeholder passwords with long random values
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
docker compose up -d --wait
```

PostgreSQL then listens on `127.0.0.1:55432` and MongoDB on `127.0.0.1:37017`. From the host, connect to MongoDB with `directConnection=true`.

Every output used as evidence is captured through one helper, which saves the raw output under a header recording the capture time (Lagos and UTC), the command, its exit code and duration, the host, the Docker version and the server version, and replaces every value from `.env` with a `[REDACTED]` marker:

```powershell
.venv\Scripts\python scripts\evidence.py --out <file> --title "<title>" -- <command>
```

The helper exits with the command's own exit code, so a failed step stops any pipeline that calls it.

Each portfolio has one pipeline that rebuilds its state from scratch, runs every test and demonstration, and rewrites its evidence:

```powershell
.venv\Scripts\python portfolio-1-database-design\run_p1.py
.venv\Scripts\python portfolio-2-query-optimisation\run_p2.py
.venv\Scripts\python portfolio-3-transactions-concurrency\run_p3.py
.venv\Scripts\python portfolio-4-nosql\run_p4.py
```

## Evidence index

| Requirement | Evidence |
|---|---|
| Selected organisation: name, nature, users, data and operations | [The organisation](#the-organisation) |
| Configuration and environment | [compose.yaml](compose.yaml), [PostgreSQL environment](portfolio-1-database-design/outputs/p1-environment-postgres.txt), [MongoDB environment](portfolio-1-database-design/outputs/p1-environment-mongo.txt) |
| Portfolio 1: case study description | [Requirements](portfolio-1-database-design/design/requirements.md) |
| Portfolio 1: ER diagram | [Overview](portfolio-1-database-design/design/er-overview.svg) and three [area diagrams](portfolio-1-database-design/README.md#required-evidence) |
| Portfolio 1: relational schema, keys and constraints | [Relational schema](portfolio-1-database-design/design/relational-schema.md), [build scripts](portfolio-1-database-design/db/) |
| Portfolio 1: normalisation explanation | [Normalisation](portfolio-1-database-design/design/normalisation.md), [lossless-join proof](portfolio-1-database-design/outputs/p1-normalisation.txt) |
| Portfolio 1: tests | [Constraints](portfolio-1-database-design/outputs/p1-test-constraints.txt), [routines](portfolio-1-database-design/outputs/p1-test-routines.txt), [privileges](portfolio-1-database-design/outputs/p1-test-privileges.txt), [consistency](portfolio-1-database-design/outputs/p1-test-consistency.txt), [catalogue](portfolio-1-database-design/outputs/p1-catalogue-check.txt) |
| Portfolio 2: SQL queries | [Workload](portfolio-2-query-optimisation/sql/workload.sql), [rewritten workload](portfolio-2-query-optimisation/sql/workload_rewritten.sql) |
| Portfolio 2: query results | [Results per phase](portfolio-2-query-optimisation/results/) |
| Portfolio 2: execution plans | [Plans per phase](portfolio-2-query-optimisation/plans/) |
| Portfolio 2: indexing and optimisation evidence | [Comparison](portfolio-2-query-optimisation/results/comparison.md), [indexes](portfolio-2-query-optimisation/sql/indexing.sql), [tuning](portfolio-2-query-optimisation/outputs/p2-11-tuning.txt), [sizes before](portfolio-2-query-optimisation/outputs/p2-04-sizes-baseline.txt) and [after](portfolio-2-query-optimisation/outputs/p2-08-sizes-indexed.txt), [write cost before](portfolio-2-query-optimisation/outputs/p2-06-write-cost-baseline.txt) and [after](portfolio-2-query-optimisation/outputs/p2-10-write-cost-indexed.txt) |
| Portfolio 2: performance analysis | [Analysis](portfolio-2-query-optimisation/analysis.md) |
| Portfolio 3: commit and rollback | [Atomicity and durability](portfolio-3-transactions-concurrency/outputs/p3-02-atomicity.txt) |
| Portfolio 3: isolation | [Isolation levels](portfolio-3-transactions-concurrency/outputs/p3-03-isolation.txt) |
| Portfolio 3: concurrency issue and control mechanism | [Locking, deadlock and hot row](portfolio-3-transactions-concurrency/outputs/p3-04-locking.txt), [scenario table](portfolio-3-transactions-concurrency/concurrency.md) |
| Portfolio 3: screenshots and output evidence | [Outputs](portfolio-3-transactions-concurrency/outputs/), [replay guide](portfolio-3-transactions-concurrency/replay-guide.md) |
| Portfolio 4: NoSQL model on the same case study | [Document model](portfolio-4-nosql/document-model.md), [load and comparison with PostgreSQL](portfolio-4-nosql/outputs/p4-01-load.txt) |
| Portfolio 4: document, column, key-value or graph example | [Documents and indexes](portfolio-4-nosql/outputs/p4-04-workload-after.txt), [time series](portfolio-4-nosql/outputs/p4-05-timeseries.txt), [graph](portfolio-4-nosql/outputs/p4-06-graph.txt) |
| Portfolio 4: implementation evidence | [Validation](portfolio-4-nosql/outputs/p4-02-validation.txt), [transactions](portfolio-4-nosql/outputs/p4-07-transactions.txt), [explain output](portfolio-4-nosql/explain/) |
| Portfolio 4: explanation of suitability | [Suitability](portfolio-4-nosql/suitability.md) |

## Academic integrity and AI use

I used Claude Code (Anthropic), running the Claude Opus 5.5 model, as a coding and writing assistant. I chose the case study and specified the architecture, technology stack, data conventions and order of work. I made the design decisions, specified each piece of work, and reviewed, ran and tested what the assistant produced, changing it where needed before committing it. The assistant generated scripts and drafted documentation to my specification, which saved time on repetitive work. The [AI assistance log](docs/ai-assistance-log.md) records what it did at each step and how I checked it.

## References

[References](docs/references.md), in APA 7th edition.
