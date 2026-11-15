# AI use declaration

## 1. Tool and model

Claude Code (Anthropic), running the Claude Opus 5.5 model (`claude-opus-5-5`), used inside Visual Studio Code on Windows in November 2026, as a coding and writing assistant.

## 2. What I used it for

I chose the case study and specified the architecture, technology stack, data conventions and order of work. I made the design decisions, approved a plan before each part of the work began, and reviewed each report before committing it. The assistant generated the scripts and drafted the documentation to my specification, which saved time on repetitive work. It never ran a command that changes the repository's history; I made and pushed every commit myself. The [AI assistance log](ai-assistance-log.md) records each step in detail.

| Part | What I did | What the assistant did |
|---|---|---|
| Case study and plan | Chose an outpatient clinic network and the name Itoju Clinics from three candidates; set the deadline and decided to commit at each milestone | Proposed the names and checked them against existing Nigerian providers; drafted the overall plan |
| Environment | Approved the stack: PostgreSQL 16 and MongoDB 7.0 in Docker, bound to 127.0.0.1, with Python pipelines; approved installing Graphviz | Generated the Compose file, the evidence helper, the environment checks and the pinned requirements |
| Portfolio 1: design | Approved the scope of 37 relations and the plan | Drafted the requirements, ER model, relational schema and normalisation; generated the diagrams, build scripts and tests |
| Portfolio 2: optimisation | Approved the plan; decided to stop other projects' containers for the measurements and to generate 90 days of billing data | Generated the volume data, workload, indexes, tuning and measurement scripts; drafted the analysis |
| Portfolio 3: transactions | Approved the plan | Generated the concurrent-session demonstrations and the sandbox schema; drafted the scenario analysis and replay guide |
| Portfolio 4: NoSQL | Chose to load the full data rather than a sample | Generated the document model, loader and demonstrations; drafted the model and suitability documents |
| Portfolio 5: distributed | Chose to build both working setups as well as the design | Generated both clusters and their demonstrations; drafted the architecture and set-up documents |
| Final documents | Approved the plan | Drafted the [reflection](reflection.md) from the events in my development log, this declaration, the references and the LMS summary; ran the fresh-run check |

Design recommendations from the assistant that I accepted at review include:

- pinning both Docker images by digest
- initialising PostgreSQL with the `C.UTF-8` collation and data checksums
- one ER overview plus three area diagrams instead of one unreadable diagram
- running every constraint test inside a rolled-back subtransaction and recording which named rule stopped it
- measuring with the median of five `EXPLAIN (ANALYZE, BUFFERS)` runs, and comparing a hash of every result row across phases
- confirming every lock wait from a separate session with `pg_blocking_pids()`
- deriving the MongoDB collections from access patterns
- measuring the failover outage as the longest gap between two acknowledged writes

## 3. How the output was reviewed and verified

**Run, not assumed.** Every script was run, and every output used as evidence was captured unedited through one helper. The helper records the time, command, exit code, duration and versions, and replaces every value from `.env` with a redaction marker.

**Automated checks.** Every one of the following passes in the committed evidence:

| Portfolio | Checks |
|---|---|
| 1 | 69 constraint tests, 28 routine tests, 45 privilege tests, 15 consistency checks, and a catalogue check of the live database against the schema document |
| 2 | 15 queries returning identical results in all three phases, 15 consistency checks at volume, and 10 tables identical when the data is generated twice |
| 3 | 45 checks across atomicity, isolation and locking, with the 15 consistency checks after each demonstration |
| 4 | 71 checks across loading, validation, the workload, time series, graph and transactions |
| 5 | 26 checks across replication, failover and sharding |

**Cross-checks.** MongoDB's data was compared with PostgreSQL's on 13 counts and totals, and every MongoDB query's rows with the same query in SQL. `$graphLookup` was compared with an independent breadth-first search. After the failover, every acknowledged write was looked up on the new primary.

**Errors found and corrected.** Checks and reviews found real problems, all described in the [AI assistance log](ai-assistance-log.md):

- an ER diagram that underlined almost every attribute
- volume data that differed between loads
- consistency checks that were quadratic at volume
- a write test whose dead row versions distorted the next phase's plan
- a locking demonstration whose monitor could not see other sessions' waits
- a MongoDB port that would have reached a different server already on the laptop
- a module name that would have shadowed Python's standard library
- a promoted standby waiting for itself
- a race between two standbys cloning at once
- a mislabelled log line
- an incorrect statement about candidate keys in the normalisation document

**Figures and links.** Every figure in the documents was checked against an evidence file. A link checker confirmed that every relative link and anchor resolves. A scan confirmed that no `.env` value appears in any committed file.

**Writing.** The assistant drafted the documents in plain first-person British English, tied every claim to an evidence file, and trimmed two documents to their word limits.
