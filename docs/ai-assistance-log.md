# AI assistance log

I used Claude Code (Anthropic), running the Claude Opus 5.5 model (`claude-opus-5-5`), as a coding and writing assistant throughout this portfolio. I chose the case study and specified the architecture, technology stack, data conventions and order of work. I made the design decisions, specified each piece of work, and reviewed, ran and tested what the assistant produced, changing it where needed before committing it. The assistant generated scripts and drafted documentation to my specification, which saved time on repetitive work.

Each entry below separates what I decided from recommendations the assistant made that I accepted when I reviewed them.

## Phase 0: Discovery and overall plan (2026-11-14)

**My decisions:** I chose the outpatient clinic and diagnostics network as the case study and chose the name Itoju Clinics from three candidates the assistant proposed. I set the deadline, decided to commit at each milestone and decided how my name appears in the documents.

**Design decisions (approved at review):** None at this stage.

**AI assistance used:** The assistant inspected the empty repository, the installed tools and the free ports without changing anything. It read the CA brief, rendered the scanned course text's contents pages to images and mapped its sessions to page numbers, proposed three fictional organisation names and checked each against web searches for existing Nigerian providers, and drafted the overall plan.

**How it was verified:** I reviewed the findings and the plan before any file was created. The course page map was checked against the printed page numbers of ten pages; the offset between PDF and printed page numbers changes by one after printed page 145, and the map records this.

## Phase 1: Repository scaffold and case-study statement (2026-11-14)

**My decisions:** I approved the scaffold plan and the stack: PostgreSQL 16 and MongoDB 7.0 in Docker, bound to 127.0.0.1 on non-default ports, with Python pipelines and every piece of evidence captured through one helper. I approved installing Graphviz for the ER diagram.

**Design decisions (approved at review):** Pinning both Docker images by digest. Initialising PostgreSQL with the `C.UTF-8` collation and data checksums. Keeping only secrets in `.env`, so the evidence helper can redact every `.env` value without garbling ordinary output.

**AI assistance used:** The assistant generated `compose.yaml`, `scripts/evidence.py`, the two environment checks in `scripts/environment/`, `.gitignore`, `.gitattributes`, `.env.example` and `requirements.txt`, and drafted the root README with the case-study statement and the five portfolio READMEs. During implementation it made three changes to the plan: it pinned the Python packages to the newest releases at least two weeks old (psycopg 3.3.6 rather than 3.3.9 and pymongo 4.19.0 rather than 4.20.0, both of which were two days old); it pinned pymongo's dependency dnspython, which `pip freeze` showed was otherwise unpinned; and it ran MongoDB on port 37017 inside the container as well as on the host, because a MongoDB service already occupies port 27017 on this machine and a driver following the replica set's advertised address would otherwise have reached it.

**How it was verified:**

- `docker compose up -d --wait` brought both containers to healthy in 28 seconds without pulling any image.
- PostgreSQL reported 16.15, UTF8 encoding, `C.UTF-8` collation and data checksums on. MongoDB reported 7.0.45 as PRIMARY of replica set `rs0` with keyfile authentication, and committed a multi-document transaction.
- From the host, psycopg and pymongo both connected; pymongo's replica-set discovery returned `localhost:37017`, confirming it reached the container rather than the local service.
- The evidence helper was tested before use: a command exiting with 3 made it exit with 3, a missing program gave 127, every `.env` value was replaced by its marker, and no secret appeared in any test output.
- A fresh virtual environment installed the pinned packages exactly and `pip check` reported no broken requirements.
- Problems found and fixed: the evidence header showed Windows commands with POSIX quoting that was hard to read, so it now uses the platform's own quoting; dnspython was unpinned, as noted above.

## Phases 2–4: Portfolio 1, requirements, ER model, logical design, normalisation, build and tests (2026-11-14)

**My decisions:** Because the deadline was the same day, I combined the three Portfolio 1 phases into one milestone with one plan and one commit. I approved the scope of about thirty data tables plus code tables, which is wider than the original target of 14–18 because Portfolios 2–4 depend on the full data list. I approved installing Graphviz.

**Design decisions (approved at review):** Making the on-call rota part of the Portfolio 1 schema so the write-skew demonstration in Portfolio 3 uses the real schema. Drawing one ER overview plus three area diagrams instead of one unreadable diagram. Running every test inside a rolled-back subtransaction and recording which named rule stopped it. Checking the live catalogue against the schema document on every rebuild.

**AI assistance used:** The assistant read the course text's pages on the stages of design, ER notation and normalisation, then drafted the requirements, business rules and traceability, wrote the ER model as a small Python definition that generates all four Chen diagrams, and drafted the relational schema and normalisation documents and the Portfolio 1 README. It generated the six build scripts, the test harness, the five SQL test suites, the catalogue check and the pipeline. During implementation it made these choices beyond the approved plan: a sixth code table (`consent_purpose`) and a one-row `pseudonym_key` table for the analysts' pseudonymous keys, giving 37 relations rather than about 35; the `tg` and `fn` suffixes so that rules enforced by triggers and routines report a name like any other constraint; views that run with their owner's rights rather than `security_invoker`, because the restricted roles must have no access to the base tables; locking both stock rows in facility order inside `transfer_stock`; and composite foreign keys onto superkeys for cross-table rules such as an encounter's patient matching its appointment's.

**How it was verified:**

- `run_p1.py` rebuilt the database from empty and ran every suite, twice in succession, with all seven steps passing both times, which shows the build is idempotent.
- Constraint tests: 69 of 69 passed, each refused by the expected named rule. Routine tests: 28 of 28. Privilege tests: 45 of 45. Consistency checks: 14 of 14 with no violations. Normalisation: 7 functional dependencies hold in the data, 9 keys hold, and all 4 rejoins were lossless with `EXCEPT ALL` in both directions. Catalogue check: 37 relations, 0 mismatches, 9 roles and 3 views as documented.
- The catalogue check was tested for failure: with one column removed from a copy of the schema document, it reported the difference and exited with code 1.
- Problems found and fixed: the first ER diagrams underlined almost every attribute as if it were a key, because the script's test for key markers matched an empty string; this was spotted by looking at the rendered diagram and fixed. Cardinality labels sat in the middle of edges, where one appeared next to the wrong entity; they now sit at the entity end. Graphviz was installed but not on the PATH, so the diagram script falls back to the standard install folder. A sentence in the normalisation document wrongly said `drug` was the only relation with two candidate keys; it was corrected on review. One test that inserted an order and its result in a single statement was rewritten as two statements before it was first run, because a trigger cannot reliably see a row inserted earlier in the same statement.

## Phases 5–6: Portfolio 2, query processing and optimisation (2026-11-14)

**My decisions:** I approved the Portfolio 2 plan: deterministic, skewed volume data, a workload tied to the organisation's key operations, and baseline, indexed and tuned phases measured one technique at a time. I decided to stop the other projects' containers on this laptop for the measurement runs, and to generate billing data for the most recent 90 days only.

**Design decisions (approved at review):** Measuring with the median of five `EXPLAIN (ANALYZE, BUFFERS)` runs and treating buffers as the stable measure. Comparing a hash of every result row across phases. Measuring write cost and index size as well as read gains. Adding a pair of queries (Q12, Q13) that compare the cached stock totals with the ledger.

**AI assistance used:** The assistant generated the volume generator, the workload and its rewritten form, the indexing and tuning scripts, the measurement, write-cost, comparison and determinism scripts and the pipeline, and drafted the analysis and the README. During implementation it made these choices beyond the approved plan: dropping and re-adding the foreign keys and exclusion constraints around the bulk load so every row is re-validated in one pass; splitting the clinician's schedule into Q03 and Q03b after the baseline showed a partial index being refused; choosing the statistics fix (a higher target on `encounter.patient_id`) from the measured estimates; adding a determinism check and a data-profile step to the pipeline; and turning off JIT compilation for the measurements.

**How it was verified:**

- The final pipeline ran all fourteen steps successfully in 17.4 minutes; the data profile was captured as a fifteenth step afterwards.
- The Portfolio 1 consistency checks passed at volume (15 of 15).
- Every query returned the same result hash in every phase, and every measured plan was stable across its five runs.
- A second load into a scratch database matched the first in all ten fingerprinted tables.
- Problems found and fixed:
  - The first volume load stalled for over five minutes building invoice lines with a correlated subquery that scanned the whole prescription table for each invoice; it was cancelled (one transaction, rolled back) and rewritten with hash joins.
  - Two consistency checks used a pairwise self-join that was fine on the sample but quadratic at volume; they were rewritten as window functions, and a check replaying the ledger in time order was added.
  - The exploratory data turned out not to match the pipeline's because the cancelled load had advanced identity sequences and two inserts had no fixed order; both causes were removed and the determinism check added, and the Q02 and Q03 parameters were re-picked on the canonical data.
  - The write-cost test's rolled-back updates to one stock row left dead row versions that distorted a later query's plan; the touched tables are now vacuumed between blocks.
  - The first full pipeline run was stopped part-way so the Portfolio 1 evidence could be refreshed first, and the session it left in the database was terminated.
- Findings reported as measured rather than smoothed over: one index made a query slower (Q07); one was never used (Q10); and three of the four write-cost changes were within run-to-run noise.

## Phases 7–8: Portfolio 3, transactions and concurrency (2026-11-14)

**My decisions:** I approved the Portfolio 3 plan: demonstrations driven by real concurrent sessions with deterministic interleaving, a sandbox schema for scenarios that need a safeguard removed, a real crash test, and the Portfolio 1 consistency checks after every demonstration.

**Design decisions (approved at review):** Confirming every wait from a separate monitoring session with `pg_blocking_pids()` before letting the other session continue. Showing each concurrency problem next to the mechanism that prevents it. Basing the hot-row conclusion on the lock-wait share and absolute throughput rather than a scaling ratio.

**AI assistance used:** The assistant generated the shared session helpers, the three demonstration scripts, the sandbox schema and the pipeline, and drafted the replay guide, the scenario analysis in `concurrency.md` and the README. During implementation it chose the specific clinic scenarios (an optional SMS-consent step for the savepoint, the on-call rota for write skew, a daily queue-number counter for the hot row), and it kept the monitoring sessions as superuser so they can see other sessions' wait events.

**How it was verified:**

- The pipeline ran all four steps in 2.7 minutes.
- Atomicity and durability: 16 of 16 checks, including a real SIGKILL of the database container with the write-ahead-log recovery captured from the server log.
- Isolation: 9 of 9 checks. Locking: 20 of 20 checks.
- The Portfolio 1 consistency suite passed 15 of 15 after each demonstration.
- Problems found and fixed:
  - The first locking run stopped with "B never blocked". The monitoring session had switched to a role that `pg_stat_activity` hides other users' wait events from, and sessions left open from earlier scenarios shared the same label. The monitor now keeps superuser rights, the detector looks only for a session that is actually blocked, and each scenario closes its sessions.
  - The logged SQL showed parameter placeholders instead of values; it now shows the bound values.
  - The free-slot queries were rewritten before their first run so they could use the GiST indexes.
- Timings varied between runs: the 8-session counter-row throughput was 130 tickets/s in a trial and 218 in the evidence run. The lock-wait share reproduced closely (75.7% and 75.3%), so the conclusion rests on the lock-wait share.

## Phase 9: Portfolio 4, NoSQL and advanced data models (2026-11-14)

**My decisions:** I approved the Portfolio 4 plan and chose to load the full data, all 714,247 encounters, rather than a subset, so that every comparison with PostgreSQL is like for like.

**Design decisions (approved at review):** Deriving the collections from access patterns, embedding what a visit writes together and referencing a patient's unbounded visits. Comparing every MongoDB query's rows with PostgreSQL's. Adding a time-series collection for home monitoring and a referral graph traversed with `$graphLookup`.

**AI assistance used:** The assistant generated the collection model and validators, the loader, the validation, workload, time-series, graph and transaction scripts and the pipeline, and drafted `document-model.md`, `suitability.md` and the README. It chose the remote-monitoring and referral scenarios, which have no counterpart in the Portfolio 1 schema and are generated deterministically from the same patients and clinicians. It checked the MongoDB 7.0 limits it relies on (time-series restrictions and the `$graphLookup` memory limit) against the official manual before writing about them.

**How it was verified:**

- The pipeline ran all seven steps in 7.4 minutes.
- The load matched PostgreSQL on 13 counts and totals.
- Validation passed 16 of 16 checks, including ten kinds of bad document or update rejected with `errInfo`.
- Every workload query returned the same rows as PostgreSQL before and after indexing (8 and 16 checks).
- Time series 7 of 7, graph 3 of 3 (with `$graphLookup` matching an independent breadth-first search), transactions 8 of 8.
- Problems found and fixed:
  - A module first named `collections.py` would have shadowed Python's standard library; it was renamed before the first run.
  - Per-encounter subqueries in the loader would have scanned unindexed child tables; the loader was written with set-based aggregation instead.
  - The graph's starting clinician could have been an internal-medicine doctor rather than a GP; the selection was corrected.
  - The suitability analysis was trimmed from 825 to 798 words to stay within its limit.

## Phase 10: Portfolio 5, distributed and cloud database exercise (2026-11-14)

**My decisions:** I chose to do both a design discussion and two working setups, PostgreSQL streaming replication with a failover and a sharded MongoDB cluster, rather than either one alone, and I approved the Portfolio 5 plan.

**Design decisions (approved at review):** Measuring the failover outage as the longest gap between two acknowledged writes rather than from timestamps around the kill. Simulating failures by stopping or killing containers rather than pausing them, since a paused process still receives buffered data when it resumes. Rebuilding both clusters from empty volumes on every run.

**AI assistance used:** The assistant generated the two Compose files, the primary's initialisation script and the standbys' start-up script, the replication and sharding demonstrations and the pipeline, and drafted `architecture.md`, `setup.md` and the README. During implementation it made these choices beyond the approved plan: a small `appointment_request` table on the replication cluster rather than the full schema; a separate password for the replication role, kept in `.env` with the other secrets; loading every seventh encounter (102,035) into the sharded cluster rather than all of them, to keep the clusters within the laptop's memory; splitting the ranged collection at 1 November 2025 and moving the older chunk so each shard held one range before the new writes arrived; and setting `synchronous_standby_names` with `ALTER SYSTEM` and keeping 256 MB of WAL on the primary, for the reasons below.

**How it was verified:**

- The pipeline ran both steps in 2.6 minutes, each from empty volumes.
- Replication and failover passed 16 of 16 checks, including the check that every one of the 1,008 writes acknowledged under synchronous commit was on the new primary.
- The sharded cluster passed 10 of 10 checks.
- Every figure in `architecture.md` and the README was checked against the two evidence files.
- Problems found and fixed:
  - The primary hung on its first start. With `synchronous_standby_names` on the command line, the image's own initialisation waited for a standby that did not exist yet. The setting moved to `ALTER SYSTEM` in the initialisation script.
  - When both standbys cloned the primary at once, one failed with "requested WAL segment … has already been removed". The primary now keeps 256 MB of WAL, and two further rebuilds from empty volumes succeeded.
  - The first failover run hung for over ten minutes. `pg_basebackup` had copied the primary's `synchronous_standby_names`, so the promoted standby waited for a synchronous partner of its own. The run was stopped, the start-up script now clears the setting after cloning, and the writer has a statement timeout, TCP timeouts and a bounded wait, with a check that it finished.
  - A log line labelled the asynchronous standby "sync", because the label was cut from the end of its name. The labels are now an explicit mapping, and the evidence was regenerated.
  - `architecture.md` was trimmed from 1,571 to 1,377 words to stay within its limit.
