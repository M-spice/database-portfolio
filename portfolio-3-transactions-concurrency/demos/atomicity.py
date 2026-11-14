"""Commit, rollback, savepoints, statement atomicity, idempotent retry, and durability across a server crash."""

import re
import subprocess
import uuid
from datetime import datetime, timezone

from common import ROOT, attempt, check, free_slots, ids, log, run, section, session, summary, value

BOOK = "SELECT book_appointment(%s, %s, %s, %s, %s, 30, %s, %s)"


def main():
    sysc = session("sys")
    k = ids(sysc)
    a = session("A")

    section("1. A booking that commits (atomicity and durability)")
    slot = free_slots(sysc, k["doctor_1"], [k["patient_a"]])[0]
    run(a, "A", "BEGIN")
    appt = run(a, "A", BOOK, (k["patient_a"], k["doctor_1"], k["gp"], k["ikeja"], slot, k["reception"], None))[0][0]
    seen_before = value(sysc, "SELECT count(*) FROM appointment WHERE appointment_id = %s", (appt,))
    log("sys", f"before COMMIT another session sees {seen_before} row(s) for appointment {appt}")
    run(a, "A", "COMMIT")
    seen_after = value(sysc, "SELECT count(*) FROM appointment WHERE appointment_id = %s", (appt,))
    history = value(sysc, "SELECT count(*) FROM appointment_status_history "
                          "WHERE appointment_id = %s AND appointment_status_code = 'BOOKED'", (appt,))
    check("an uncommitted booking is invisible to other sessions", seen_before == 0)
    check("after COMMIT the booking and its status history are visible together", seen_after == 1 and history == 1)

    section("2. Dispensing more than the shelf holds rolls the whole transaction back")
    counts = "SELECT (SELECT count(*) FROM prescription), (SELECT count(*) FROM stock_movement), " \
             "(SELECT quantity FROM stock_on_hand WHERE facility_id = %s AND drug_id = %s)"
    before = sysc.execute(counts, (k["ikeja"], k["inhaler"])).fetchone()
    log("sys", f"before: {before[0]} prescriptions, {before[1]} stock movements, {before[2]} inhalers at Ikeja")
    run(a, "A", "BEGIN")
    rx = run(a, "A", "INSERT INTO prescription (encounter_id, prescriber_id) "
                     "SELECT encounter_id, %s FROM encounter WHERE patient_id = %s ORDER BY encounter_id LIMIT 1 "
                     "RETURNING prescription_id", (k["doctor_1"], k["patient_c"]))[0][0]
    run(a, "A", "INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage) "
                "VALUES (%s, %s, 1000, '2 puffs as needed')", (rx, k["inhaler"]))
    _, err = attempt(a, "A", "SELECT dispense_prescription_item(%s, %s, %s, %s)",
                     (rx, k["inhaler"], k["ikeja"], k["pharmacist"]))
    run(a, "A", "ROLLBACK")
    after = sysc.execute(counts, (k["ikeja"], k["inhaler"])).fetchone()
    log("sys", f"after:  {after[0]} prescriptions, {after[1]} stock movements, {after[2]} inhalers at Ikeja")
    check("the dispense is refused by the stock rule",
          err is not None and err.diag.constraint_name == "stock_on_hand_quantity_ck")
    check("ROLLBACK removes the prescription written earlier in the same transaction", tuple(after) == tuple(before))

    section("3. A business decision to abandon an invoice: explicit ROLLBACK")
    run(a, "A", "BEGIN")
    inv_no, inv = run(a, "A", "INSERT INTO invoice (invoice_no, patient_id, facility_id, issued_by, total_kobo) "
                              "VALUES ('INV-' || lpad(nextval('invoice_no_seq')::text, 8, '0'), %s, %s, %s, 500000) "
                              "RETURNING invoice_no, invoice_id", (k["patient_a"], k["ikeja"], k["billing"]))[0]
    run(a, "A", "INSERT INTO invoice_line (invoice_id, line_no, description, quantity, unit_price_kobo) "
                "VALUES (%s, 1, 'Consultation', 1, 500000)", (inv,))
    log("A", f"{inv_no}: the patient turns out to be covered by an HMO, so billing abandons the cash invoice")
    run(a, "A", "ROLLBACK")
    gone = value(sysc, "SELECT count(*) FROM invoice WHERE invoice_id = %s", (inv,))
    last = value(sysc, "SELECT last_value FROM invoice_no_seq")
    check("the abandoned invoice and its line are gone", gone == 0)
    check("its invoice number is not handed out again: sequences are not rolled back",
          last >= int(inv_no[4:]), f"{inv_no} used, sequence now at {last}")

    section("4. SAVEPOINT: an optional step fails, the booking still commits")
    slot = free_slots(sysc, k["doctor_1"], [k["patient_c"]])[0]
    sms_before = value(sysc, "SELECT count(*) FROM consent WHERE patient_id = %s AND consent_purpose_code = 'SMS_REMINDERS'",
                       (k["patient_c"],))
    run(a, "A", "BEGIN")
    appt = run(a, "A", BOOK, (k["patient_c"], k["doctor_1"], k["gp"], k["ikeja"], slot, k["reception"], None))[0][0]
    run(a, "A", "SAVEPOINT sms_consent")
    _, err = attempt(a, "A", "INSERT INTO consent (patient_id, consent_purpose_code, granted_at, recorded_by) "
                             "VALUES (%s, 'SMS_REMINDERS', now(), %s)", (k["patient_c"], k["reception"]))
    run(a, "A", "ROLLBACK TO SAVEPOINT sms_consent")
    run(a, "A", "COMMIT")
    booked = value(sysc, "SELECT count(*) FROM appointment WHERE appointment_id = %s", (appt,))
    sms_after = value(sysc, "SELECT count(*) FROM consent WHERE patient_id = %s AND consent_purpose_code = 'SMS_REMINDERS'",
                      (k["patient_c"],))
    check("the optional consent step failed on its own rule",
          err is not None and err.diag.constraint_name == "consent_patient_purpose_open_uk")
    check("the booking made before the savepoint committed", booked == 1)
    check("nothing from the failed step was kept", sms_after == sms_before)

    section("5. Statement atomicity: a multi-row insert that fails on its third row leaves nothing")
    phones_before = value(sysc, "SELECT count(*) FROM patient_phone WHERE patient_id = %s", (k["patient_a"],))
    _, err = attempt(a, "A", "INSERT INTO patient_phone (patient_id, phone_no) VALUES "
                             "(%s, '+2340009100001'), (%s, '+2340009100002'), (%s, '+2348031234567')",
                     (k["patient_a"], k["patient_a"], k["patient_a"]))
    phones_after = value(sysc, "SELECT count(*) FROM patient_phone WHERE patient_id = %s", (k["patient_a"],))
    check("the statement is refused by the phone-number rule",
          err is not None and err.diag.constraint_name == "patient_phone_no_ck")
    check("the two valid rows before it were not kept", phones_after == phones_before,
          f"phone rows for the patient: {phones_before} before, {phones_after} after")

    section("6. A retried booking request returns the original appointment")
    key = uuid.uuid4()
    slot = free_slots(sysc, k["doctor_1"], [k["patient_b"]])[0]
    first = run(a, "A", BOOK, (k["patient_b"], k["doctor_1"], k["gp"], k["ikeja"], slot, None, key))[0][0]
    log("A", "the booking app times out waiting for the reply and sends the same request again")
    second = run(a, "A", BOOK, (k["patient_b"], k["doctor_1"], k["gp"], k["ikeja"], slot, None, key))[0][0]
    rows = value(sysc, "SELECT count(*) FROM appointment WHERE request_key = %s", (key,))
    check("the retry returns the original appointment", first == second, f"appointment {first}")
    check("exactly one appointment exists for the request key", rows == 1)

    section("7. Durability: committed work survives a crash, uncommitted work does not")
    s1, s2 = free_slots(sysc, k["doctor_2"], [k["patient_a"], k["patient_b"]], 2)
    committed_key, open_key = uuid.uuid4(), uuid.uuid4()
    b = session("B")
    run(a, "A", "BEGIN")
    run(a, "A", BOOK, (k["patient_a"], k["doctor_2"], k["gp"], k["ikeja"], s1, k["reception"], committed_key))
    run(a, "A", "COMMIT")
    run(b, "B", "BEGIN")
    run(b, "B", BOOK, (k["patient_b"], k["doctor_2"], k["gp"], k["ikeja"], s2, k["reception"], open_key))
    log("B", "transaction left open: not committed")

    killed_at = datetime.now(timezone.utc).replace(microsecond=0)
    log("sys", "docker compose kill postgres  (SIGKILL: no shutdown, no final checkpoint)")
    subprocess.run(["docker", "compose", "kill", "postgres"], cwd=ROOT, check=True, capture_output=True)
    for conn in (a, b, sysc):
        try:
            conn.close()
        except Exception:
            pass
    log("sys", "docker compose up -d --wait postgres")
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "postgres"], cwd=ROOT, check=True, capture_output=True)
    logs = subprocess.run(["docker", "compose", "logs", "--since", killed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                           "--no-log-prefix", "postgres"], cwd=ROOT, capture_output=True, text=True).stdout
    recovery = [line.strip() for line in logs.splitlines()
                if re.search(r"interrupted|not properly shut down|automatic recovery|redo (starts|done)|"
                             r"ready to accept", line)]
    for line in recovery:
        log("log", line)

    sysc = session("sys")
    kept = value(sysc, "SELECT count(*) FROM appointment WHERE request_key = %s", (committed_key,))
    lost = value(sysc, "SELECT count(*) FROM appointment WHERE request_key = %s", (open_key,))
    check("the server replayed its write-ahead log on restart",
          any("redo" in line for line in recovery) and any("ready to accept" in line for line in recovery))
    check("the committed booking survived the crash", kept == 1)
    check("the uncommitted booking vanished", lost == 0)
    summary()


if __name__ == "__main__":
    main()
