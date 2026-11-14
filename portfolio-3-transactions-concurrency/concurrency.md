# Transactions and concurrency at Itoju Clinics

Twelve branches share one database. Receptionists book the same clinicians, pharmacists draw on the same stock, and two doctors can try to leave the same on-call rota at the same moment. I ran each of the situations below with real concurrent sessions against PostgreSQL 16 and recorded what happened ([outputs/](outputs/)). In the table, *expected* is what the theory predicts and *observed* is what the evidence shows.

| # | Scenario | Isolation or mechanism | Expected | Observed | ACID property |
|---|---|---|---|---|---|
| 1 | A receptionist books an appointment | One transaction, then COMMIT | Invisible to others until COMMIT; then the booking and its status history appear together | 0 rows visible before COMMIT; afterwards the appointment and its BOOKED history row | Atomicity, durability |
| 2 | A dispense of 1,000 inhalers, more than the shelf holds | Error, then ROLLBACK | Nothing changes, including the prescription written earlier in the transaction | Refused by `stock_on_hand_quantity_ck`; prescriptions, movements and stock identical before and after | Atomicity, consistency |
| 3 | Billing abandons a half-written invoice | Explicit ROLLBACK | Invoice and line gone | Gone; the invoice number is not reused, because sequences are not transactional | Atomicity |
| 4 | Booking plus an optional SMS-reminder consent that fails | SAVEPOINT and ROLLBACK TO SAVEPOINT | The booking commits without the failed step | Consent refused by `consent_patient_purpose_open_uk`; booking committed | Atomicity (partial rollback) |
| 5 | Three phone numbers in one INSERT, the third invalid | Statement atomicity | None of the three kept | Refused by `patient_phone_no_ck`; 1 phone row before, 1 after | Atomicity |
| 6 | The booking app retries a request after a timeout | Unique `request_key` with `ON CONFLICT DO NOTHING` | The original appointment returned, no duplicate | Same appointment number both times; one row for the key | Consistency |
| 7 | The server is killed with SIGKILL mid-work | Write-ahead log | Committed booking survives; open one disappears | Log shows `redo starts`, `redo done`, `ready to accept connections`; committed booking present, open one absent | Durability |
| 8 | A pharmacist re-reads a stock level while a delivery lands | READ COMMITTED against REPEATABLE READ | READ COMMITTED sees the change (non-repeatable read); REPEATABLE READ does not | 1,845 then 1,855 under READ COMMITTED; 1,855 then 1,855 under REPEATABLE READ | Isolation |
| 9 | A clinician's day is counted while a booking arrives | READ COMMITTED against REPEATABLE READ | A phantom row under READ COMMITTED only | 1 then 2 under READ COMMITTED; 2 then 2 under REPEATABLE READ | Isolation |
| 10 | Reading during someone else's uncommitted delivery | READ UNCOMMITTED | PostgreSQL runs it as READ COMMITTED, so no dirty read | Saw the committed 1,865, not the uncommitted extra 500 | Isolation |
| 11 | Two doctors sign off the same night's on-call rota | REPEATABLE READ against SERIALIZABLE | Write skew under REPEATABLE READ; one serialization failure under SERIALIZABLE | REPEATABLE READ: both committed, nobody on call. SERIALIZABLE: SQLSTATE 40001, and on retry the rule refused (`on_call_minimum_fn`); one doctor still on call | Isolation, consistency |
| 12 | Two dispenses read, compute and write back | READ COMMITTED, no lock | Lost update | 100 − 10 − 5 left 95, not 85 | Isolation (anomaly) |
| 13 | The same with `SELECT … FOR UPDATE` | Row lock | Second session waits, nothing lost | B waited (`Lock:transactionid`, blocked by A) and read 90; final 85 | Isolation by locking |
| 14 | The same under REPEATABLE READ | First updater wins | Second writer fails and retries | 40001 "could not serialize access due to concurrent update"; after retry, 85 | Isolation |
| 15 | Two receptionists book the same clinician's slot | Check-then-insert (sandbox) against the exclusion constraint | The race lets both in; the constraint lets one in | Sandbox: 2 bookings for one slot. Real table: B waited for A, then was refused by `appointment_clinician_slot_ex`; one appointment | Consistency, isolation |
| 16 | Stock transferred Ikeja→Lekki and Lekki→Ikeja at once | Opposite lock order | Deadlock; one transaction aborted | `deadlock detected` (40P01), with A as victim; B committed | Isolation hazard |
| 17 | The same, locking both rows in facility order | Ordered locking | Waiting, never deadlock | B waited, both committed; so did the real `transfer_stock` | Isolation |
| 18 | 200 transfers each way at once | Naive against ordered locking | Deadlocks only with naive order | Naive: 100 deadlocks in 400 attempts, 7.05 s. Ordered: 0 deadlocks, 2.04 s. Total stock 20,000 after both | Consistency |
| 19 | A daily queue-number counter shared by all front desks | One counter row against a sequence | The counter row serialises sessions | 8 sessions on the counter row: 75.3% of session samples waiting on its lock, a median of 218 tickets/s against 149 for one session. A sequence: 1,314 tickets/s against 436, with no waits | Isolation cost |

## What the results mean for Itoju

The double-booking rule sits in the right place. A check followed by an insert, which is how most booking screens are written, let two patients into one slot as soon as two receptionists clicked together (15). The exclusion constraint cannot be raced: the second booking waited for the first transaction to decide, and was refused the moment it committed. No isolation level is needed for that, because the constraint is enforced inside the index.

Stock needs locks or a stricter isolation level, not hope. A read-compute-write dispense lost 10 units of paracetamol between two pharmacists (12). `FOR UPDATE` turned the race into a short wait (13), and REPEATABLE READ turned it into an error the application must retry (14). The real routines avoid the problem by updating with `quantity = quantity − n` inside the database and by locking both rows of a transfer in facility order, which is why the deadlocks of (16) and (18) cannot happen to them.

The on-call rule is the clinic's one rule about a set of rows rather than a row, and it is the one that REPEATABLE READ cannot protect (11). Both doctors saw the other on call in their own snapshot, both signed off, and the night was left uncovered. Only SERIALIZABLE noticed that the two transactions could not have run one after the other. Any rule of the form "at least one" or "no more than n" across rows needs SERIALIZABLE, an explicit lock on something both transactions touch, or a constraint that can express it.

Durability is the write-ahead log's job, and it did it (7): after a kill with no shutdown, the server replayed its log in a fraction of a second, kept the booking whose COMMIT had returned and discarded the one whose COMMIT never came. A patient told "you are booked" stays booked.

The counter row (19) is a warning about convenient designs. One row that every front desk updates makes every booking queue behind the last one: with eight sessions, three-quarters of the samples found a session waiting on that row's lock, and throughput barely rose above a single session's. A sequence scales because it hands out numbers outside the transaction, at the price of gaps when a transaction rolls back (3). If the clinic needs gapless queue numbers, it should keep one counter row per branch per day, so that only one branch's desks compete for it, and keep the transaction that holds the lock as short as possible. Timings on this laptop vary by tens of per cent between runs, so I rely on the lock-wait share and the absolute throughput rather than on any ratio built from a single noisy measurement.

## From one database to several: two-phase commit

Every transaction above lived in one PostgreSQL server, so one write-ahead log decided whether it committed. If Ikeja and Lekki ran separate databases, a stock transfer would need both to commit or neither. Two-phase commit does that: a coordinator asks each database to `PREPARE TRANSACTION`, which makes the work durable and holds its locks without committing; only when every participant has prepared does it issue `COMMIT PREPARED` everywhere. The cost is the course's CAP trade-off in practice. A participant that has prepared cannot decide on its own, so if the coordinator fails at that moment the locks stay held and the stock rows stay blocked until it returns. That is why the distributed design in [Portfolio 5](../portfolio-5-distributed-cloud/README.md) keeps each transfer inside one primary and uses asynchronous replication only for reporting.

## What I would tell a developer joining the team

1. Let the database enforce rules. A check in application code is a race; a constraint is not.
2. Change quantities with `SET quantity = quantity − n`, or lock the row with `FOR UPDATE` before reading it. Never write back a value computed from an earlier read.
3. When a transaction locks several rows, lock them in one agreed order.
4. Use SERIALIZABLE for rules about sets of rows, and write every transaction so it can be retried after SQLSTATE 40001 or 40P01.
5. Keep transactions short and never wait for a user while holding a lock.
6. Give every request that changes data an idempotency key, so a retry cannot do the work twice.
