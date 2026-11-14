"""PostgreSQL streaming replication: lag, read-only standbys, stale reads, synchronous-commit cost, CP behaviour, failover."""

import statistics
import threading
import time

import psycopg
from tabulate import tabulate

from common import check, compose, log, pg, section, summary

INSERT = "INSERT INTO appointment_request (request_no, hospital_no, branch) VALUES (%s, %s, %s)"


def next_no(conn):
    return conn.execute("SELECT coalesce(max(request_no), 0) + 1 FROM appointment_request").fetchone()[0]


def visible(node, request_no, timeout=5.0):
    """Seconds until a row appears on a node, or None if it never does within the timeout."""
    with pg(node) as conn:
        t0 = time.perf_counter()
        while time.perf_counter() - t0 < timeout:
            if conn.execute("SELECT 1 FROM appointment_request WHERE request_no = %s", (request_no,)).fetchone():
                return time.perf_counter() - t0
            time.sleep(0.002)
    return None


def wait_streaming(name, timeout=60):
    t0 = time.perf_counter()
    with pg("primary") as conn:
        while time.perf_counter() - t0 < timeout:
            row = conn.execute("SELECT state, sync_state FROM pg_stat_replication WHERE application_name = %s",
                               (name,)).fetchone()
            if row and row[0] == "streaming":
                return row
            time.sleep(0.5)
    raise TimeoutError(f"{name} did not resume streaming")


def topology():
    section("1. Topology and replication of a committed write")
    with pg("primary") as p:
        log("pri", p.execute("SELECT version()").fetchone()[0])
        rows = p.execute("SELECT application_name, client_addr, state, sync_state, sync_priority "
                         "FROM pg_stat_replication ORDER BY application_name").fetchall()
        print(tabulate(rows, headers=["standby", "address", "state", "sync_state", "priority"]))
        no = next_no(p)
        t0 = time.perf_counter()
        p.execute(INSERT, (no, "HN-0000001", "LAG-IKJ"))
        log("pri", f"request {no} committed in {(time.perf_counter() - t0) * 1000:.1f} ms (waits for standby_sync to flush)")
    delays = {node: visible(node, no) for node in ("standby_sync", "standby_async")}
    for node, delay in delays.items():
        log({"standby_sync": "syn", "standby_async": "asy"}[node],
            f"request {no} visible after {delay * 1000:.1f} ms" if delay is not None else "not visible")
    with pg("primary") as p:
        lag = p.execute("SELECT application_name, write_lag, flush_lag, replay_lag FROM pg_stat_replication "
                        "ORDER BY application_name").fetchall()
    print(tabulate(lag, headers=["standby", "write_lag", "flush_lag", "replay_lag"]))
    check("standby_sync is the synchronous standby and standby_async the asynchronous one",
          {r[0]: r[3] for r in rows} == {"standby_async": "async", "standby_sync": "sync"})
    check("the committed write reached both standbys", all(d is not None for d in delays.values()))


def read_only():
    section("2. Standbys are read-only")
    with pg("standby_sync") as s:
        try:
            s.execute(INSERT, (999999999, "HN-0000002", "LAG-IKJ"))
            err = None
        except psycopg.Error as exc:
            err = exc
            log("syn", f"ERROR {exc.sqlstate}: {exc.diag.message_primary}")
    check("a write on a standby is refused (25006 read_only_sql_transaction)", err is not None and err.sqlstate == "25006")


def stale_read():
    section("3. A stale read: replay paused on the asynchronous standby")
    with pg("standby_async") as a, pg("primary") as p:
        a.execute("SELECT pg_wal_replay_pause()")
        log("asy", "pg_wal_replay_pause(): the standby still receives WAL but stops applying it")
        no = next_no(p)
        p.execute(INSERT, (no, "HN-0000012", "LAG-SUR"))
        log("pri", f"a receptionist books request {no} on the primary and the app reads it back from the reporting replica")
        on_async = a.execute("SELECT count(*) FROM appointment_request WHERE request_no = %s", (no,)).fetchone()[0]
        log("asy", f"request {no} on standby_async: {on_async} row(s): the patient's own booking is missing")
        on_sync = visible("standby_sync", no)
        a.execute("SELECT pg_wal_replay_resume()")
        log("asy", "pg_wal_replay_resume()")
    caught_up = visible("standby_async", no)
    check("the asynchronous standby served a stale read (read-your-writes violated)", on_async == 0)
    check("the synchronous standby already had the row", on_sync is not None)
    check("after replay resumed, the asynchronous standby caught up", caught_up is not None)


def commit_latency():
    section("4. What synchronous replication costs: commit latency by synchronous_commit (300 commits, 3 runs each)")
    rows, medians = [], {}
    with pg("primary") as p:
        no = next_no(p)
        for setting in ("off", "local", "on", "remote_apply"):
            p.execute(f"SET synchronous_commit = {setting}")
            runs = []
            for _ in range(3):
                samples = []
                for _ in range(300):
                    t0 = time.perf_counter()
                    p.execute(INSERT, (no, "HN-0000002", "LAG-IKJ"))
                    samples.append((time.perf_counter() - t0) * 1000)
                    no += 1
                runs.append(statistics.median(samples))
            medians[setting] = statistics.median(runs)
            rows.append([setting, f"{medians[setting]:.3f}", f"{min(runs):.3f}–{max(runs):.3f}"])
            log("pri", f"synchronous_commit = {setting}: median commit {medians[setting]:.3f} ms")
        p.execute("RESET synchronous_commit")
    print(tabulate(rows, headers=["synchronous_commit", "median ms per commit", "range of run medians"]))
    check("waiting for the synchronous standby makes commits slower than not waiting for the disk at all",
          medians["on"] > medians["off"] and medians["remote_apply"] > medians["off"],
          f"off {medians['off']:.3f} ms, on {medians['on']:.3f} ms, remote_apply {medians['remote_apply']:.3f} ms")


def cp_behaviour():
    section("5. CP behaviour: the synchronous standby is stopped, so commits wait")
    compose("pg-replication", "stop", "pg_standby_sync")
    log("sys", "docker compose stop pg_standby_sync")
    notices, outcome = [], {}
    writer = pg("primary")
    writer.add_notice_handler(lambda d: notices.append(f"{d.severity}: {d.message_primary}" +
                                                       (f" DETAIL: {d.message_detail}" if d.message_detail else "")))
    no = next_no(writer)

    def book():
        t0 = time.perf_counter()
        try:
            writer.execute(INSERT, (no, "HN-0000001", "LAG-IKJ"))
            outcome["error"] = None
        except psycopg.Error as exc:
            outcome["error"] = exc
        outcome["seconds"] = time.perf_counter() - t0

    thread = threading.Thread(target=book)
    thread.start()
    with pg("primary") as mon:
        waited = None
        for _ in range(100):
            row = mon.execute("SELECT pid, wait_event FROM pg_stat_activity WHERE application_name = 'p5-primary' "
                              "AND wait_event = 'SyncRep'").fetchone()
            if row:
                waited = row
                break
            time.sleep(0.05)
        log("sys", f"the commit of request {no} is waiting: pid {waited[0]}, wait_event {waited[1]}" if waited
            else "the commit did not wait")
        time.sleep(2)
        log("sys", "after 2 s the commit is still waiting; the operator cancels it with pg_cancel_backend")
        mon.execute("SELECT pg_cancel_backend(%s)", (waited[0],))
    thread.join()
    for notice in notices:
        log("pri", notice)
    with pg("primary") as p:
        local = p.execute("SELECT count(*) FROM appointment_request WHERE request_no = %s", (no,)).fetchone()[0]
    writer.close()
    check("with the synchronous standby down, the commit waited (wait_event SyncRep)", waited is not None)
    check("cancelling the wait warns that the transaction committed locally but may not be replicated",
          any("committed locally" in n for n in notices))
    check("the row is on the primary although the client never received a clean acknowledgement", local == 1)
    compose("pg-replication", "start", "pg_standby_sync")
    state = wait_streaming("standby_sync")
    log("sys", f"docker compose start pg_standby_sync: streaming again ({state[1]})")
    check("once the standby is back it receives the row", visible("standby_sync", no, timeout=10) is not None)


def failover():
    section("6. Failover: the primary is killed while a client keeps writing; standby_sync is promoted")
    with pg("primary") as p:
        before_tli = p.execute("SELECT substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8)").fetchone()[0]
        start_no = next_no(p)
    acked, stop = [], threading.Event()
    errors = []

    def writer():
        no, conn, node = start_no, None, "primary"
        while not stop.is_set():
            try:
                if conn is None:
                    conn = pg(node, timeout=1, statement_timeout_ms=5000)
                conn.execute(INSERT, (no, "HN-0000002", "LAG-IKJ"))
                acked.append((no, time.perf_counter(), node))
            except psycopg.Error as exc:
                errors.append((time.perf_counter(), node, type(exc).__name__))
                try:
                    if conn is not None:
                        conn.close()
                except Exception:
                    pass
                conn = None
                node = "standby_sync" if node == "primary" else "primary"
                time.sleep(0.05)
            no += 1
        if conn is not None:
            conn.close()

    thread = threading.Thread(target=writer)
    thread.start()
    time.sleep(2)
    killed = time.perf_counter()
    compose("pg-replication", "kill", "pg_primary")
    log("sys", f"docker compose kill pg_primary after {len(acked)} acknowledged writes")
    time.sleep(1)
    with pg("standby_sync") as s:
        log("syn", "SELECT pg_promote(wait => true)")
        promoted = s.execute("SELECT pg_promote(wait => true, wait_seconds => 30)").fetchone()[0]
        promoted_at = time.perf_counter()
        log("syn", f"promoted: {promoted}; pg_is_in_recovery() = {s.execute('SELECT pg_is_in_recovery()').fetchone()[0]}")
    time.sleep(2)
    stop.set()
    thread.join(timeout=30)
    check("the writer finished instead of hanging on a dead connection", not thread.is_alive())

    times = [t for _, t, _ in acked]
    gaps = [(b - a, a) for a, b in zip(times, times[1:])]
    outage, gap_start = max(gaps)
    before = [n for n, t, node in acked if node == "primary"]
    after = [n for n, t, node in acked if node == "standby_sync"]
    log("sys", f"{len(before)} writes acknowledged by the old primary, {len(after)} by the new one; "
               f"{len(errors)} failed attempts while no primary accepted writes")
    log("sys", f"longest gap between two acknowledged writes: {outage:.2f} s "
               f"(kill to promotion {promoted_at - killed:.2f} s, including the 1 s taken to decide)")
    with pg("standby_sync") as s:
        present = {r[0] for r in s.execute("SELECT request_no FROM appointment_request WHERE request_no >= %s",
                                           (start_no,)).fetchall()}
        after_tli = s.execute("SELECT substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8)").fetchone()[0]
    missing = [n for n, _, _ in acked if n not in present]
    log("syn", f"timeline before failover {before_tli}, after {after_tli}")
    check("the client wrote through the failover: acknowledged writes on both sides of it", before and after)
    check("no write acknowledged under synchronous commit was lost", not missing, f"{len(acked)} acknowledged, "
          f"{len(missing)} missing")
    check("the promoted standby started a new timeline", int(after_tli, 16) == int(before_tli, 16) + 1,
          f"{before_tli} -> {after_tli}")
    check("the outage is measured from acknowledged writes and is finite", 0 < outage < 30, f"{outage:.2f} s")
    rows = compose("pg-replication", "ps", "--all", "--format", "table {{.Service}}\t{{.State}}\t{{.Status}}").stdout
    print(rows)


def main():
    topology()
    read_only()
    stale_read()
    commit_latency()
    cp_behaviour()
    failover()
    summary()


if __name__ == "__main__":
    main()
