"""Concurrency problems and the controls that prevent them: lost update, row locks, exclusion, deadlock, hot row."""

import statistics
import threading
import time
from datetime import date

import psycopg
from tabulate import tabulate

from common import (attempt, check, free_slots, ids, in_thread, log, run, section, session, summary, value,
                    wait_for_lock)

STOCK = "SELECT quantity FROM sandbox.stock WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002'"
SET_STOCK = "UPDATE sandbox.stock SET quantity = %s WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002'"
BOOK = "SELECT book_appointment(%s, %s, %s, %s, %s, 30, %s)"
FAST_DEADLOCKS = ("SET deadlock_timeout = '50ms'",)


def reset_stock(sysc, quantity=100):
    sysc.execute("UPDATE sandbox.stock SET quantity = %s", (quantity,))
    log("sys", f"sandbox paracetamol stock reset to {quantity} at Ikeja and Lekki")


def lost_update(sysc):
    section("1. Lost update: read, compute in the application, write back (READ COMMITTED)")
    reset_stock(sysc)
    a, b = session("A"), session("B")
    run(a, "A", "BEGIN")
    qa = run(a, "A", STOCK)[0][0]
    run(b, "B", "BEGIN")
    qb = run(b, "B", STOCK)[0][0]
    log("A", f"dispensing 10: the application computes {qa} - 10 = {qa - 10}")
    run(a, "A", SET_STOCK, (qa - 10,))
    run(a, "A", "COMMIT")
    log("B", f"dispensing 5: the application computes {qb} - 5 = {qb - 5}")
    run(b, "B", SET_STOCK, (qb - 5,))
    run(b, "B", "COMMIT")
    final = value(sysc, STOCK)
    check("lost update: dispensing 10 and 5 from 100 leaves 95 instead of 85", final == 95, f"final {final}")
    a.close(), b.close()


def for_update(sysc):
    section("2. SELECT ... FOR UPDATE: the second session waits and nothing is lost")
    reset_stock(sysc)
    a, b = session("A"), session("B")
    seen = {}

    def session_b():
        run(b, "B", "BEGIN")
        seen["b"] = run(b, "B", STOCK + " FOR UPDATE")[0][0]
        run(b, "B", SET_STOCK, (seen["b"] - 5,))
        run(b, "B", "COMMIT")

    run(a, "A", "BEGIN")
    qa = run(a, "A", STOCK + " FOR UPDATE")[0][0]
    t = in_thread(session_b)
    waited = wait_for_lock(sysc, "B")
    run(a, "A", SET_STOCK, (qa - 10,))
    run(a, "A", "COMMIT")
    t.join()
    final = value(sysc, STOCK)
    check("B waited for A's row lock", waited is not None)
    check("B read the value A committed", seen["b"] == 90, f"B read {seen['b']}")
    check("both dispenses count: 100 - 10 - 5 = 85", final == 85, f"final {final}")
    a.close(), b.close()


def repeatable_read(sysc):
    section("3. REPEATABLE READ: the second writer gets a serialization failure and retries")
    reset_stock(sysc)
    a, b = session("A"), session("B")
    run(a, "A", "BEGIN ISOLATION LEVEL REPEATABLE READ")
    qa = run(a, "A", STOCK)[0][0]
    run(b, "B", "BEGIN ISOLATION LEVEL REPEATABLE READ")
    qb = run(b, "B", STOCK)[0][0]
    run(a, "A", SET_STOCK, (qa - 10,))
    run(a, "A", "COMMIT")
    _, err = attempt(b, "B", SET_STOCK, (qb - 5,))
    run(b, "B", "ROLLBACK")
    log("B", "retrying the whole transaction")
    run(b, "B", "BEGIN ISOLATION LEVEL REPEATABLE READ")
    qb = run(b, "B", STOCK)[0][0]
    run(b, "B", SET_STOCK, (qb - 5,))
    run(b, "B", "COMMIT")
    final = value(sysc, STOCK)
    check("B's update on a row changed since its snapshot fails with 40001", err is not None and err.sqlstate == "40001")
    check("after the retry both dispenses count", final == 85, f"final {final}")
    a.close(), b.close()


def double_booking(sysc, k):
    section("4. Double booking: a check-then-insert race, then the exclusion constraint")
    sysc.execute("DELETE FROM sandbox.booking")
    starts = "2027-01-04 08:00+01"
    count = "SELECT count(*) FROM sandbox.booking WHERE clinician_no = 'ST-00001' AND starts = %s"
    insert = "INSERT INTO sandbox.booking (clinician_no, starts, hospital_no) VALUES ('ST-00001', %s, %s)"
    a, b = session("A"), session("B")
    run(a, "A", "BEGIN")
    run(a, "A", count, (starts,))
    run(b, "B", "BEGIN")
    run(b, "B", count, (starts,))
    log("B", "both receptionists see the slot free")
    run(a, "A", insert, (starts, "HN-0000002"))
    run(a, "A", "COMMIT")
    run(b, "B", insert, (starts, "HN-0000012"))
    run(b, "B", "COMMIT")
    booked = value(sysc, count, (starts,))
    check("sandbox, no constraint: both bookings got in", booked == 2, f"{booked} bookings for one slot")

    log("---", "the real appointment table with appointment_clinician_slot_ex")
    slot = free_slots(sysc, k["doctor_1"], [k["patient_a"], k["patient_b"]])[0]
    a, b = session("A"), session("B")
    outcome = {}

    def session_b():
        run(b, "B", "BEGIN")
        _, outcome["err"] = attempt(b, "B", BOOK, (k["patient_b"], k["doctor_1"], k["gp"], k["ikeja"], slot, k["reception"]))
        run(b, "B", "ROLLBACK")

    run(a, "A", "BEGIN")
    run(a, "A", BOOK, (k["patient_a"], k["doctor_1"], k["gp"], k["ikeja"], slot, k["reception"]))
    t = in_thread(session_b)
    waited = wait_for_lock(sysc, "B")
    run(a, "A", "COMMIT")
    t.join()
    err = outcome["err"]
    active = value(sysc, "SELECT count(*) FROM appointment WHERE clinician_id = %s AND lower(slot) = %s "
                         "AND appointment_status_code <> 'CANCELLED'", (k["doctor_1"], slot))
    check("B's booking waited for A's undecided booking of the same slot", waited is not None)
    check("once A committed, B was refused by the exclusion constraint",
          err is not None and err.diag.constraint_name == "appointment_clinician_slot_ex")
    check("the slot holds exactly one appointment", active == 1)
    a.close(), b.close()


def deadlock(sysc, k):
    section("5. Deadlock: opposite transfers lock the same two rows in opposite order")
    reset_stock(sysc)
    a, b = session("A"), session("B")
    errors = {}

    def second_update(conn, who, facility):
        _, err = attempt(conn, who, "UPDATE sandbox.stock SET quantity = quantity + 1 "
                                    f"WHERE facility_code = '{facility}' AND drug_code = 'DRG-0002'")
        if err is not None and err.diag.message_detail:
            for line in err.diag.message_detail.splitlines():
                log(who, f"  DETAIL {line}")
        errors[who] = err

    run(a, "A", "BEGIN")
    run(a, "A", "UPDATE sandbox.stock SET quantity = quantity - 1 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002'")
    run(b, "B", "BEGIN")
    run(b, "B", "UPDATE sandbox.stock SET quantity = quantity - 1 WHERE facility_code = 'LAG-LEK' AND drug_code = 'DRG-0002'")
    ta = in_thread(second_update, a, "A", "LAG-LEK")
    wait_for_lock(sysc, "A")
    tb = in_thread(second_update, b, "B", "LAG-IKJ")
    ta.join()
    tb.join()
    for who, conn in (("A", a), ("B", b)):
        run(conn, who, "ROLLBACK" if errors[who] else "COMMIT")
    victims = [w for w, e in errors.items() if e is not None and e.sqlstate == "40P01"]
    check("PostgreSQL detected the deadlock and aborted exactly one transaction", len(victims) == 1,
          f"victim: {', '.join(victims) or 'none'}")
    check("the other transaction completed", sum(e is None for e in errors.values()) == 1)
    a.close(), b.close()

    log("---", "the same transfers, both locking the two rows in facility order first")
    reset_stock(sysc)
    a, b = session("A"), session("B")
    lock_both = ("SELECT facility_code FROM sandbox.stock WHERE drug_code = 'DRG-0002' "
                 "AND facility_code IN ('LAG-IKJ', 'LAG-LEK') ORDER BY facility_code FOR UPDATE")
    outcome = {}

    def session_b():
        run(b, "B", "BEGIN")
        run(b, "B", lock_both)
        run(b, "B", "UPDATE sandbox.stock SET quantity = quantity - 1 WHERE facility_code = 'LAG-LEK' AND drug_code = 'DRG-0002'")
        _, outcome["err"] = attempt(b, "B", "UPDATE sandbox.stock SET quantity = quantity + 1 "
                                            "WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002'")
        run(b, "B", "COMMIT")

    run(a, "A", "BEGIN")
    run(a, "A", lock_both)
    t = in_thread(session_b)
    waited = wait_for_lock(sysc, "B")
    run(a, "A", "UPDATE sandbox.stock SET quantity = quantity - 1 WHERE facility_code = 'LAG-IKJ' AND drug_code = 'DRG-0002'")
    run(a, "A", "UPDATE sandbox.stock SET quantity = quantity + 1 WHERE facility_code = 'LAG-LEK' AND drug_code = 'DRG-0002'")
    run(a, "A", "COMMIT")
    t.join()
    check("with ordered locking B simply waits", waited is not None)
    check("no deadlock: both transfers commit", outcome["err"] is None)
    a.close(), b.close()

    log("---", "the real transfer_stock routine, which locks both stock rows in facility order")
    a, b = session("A"), session("B")
    outcome = {}

    def real_b():
        run(b, "B", "BEGIN")
        _, outcome["err"] = attempt(b, "B", "SELECT transfer_stock(%s, %s, %s, 1, %s)",
                                    (k["paracetamol"], k["lekki"], k["ikeja"], k["pharmacist"]))
        run(b, "B", "COMMIT" if outcome["err"] is None else "ROLLBACK")

    run(a, "A", "BEGIN")
    run(a, "A", "SELECT transfer_stock(%s, %s, %s, 1, %s)", (k["paracetamol"], k["ikeja"], k["lekki"], k["pharmacist"]))
    t = in_thread(real_b)
    waited = wait_for_lock(sysc, "B")
    run(a, "A", "COMMIT")
    t.join()
    check("transfer_stock in opposite directions: B waits, then both commit",
          waited is not None and outcome["err"] is None)
    a.close(), b.close()


def deadlocks_under_load(sysc):
    section("6. Deadlocks under load: 200 transfers each way at once (deadlock_timeout lowered to 50 ms)")
    rows, results = [], {}
    for strategy in ("transfer_naive", "transfer_ordered"):
        sysc.execute("UPDATE sandbox.stock SET quantity = 10000")
        barrier = threading.Barrier(2)
        stats = {}

        def worker(label, origin, destination):
            conn = session(label, FAST_DEADLOCKS)
            committed = deadlocks = 0
            barrier.wait()
            for _ in range(200):
                try:
                    conn.execute("BEGIN")
                    conn.execute(f"SELECT sandbox.{strategy}(%s, %s, 'DRG-0002', 1, 0.002)", (origin, destination))
                    conn.execute("COMMIT")
                    committed += 1
                except psycopg.errors.DeadlockDetected:
                    conn.execute("ROLLBACK")
                    deadlocks += 1
            stats[label] = (committed, deadlocks)
            conn.close()

        t0 = time.perf_counter()
        threads = [in_thread(worker, "L1", "LAG-IKJ", "LAG-LEK"), in_thread(worker, "L2", "LAG-LEK", "LAG-IKJ")]
        for t in threads:
            t.join()
        elapsed = time.perf_counter() - t0
        total = value(sysc, "SELECT sum(quantity) FROM sandbox.stock")
        committed = sum(s[0] for s in stats.values())
        deadlocks = sum(s[1] for s in stats.values())
        results[strategy] = (deadlocks, total)
        rows.append([strategy, 400, committed, deadlocks, f"{elapsed:.2f}", total])
        log("sys", f"{strategy}: {committed} committed, {deadlocks} deadlocks, {elapsed:.2f} s, total stock {total}")
    print(tabulate(rows, headers=["strategy", "attempts", "committed", "deadlocks", "seconds", "total stock after"]))
    check("naive locking order deadlocks under load", results["transfer_naive"][0] > 0,
          f"{results['transfer_naive'][0]} deadlocks")
    check("ordered locking never deadlocks", results["transfer_ordered"][0] == 0)
    check("no unit of stock was created or lost", all(r[1] == 20000 for r in results.values()))


def hot_row(sysc):
    section("7. A hot row: one queue-number counter row against a sequence (3 runs of 3 s per setting)")
    day = date(2027, 1, 4)
    duration, runs = 3.0, 3
    table, summary_rows, medians = [], [], {}

    def take_ticket(conn, strategy):
        if strategy == "counter row":
            conn.execute("BEGIN")
            number = conn.execute("UPDATE sandbox.queue_counter SET last_no = last_no + 1 "
                                  "WHERE facility_code = 'LAG-IKJ' AND queue_day = %s RETURNING last_no", (day,)).fetchone()[0]
            conn.execute("INSERT INTO sandbox.queue_ticket (facility_code, queue_day, queue_no) VALUES ('LAG-IKJ', %s, %s)",
                         (day, number))
            conn.execute("COMMIT")
        else:
            conn.execute("INSERT INTO sandbox.queue_ticket (facility_code, queue_day, queue_no) "
                         "VALUES ('LAG-IKJ', %s, nextval('sandbox.queue_seq'))", (day,))

    for strategy in ("counter row", "sequence"):
        for sessions in (1, 8):
            throughput, waiting = [], []
            for n in range(runs):
                sysc.execute("TRUNCATE sandbox.queue_ticket")
                sysc.execute("DELETE FROM sandbox.queue_counter")
                sysc.execute("INSERT INTO sandbox.queue_counter VALUES ('LAG-IKJ', %s, 0)", (day,))
                sysc.execute("VACUUM (ANALYZE) sandbox.queue_counter, sandbox.queue_ticket")
                conns = [session(f"hot-{i}") for i in range(sessions)]
                monitor = session("mon")
                stop, barrier = threading.Event(), threading.Barrier(sessions + 2)
                counts, samples = [0] * sessions, [0, 0]

                def worker(i):
                    barrier.wait()
                    while not stop.is_set():
                        take_ticket(conns[i], strategy)
                        counts[i] += 1

                def sampler():
                    barrier.wait()
                    while not stop.is_set():
                        w, total = monitor.execute(
                            "SELECT count(*) FILTER (WHERE wait_event_type = 'Lock'), count(*) "
                            "FROM pg_stat_activity WHERE application_name LIKE 'p3-hot-%%'").fetchone()
                        samples[0] += w
                        samples[1] += total
                        time.sleep(0.01)

                threads = [in_thread(worker, i) for i in range(sessions)] + [in_thread(sampler)]
                barrier.wait()
                t0 = time.perf_counter()
                time.sleep(duration)
                stop.set()
                for t in threads:
                    t.join()
                elapsed = time.perf_counter() - t0
                tickets = sum(counts)
                gapless = value(sysc, "SELECT max(queue_no) = count(*) FROM sandbox.queue_ticket") \
                    if strategy == "counter row" else None
                tps = tickets / elapsed
                wait_pct = 100.0 * samples[0] / samples[1] if samples[1] else 0.0
                throughput.append(tps)
                waiting.append(wait_pct)
                table.append([strategy, sessions, n + 1, tickets, f"{tps:.0f}", f"{wait_pct:.1f}",
                              "" if gapless is None else ("yes" if gapless else "NO")])
                for c in conns + [monitor]:
                    c.close()
            medians[(strategy, sessions)] = (statistics.median(throughput), statistics.median(waiting))
            summary_rows.append([strategy, sessions, f"{statistics.median(throughput):.0f}",
                                 f"{min(throughput):.0f}–{max(throughput):.0f}",
                                 f"{statistics.median(waiting):.1f}", f"{min(waiting):.1f}–{max(waiting):.1f}"])
            log("sys", f"{strategy}, {sessions} session(s): median {statistics.median(throughput):.0f} tickets/s, "
                       f"{statistics.median(waiting):.1f}% of session samples waiting on a lock")
    print(tabulate(table, headers=["strategy", "sessions", "run", "tickets", "tickets/s", "% samples waiting on a lock",
                                   "numbers gapless"]))
    print()
    print(tabulate(summary_rows, headers=["strategy", "sessions", "median tickets/s", "range", "median % waiting", "range"]))
    check("the counter row hands out gapless numbers", all(r[6] in ("yes", "") for r in table))
    check("with 8 sessions the counter row makes sessions wait on its lock, the sequence does not",
          medians[("counter row", 8)][1] > 10 * max(medians[("sequence", 8)][1], 0.1),
          f"{medians[('counter row', 8)][1]:.1f}% against {medians[('sequence', 8)][1]:.1f}%")


def main():
    sysc = session("sys")
    k = ids(sysc)
    lost_update(sysc)
    for_update(sysc)
    repeatable_read(sysc)
    double_booking(sysc, k)
    deadlock(sysc, k)
    deadlocks_under_load(sysc)
    hot_row(sysc)
    summary()


if __name__ == "__main__":
    main()
