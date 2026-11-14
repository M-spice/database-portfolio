# Replaying the concurrency scenarios by hand

The automated demonstrations in [demos/](demos/) drive the sessions from Python. These are the same scenarios as short scripts for two `psql` terminals, A and B, so each step can be watched as it happens. They use the `sandbox` schema, so they never touch the clinic's real data and can be repeated as often as needed. Run the steps in the order given (A1, B1, A2, …).

Open each terminal in PowerShell at the repository root:

```powershell
docker compose exec postgres psql -U postgres -d itoju
```

then, in each terminal:

```sql
SET search_path = sandbox;
\pset footer off
```

A third terminal shows who is waiting for whom at any moment:

```sql
\x on
SELECT pid, application_name, state, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by, left(query, 60) AS query
  FROM pg_stat_activity WHERE datname = 'itoju' AND pid <> pg_backend_pid() AND state <> 'idle';
```

When a statement waits for a lock, leave it alone: the next step in the other terminal releases it. Pressing Ctrl+C would cancel the waiting statement and spoil the demonstration.

## 1. Lost update

Reset, in either terminal: `UPDATE stock SET quantity = 100;`

| Step | Terminal | Statement | What happens |
|---|---|---|---|
| A1 | A | `BEGIN;` | |
| A2 | A | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | 100 |
| B1 | B | `BEGIN;` | |
| B2 | B | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | 100 |
| A3 | A | `UPDATE stock SET quantity = 90 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | A dispenses 10 and writes back 100 − 10 |
| A4 | A | `COMMIT;` | |
| B3 | B | `UPDATE stock SET quantity = 95 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | B dispenses 5 and writes back 100 − 5 |
| B4 | B | `COMMIT;` | |
| B5 | B | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | **95**: A's dispense of 10 is lost |

## 2. SELECT … FOR UPDATE: the second session waits

Reset: `UPDATE stock SET quantity = 100;`

| Step | Terminal | Statement | What happens |
|---|---|---|---|
| A1 | A | `BEGIN;` | |
| A2 | A | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002' FOR UPDATE;` | 100, and the row is now locked |
| B1 | B | `BEGIN;` | |
| B2 | B | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002' FOR UPDATE;` | **B waits**. The third terminal shows `Lock` / `transactionid`, blocked by A's pid |
| A3 | A | `UPDATE stock SET quantity = quantity - 10 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | |
| A4 | A | `COMMIT;` | B's statement returns at once with **90** |
| B3 | B | `UPDATE stock SET quantity = quantity - 5 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | |
| B4 | B | `COMMIT;` | |
| B5 | B | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | **85**: nothing lost |

## 3. Deadlock

Reset: `UPDATE stock SET quantity = 100;`

| Step | Terminal | Statement | What happens |
|---|---|---|---|
| A1 | A | `BEGIN;` | |
| A2 | A | `UPDATE stock SET quantity = quantity - 1 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | A locks Ikeja's row |
| B1 | B | `BEGIN;` | |
| B2 | B | `UPDATE stock SET quantity = quantity - 1 WHERE facility_code = 'LAG-LEK' AND drug_code = 'DRG-0002';` | B locks Lekki's row |
| A3 | A | `UPDATE stock SET quantity = quantity + 1 WHERE facility_code = 'LAG-LEK' AND drug_code = 'DRG-0002';` | **A waits** for B |
| B3 | B | `UPDATE stock SET quantity = quantity + 1 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | B waits for A: a cycle. After `deadlock_timeout` (1 s) one of them gets **ERROR: deadlock detected** with a DETAIL naming both processes, and the other continues |
| A4, B4 | both | `ROLLBACK;` in the session that failed, `COMMIT;` in the other | |

To see the cure, repeat with both terminals first running `SELECT facility_code FROM stock WHERE drug_code = 'DRG-0002' ORDER BY facility_code FOR UPDATE;` straight after `BEGIN`. The second terminal then simply waits at that statement, and no deadlock is possible because both lock the rows in the same order.

## 4. Serialization failure under REPEATABLE READ

Reset: `UPDATE stock SET quantity = 100;`

| Step | Terminal | Statement | What happens |
|---|---|---|---|
| A1 | A | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | |
| A2 | A | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | 100 |
| B1 | B | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | |
| B2 | B | `SELECT quantity FROM stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | 100 |
| A3 | A | `UPDATE stock SET quantity = 90 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | |
| A4 | A | `COMMIT;` | |
| B3 | B | `UPDATE stock SET quantity = 95 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002';` | **ERROR: could not serialize access due to concurrent update** (SQLSTATE 40001) |
| B4 | B | `ROLLBACK;` | The application retries the whole transaction and now reads 90 |
