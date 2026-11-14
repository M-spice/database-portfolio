"""Isolation levels: non-repeatable read, phantom, READ UNCOMMITTED, and write skew on the on-call rule."""

from common import attempt, check, ids, log, run, section, session, summary, value

STOCK = "SELECT quantity FROM stock_on_hand WHERE facility_id = %s AND drug_id = %s"
DAY_COUNT = ("SELECT count(*) FROM appointment WHERE clinician_id = %s AND appointment_status_code <> 'CANCELLED' "
             "AND slot && tstzrange(%s::date::timestamp AT TIME ZONE 'Africa/Lagos', "
             "(%s::date + 1)::timestamp AT TIME ZONE 'Africa/Lagos')")


def free_day(conn, clinician_id, patient_ids):
    return value(conn, """
        SELECT d::date FROM generate_series(DATE '2027-01-04', DATE '2028-01-04', interval '1 day') d
         WHERE extract(isodow FROM d) < 6
           AND NOT EXISTS (SELECT 1 FROM appointment a
                            WHERE a.appointment_status_code <> 'CANCELLED' AND a.clinician_id = %s
                              AND a.slot && tstzrange(d::date::timestamp AT TIME ZONE 'Africa/Lagos',
                                                      (d::date + 1)::timestamp AT TIME ZONE 'Africa/Lagos'))
           AND NOT EXISTS (SELECT 1 FROM unnest(%s::bigint[]) p (patient_id)
                             JOIN appointment a ON a.patient_id = p.patient_id
                            WHERE a.appointment_status_code <> 'CANCELLED'
                              AND a.slot && tstzrange(d::date::timestamp AT TIME ZONE 'Africa/Lagos',
                                                      (d::date + 1)::timestamp AT TIME ZONE 'Africa/Lagos'))
         ORDER BY d LIMIT 1""", (clinician_id, list(patient_ids)))


def main():
    sysc = session("sys")
    k = ids(sysc)

    section("1. Non-repeatable read: re-reading a stock level inside one transaction")
    for level in ("READ COMMITTED", "REPEATABLE READ"):
        a, b = session("A"), session("B")
        log("---", level)
        run(a, "A", f"BEGIN ISOLATION LEVEL {level}")
        first = run(a, "A", STOCK, (k["ikeja"], k["amoxicillin"]))[0][0]
        run(b, "B", "SELECT receive_stock(%s, %s, 10, %s, 'Isolation demonstration delivery')",
            (k["ikeja"], k["amoxicillin"], k["pharmacist"]))
        log("B", "autocommit: the delivery of 10 is committed")
        second = run(a, "A", STOCK, (k["ikeja"], k["amoxicillin"]))[0][0]
        run(a, "A", "COMMIT")
        if level == "READ COMMITTED":
            check("READ COMMITTED: the second read sees the committed delivery (non-repeatable read)",
                  second == first + 10, f"{first} then {second}")
        else:
            check("REPEATABLE READ: both reads come from one snapshot", second == first, f"{first} then {second}")
        a.close(), b.close()

    section("2. Phantom: counting a clinician's appointments for a day while another booking arrives")
    patients = [k["patient_a"], k["patient_b"], k["patient_c"]]
    day = free_day(sysc, k["doctor_2"], patients)
    log("sys", f"using {day}, a day on which Dr Adeyemi and the three patients have no appointments")
    run(sysc, "sys", "SELECT book_appointment(%s, %s, %s, %s, (%s::date + time '08:00') AT TIME ZONE 'Africa/Lagos', 30, %s)",
        (k["patient_a"], k["doctor_2"], k["gp"], k["ikeja"], day, k["reception"]))
    for level, patient, start in (("READ COMMITTED", k["patient_b"], "08:30"), ("REPEATABLE READ", k["patient_c"], "09:00")):
        a, b = session("A"), session("B")
        log("---", level)
        run(a, "A", f"BEGIN ISOLATION LEVEL {level}")
        first = run(a, "A", DAY_COUNT, (k["doctor_2"], day, day))[0][0]
        run(b, "B", f"SELECT book_appointment(%s, %s, %s, %s, (%s::date + time '{start}') AT TIME ZONE 'Africa/Lagos', 30, %s)",
            (patient, k["doctor_2"], k["gp"], k["ikeja"], day, k["reception"]))
        log("B", "autocommit: a new appointment on that day is committed")
        second = run(a, "A", DAY_COUNT, (k["doctor_2"], day, day))[0][0]
        run(a, "A", "COMMIT")
        if level == "READ COMMITTED":
            check("READ COMMITTED: a new row appears in the same query (phantom)", second == first + 1,
                  f"{first} then {second}")
        else:
            check("REPEATABLE READ: no phantom, the count is stable", second == first, f"{first} then {second}")
        a.close(), b.close()

    section("3. READ UNCOMMITTED is READ COMMITTED in PostgreSQL: a dirty read cannot happen")
    a, b = session("A"), session("B")
    committed = value(sysc, STOCK, (k["ikeja"], k["amoxicillin"]))
    run(b, "B", "BEGIN")
    run(b, "B", "SELECT receive_stock(%s, %s, 500, %s, 'Delivery that will be cancelled')",
        (k["ikeja"], k["amoxicillin"], k["pharmacist"]))
    log("B", "500 units added but not committed")
    run(a, "A", "BEGIN ISOLATION LEVEL READ UNCOMMITTED")
    run(a, "A", "SHOW transaction_isolation")
    seen = run(a, "A", STOCK, (k["ikeja"], k["amoxicillin"]))[0][0]
    run(b, "B", "ROLLBACK")
    run(a, "A", "COMMIT")
    check("READ UNCOMMITTED does not see B's uncommitted 500 units", seen == committed, f"saw {seen}, committed {committed}")
    a.close(), b.close()

    section("4. Write skew on the on-call rule: at least one clinician must stay on call")
    for level in ("REPEATABLE READ", "SERIALIZABLE"):
        shift_date = value(sysc, "SELECT greatest(coalesce(max(shift_date), DATE '2027-01-01'), DATE '2027-01-01') + 1 "
                                 "FROM on_call_shift WHERE facility_id = %s", (k["ikeja"],))
        s1, s2 = (r[0] for r in sysc.execute(
            "INSERT INTO on_call_shift (facility_id, clinician_id, shift_date) VALUES (%s, %s, %s), (%s, %s, %s) "
            "RETURNING on_call_shift_id", (k["ikeja"], k["doctor_1"], shift_date, k["ikeja"], k["doctor_2"], shift_date)))
        log("sys", f"{level}: Dr Okafor (shift {s1}) and Dr Adeyemi (shift {s2}) are both on call at Ikeja on {shift_date}")
        a, b = session("A"), session("B")
        run(a, "A", f"BEGIN ISOLATION LEVEL {level}")
        run(a, "A", "SELECT sign_off_on_call(%s)", (s1,))
        run(b, "B", f"BEGIN ISOLATION LEVEL {level}")
        run(b, "B", "SELECT sign_off_on_call(%s)", (s2,))
        log("B", "each saw the other still on call in its own snapshot, so each was allowed to sign off")
        run(a, "A", "COMMIT")
        _, err = attempt(b, "B", "COMMIT")
        on_call = value(sysc, "SELECT count(*) FROM on_call_shift WHERE facility_id = %s AND shift_date = %s AND on_call",
                        (k["ikeja"], shift_date))
        if level == "REPEATABLE READ":
            check("REPEATABLE READ: both sign-offs commit and nobody is left on call (write skew)",
                  err is None and on_call == 0, f"{on_call} on call")
            run(sysc, "sys", "UPDATE on_call_shift SET on_call = true WHERE on_call_shift_id = %s", (s2,))
            log("sys", "rota repaired by hand so the night is covered again")
        else:
            check("SERIALIZABLE: the second sign-off fails with a serialization failure",
                  err is not None and err.sqlstate == "40001")
            run(b, "B", "BEGIN ISOLATION LEVEL SERIALIZABLE")
            _, retry = attempt(b, "B", "SELECT sign_off_on_call(%s)", (s2,))
            run(b, "B", "ROLLBACK")
            on_call = value(sysc, "SELECT count(*) FROM on_call_shift WHERE facility_id = %s AND shift_date = %s AND on_call",
                            (k["ikeja"], shift_date))
            check("on retry the rule itself refuses the second sign-off",
                  retry is not None and retry.diag.constraint_name == "on_call_minimum_fn")
            check("one clinician is still on call", on_call == 1)
        a.close(), b.close()
    summary()


if __name__ == "__main__":
    main()
