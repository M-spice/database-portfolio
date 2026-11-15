# Individual technical reflection

## Design choices I would make again

**An outpatient network as the case study.** It gave every part of the course real work to do: clinical records that need strict integrity and an audit trail, clinicians' time booked concurrently, pharmacy stock that is naturally a ledger, lab results whose shape changes from test to test, and health data in five cities under the NDPA 2023.

**A named rule behind every constraint, and a test for each rule.** Every constraint, trigger and routine check has a name, and each test inserts a bad row and records which named rule stopped it. All 69 constraint tests passed, and the names made the later portfolios easier to explain.

**Stock as a ledger with a cached total.** Every receipt, dispense and transfer is a row in the ledger, and a trigger keeps `stock_on_hand` in step, which even the owner cannot edit directly. Reading Ikeja's stock from the cache took 4 pages in every phase, against about 9,000 to recompute it from the ledger, and both gave the same result.

**Deterministic data and result hashes.** Every value in the volume data comes from a hash of a row number and a seed, and every query result is hashed. The comparison between the baseline, indexed and tuned phases is therefore like for like: the same rows, and proof that each optimisation returned the same answer.

**The full data in MongoDB.** I chose to load all 714,247 encounters rather than a sample, so that the 13 counts and totals and every workload query could be compared directly with PostgreSQL. All of them matched.

**Synchronous replication inside a city, asynchronous between cities,** with the failover outage measured from the client's acknowledged writes. That measure is what showed that none of the 1,008 acknowledged writes was lost.

## Challenges and how they were solved

**Data that was not deterministic.** Figures from an early exploratory load differed from the pipeline's, such as the number of distinct patients with encounters. A cancelled first load had used up identity-sequence values, which are never rolled back, and two `INSERT … SELECT` statements had no `ORDER BY`. Both were fixed. A determinism check now loads the data a second time into a scratch database and compares a fingerprint of each table; all 10 tables are identical.

**Checks that were fine on sample data and far too slow at volume.** The double-booking checks were pairwise self-joins, quadratic at volume. They were rewritten with a running maximum over a window. The first load also stalled on a subquery per invoice that scanned an unindexed table, and was rebuilt with hash joins.

**One test spoiling the next.** The write-cost test updated one stock row thousands of times and rolled back, and the dead row versions distorted the next phase's plan for the stock query. A `VACUUM (ANALYZE)` between blocks fixed it.

**A locking demonstration that never saw a lock.** The monitoring session had switched to a role that `pg_stat_activity` hides other users' wait events from, and idle sessions from earlier scenarios shared the same label. The monitor now keeps its rights, and each scenario closes its sessions.

**A standby that waited for itself.** After a failover, the promoted standby refused to complete any commit. `pg_basebackup` had copied the primary's `synchronous_standby_names`, so the new primary was waiting for a synchronous partner it did not have. The standby's start-up script now clears the setting, and the test client has timeouts so it can never hang silently again.

## Lessons learned

1. A test is only as good as the volume it runs at. Checks and queries that are instant on sample data can be quadratic or unindexed at scale.
2. Sequences are not transactional. A rolled-back load still changes the next load's identifiers, so reproducible data needs a full rebuild and an explicit order.
3. Buffers are a more stable measure than milliseconds. Q10 ran the same plan in 345 ms and then 176 ms. When I rebuilt everything from a clean copy, most medians moved again, while 11 of the 15 queries read exactly the same number of buffers.
4. An index helps only a selective query. PostgreSQL's planner declined an index on a low-selectivity column. MongoDB's took one that led to 349,504 documents, half the collection, and gained nothing.
5. Better statistics cannot fix a parameter the planner never sees. Raising the statistics target improved the distinct-patient estimate from about half of the 57,938 patients to 87%, but Q02's estimate for its heaviest patient got worse, because that patient is chosen at run time.
6. Deadlocks come from lock order. The same 400 stock transfers caused 100 deadlocks in an arbitrary order and none in a fixed one.
7. A copy carries its configuration with it. Only an end-to-end failover test showed that a cloned standby had inherited a setting that made sense only on the primary.

## What I would do next

- Add automatic failover with Patroni, a consensus store and fencing, and rejoin the old primary with `pg_rewind`.
- Run the clusters on separate machines, or inject network delay, to measure the real cost of synchronous replication between Lagos and Abuja.
- Give each MongoDB shard three members, so that a shard survives the loss of a member.
- Feed the MongoDB read model continuously from PostgreSQL by change data capture, instead of loading it once.
- Build the TLS, encryption at rest, backups and point-in-time recovery that the design describes.

## Working with an AI assistant

I used Claude Code as a coding and writing assistant. I chose the case study, approved a plan before each part of the work and reviewed each report before committing it. The assistant generated the scripts and drafted the documents. What made this work was insisting that every number come from a captured evidence file and every claim from an automated check. Several of the problems above, including the non-deterministic data and the standby waiting for itself, were found by checks and evidence rather than by reading code.
