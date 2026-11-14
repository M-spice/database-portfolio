# Portfolio 3: Transactions and Concurrency

What keeps Itoju Clinics' bookings, stock and payments correct when many staff work at once, or when the server fails part-way through: transactions, isolation levels and locking, shown with real concurrent sessions.

## Required evidence

- [x] Commit: booking committed, invisible until COMMIT, and surviving a crash ([p3-02-atomicity.txt](outputs/p3-02-atomicity.txt), sections 1 and 7)
- [x] Rollback: error rollback, explicit business rollback, savepoint and statement atomicity ([p3-02-atomicity.txt](outputs/p3-02-atomicity.txt), sections 2–5)
- [x] Isolation: non-repeatable read, phantom, READ UNCOMMITTED and write skew under three isolation levels ([p3-03-isolation.txt](outputs/p3-03-isolation.txt))
- [x] A concurrency issue and a control mechanism: lost update against `FOR UPDATE` and REPEATABLE READ, a double-booking race against an exclusion constraint, deadlock against ordered locking, and a hot row against a sequence ([p3-04-locking.txt](outputs/p3-04-locking.txt))
- [x] Screenshots and output evidence: the output files above, and the hand-run scenarios in the [replay guide](replay-guide.md)

The meaning of each result is set out in [concurrency.md](concurrency.md), with a table of every scenario against the isolation level or mechanism, what was expected and what was observed, and the ACID property it shows.

## How I implemented it

Each demonstration in [demos/](demos/) opens two or more real database sessions, one connection each, labelled A and B. The script drives them step by step, so the interleaving is the same on every run, and every statement is logged with the milliseconds since the start, the session's label and the values it used. When a session is expected to wait, the script confirms it from a separate monitoring session (`sys`), which reads `pg_stat_activity` and `pg_blocking_pids()` and logs who is waiting for whom, for example `B (pid 168) waits on Lock:transactionid, blocked by A (pid 167)`. Only then does it let the other session continue. The monitoring session runs outside any transaction, so it never looks at a frozen snapshot.

- [atomicity.py](demos/atomicity.py) commits, rolls back, uses a savepoint, shows statement atomicity and an idempotent retry, then kills the PostgreSQL container with SIGKILL while one transaction is committed and another is open. After restarting it, the script reads the recovery lines from the server log written since the kill, and checks which booking survived.
- [isolation.py](demos/isolation.py) repeats the same reads under READ COMMITTED and REPEATABLE READ, tries READ UNCOMMITTED, and runs the on-call sign-off under REPEATABLE READ and SERIALIZABLE.
- [locking.py](demos/locking.py) shows each concurrency problem and then the control that prevents it, including a load test of 200 transfers each way and a throughput test of a shared counter row against a sequence.

Scenarios that need a rule to be missing, such as a stock table without a non-negative check or a booking table without an exclusion constraint, run in a separate `sandbox` schema ([sql/sandbox.sql](sql/sandbox.sql)). The real tables keep every constraint, and each real-table scenario is run against them unchanged. The deadlock load test lowers `deadlock_timeout` to 50 ms for its own sessions only, so that 400 attempts finish in seconds.

## How I tested it

Every demonstration ends with automated checks that print PASS or FAIL, and the script exits non-zero if any check fails. After each one, [run_p3.py](run_p3.py) runs the full Portfolio 1 consistency suite against the database, so no demonstration can leave the data in a state that breaks a rule.

| Demonstration | Checks | Consistency afterwards | Evidence |
|---|---|---|---|
| Atomicity and durability | 16 of 16 passed | 15 of 15 | [p3-02-atomicity.txt](outputs/p3-02-atomicity.txt) |
| Isolation | 9 of 9 passed | 15 of 15 | [p3-03-isolation.txt](outputs/p3-03-isolation.txt) |
| Locking, deadlock and hot row | 20 of 20 passed | 15 of 15 | [p3-04-locking.txt](outputs/p3-04-locking.txt) |

A few results matter most. The crash test showed the write-ahead log replaying on restart, the committed booking kept and the open one gone. Under REPEATABLE READ two doctors both left the on-call rota, while SERIALIZABLE stopped the second with SQLSTATE 40001. Naive lock ordering produced 100 deadlocks in 400 transfers, against none with ordered locking. With eight sessions, a shared counter row kept sessions waiting on its lock in 75.3% of samples.

To reproduce (about three minutes; the PostgreSQL container is killed and restarted once on purpose):

```powershell
docker compose up -d --wait
.venv\Scripts\python portfolio-3-transactions-concurrency\run_p3.py
```

The demonstrations add a few rows to the real tables on each run, such as appointments in 2027, a transfer and two on-call nights. Each run books fresh slots and dates, so it can be repeated.

## Contents

| Path | What it holds |
|---|---|
| [demos/common.py](demos/common.py) | Labelled sessions, timed logging, lock-wait detection and checks |
| [demos/atomicity.py](demos/atomicity.py), [demos/isolation.py](demos/isolation.py), [demos/locking.py](demos/locking.py) | The demonstrations |
| [sql/sandbox.sql](sql/sandbox.sql) | Tables and functions without the real safeguards |
| [run_p3.py](run_p3.py) | Runs every demonstration and the consistency checks, capturing the evidence |
| [concurrency.md](concurrency.md) | Scenario table, what it means for the clinic, two-phase commit, advice for developers |
| [replay-guide.md](replay-guide.md) | Two-terminal scripts for replaying the scenarios by hand |
| [outputs/](outputs/) | Evidence |
