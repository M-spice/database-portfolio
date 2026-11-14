"""Load the Itoju Clinics data from PostgreSQL into MongoDB as documents, then check counts and totals match."""

from datetime import date, datetime, time as dtime, timezone

from tabulate import tabulate

from common import check, log, mongo, postgres, section, summary
from model import create_all

BATCH = 5000

PATIENTS = """
SELECT p.patient_id, p.hospital_no, p.given_name, p.middle_name, p.family_name, p.date_of_birth, p.national_id,
       p.address_line, p.address_city, p.address_state, f.facility_code, p.registered_at,
       ph.phones, al.allergies, k.kin, c.consents
  FROM patient p
  JOIN facility f ON f.facility_id = p.registered_facility_id
  LEFT JOIN (SELECT patient_id, jsonb_agg(jsonb_build_object('number', phone_no, 'primary', is_primary)
                                          ORDER BY NOT is_primary, phone_no) AS phones
               FROM patient_phone GROUP BY patient_id) ph USING (patient_id)
  LEFT JOIN (SELECT patient_id, jsonb_agg(jsonb_build_object('allergen', allergen, 'reaction', reaction,
                                                             'recorded_at', recorded_at) ORDER BY allergen) AS allergies
               FROM patient_allergy GROUP BY patient_id) al USING (patient_id)
  LEFT JOIN (SELECT patient_id, jsonb_agg(jsonb_build_object('kin_no', kin_no, 'full_name', full_name,
                                                             'relationship', relationship, 'phone', phone_no)
                                          ORDER BY kin_no) AS kin
               FROM next_of_kin GROUP BY patient_id) k USING (patient_id)
  LEFT JOIN (SELECT patient_id, jsonb_agg(jsonb_build_object('purpose', consent_purpose_code, 'granted_at', granted_at,
                                                             'withdrawn_at', withdrawn_at)
                                          ORDER BY granted_at, consent_purpose_code) AS consents
               FROM consent GROUP BY patient_id) c USING (patient_id)
 ORDER BY p.patient_id"""

ENCOUNTERS = """
WITH v AS (
  SELECT encounter_id, jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'recorded_at', recorded_at, 'temperature_c', temperature_c, 'pulse_bpm', pulse_bpm,
           'systolic_mmhg', systolic_mmhg, 'diastolic_mmhg', diastolic_mmhg, 'spo2_pct', spo2_pct,
           'weight_kg', weight_kg, 'height_cm', height_cm)) ORDER BY recorded_at, vital_sign_id) AS vitals
    FROM vital_sign GROUP BY encounter_id
), d AS (
  SELECT ed.encounter_id, jsonb_agg(jsonb_build_object('code', ed.diagnosis_code, 'description', dc.description,
                                                       'primary', ed.is_primary)
                                    ORDER BY ed.is_primary DESC, ed.diagnosis_code) AS diagnoses
    FROM encounter_diagnosis ed JOIN diagnosis_code dc USING (diagnosis_code) GROUP BY ed.encounter_id
), items AS (
  SELECT pi.prescription_id, jsonb_agg(jsonb_build_object('drug_code', dr.drug_code, 'name', dr.name,
                                                          'quantity', pi.quantity, 'dosage', pi.dosage)
                                       ORDER BY dr.drug_code) AS items
    FROM prescription_item pi JOIN drug dr USING (drug_id) GROUP BY pi.prescription_id
), rx AS (
  SELECT r.encounter_id, jsonb_agg(jsonb_build_object('prescription_id', r.prescription_id, 'issued_at', r.issued_at,
                                                      'items', i.items) ORDER BY r.prescription_id) AS prescriptions
    FROM prescription r JOIN items i USING (prescription_id) GROUP BY r.encounter_id
), numbered AS (
  SELECT n.*, row_number() OVER (PARTITION BY n.encounter_id ORDER BY n.clinical_note_id) AS note_no
    FROM clinical_note n
), notes AS (
  SELECT n.encounter_id, jsonb_agg(jsonb_build_object('note_no', n.note_no, 'author', s.staff_no, 'written_at', n.written_at,
                                                      'body', n.body, 'amends_note_no', a.note_no,
                                                      'amendment_reason', n.amendment_reason) ORDER BY n.note_no) AS notes
    FROM numbered n JOIN staff s ON s.staff_id = n.author_id
    LEFT JOIN numbered a ON a.clinical_note_id = n.amends_note_id
   GROUP BY n.encounter_id
), orders AS (
  SELECT o.encounter_id, jsonb_agg(jsonb_build_object('lab_order_id', o.lab_order_id, 'test_code', t.test_code,
                                                      'ordered_at', o.ordered_at) ORDER BY o.lab_order_id) AS lab_orders
    FROM lab_order o JOIN lab_test t USING (lab_test_id) GROUP BY o.encounter_id
)
SELECT e.encounter_id, e.patient_id,
       encode(substr(sha256(k.secret || int8send(e.patient_id)), 1, 8), 'hex') AS patient_key,
       f.facility_code, s.staff_no, s.given_name || ' ' || s.family_name AS clinician_name,
       e.encounter_type_code, e.started_at, e.ended_at, e.appointment_id,
       v.vitals, d.diagnoses, rx.prescriptions, notes.notes, orders.lab_orders
  FROM encounter e
  JOIN facility f ON f.facility_id = e.facility_id
  JOIN staff s ON s.staff_id = e.clinician_id
 CROSS JOIN pseudonym_key k
  LEFT JOIN v USING (encounter_id)
  LEFT JOIN d USING (encounter_id)
  LEFT JOIN rx USING (encounter_id)
  LEFT JOIN notes USING (encounter_id)
  LEFT JOIN orders USING (encounter_id)
 ORDER BY e.encounter_id"""

LAB_RESULTS = """
SELECT r.lab_result_id, r.lab_order_id, o.encounter_id, e.patient_id, t.test_code, t.name, t.unit,
       t.reference_low, t.reference_high, extract(epoch FROM t.target_turnaround) / 3600 AS target_hours,
       f.facility_code, o.ordered_at, r.recorded_at, r.value_numeric, r.value_text,
       r.supersedes_result_id, r.correction_reason
  FROM lab_result r
  JOIN lab_order o USING (lab_order_id)
  JOIN encounter e ON e.encounter_id = o.encounter_id
  JOIN lab_test t ON t.lab_test_id = o.lab_test_id
  JOIN facility f ON f.facility_id = o.facility_id
 ORDER BY r.lab_result_id"""

INVOICES = """
SELECT i.invoice_id, i.invoice_no, i.patient_id, f.facility_code, i.encounter_id, i.issued_at, s.staff_no, i.total_kobo,
       l.lines, p.payments
  FROM invoice i
  JOIN facility f ON f.facility_id = i.facility_id
  JOIN staff s ON s.staff_id = i.issued_by
  JOIN (SELECT il.invoice_id, jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                 'line_no', il.line_no, 'description', il.description, 'drug_code', d.drug_code, 'test_code', t.test_code,
                 'quantity', il.quantity, 'unit_price_kobo', il.unit_price_kobo, 'amount_kobo', il.amount_kobo))
                 ORDER BY il.line_no) AS lines
          FROM invoice_line il LEFT JOIN drug d USING (drug_id) LEFT JOIN lab_test t USING (lab_test_id)
         GROUP BY il.invoice_id) l USING (invoice_id)
  LEFT JOIN (SELECT invoice_id, jsonb_agg(jsonb_build_object('method', payment_method_code, 'amount_kobo', amount_kobo,
                                                            'paid_at', paid_at, 'reference', reference)
                                          ORDER BY paid_at, payment_id) AS payments
               FROM payment GROUP BY invoice_id) p USING (invoice_id)
 ORDER BY i.invoice_id"""

CLINICIANS = """
SELECT s.staff_id, s.staff_no, s.given_name, s.family_name, s.staff_role_code, f.facility_code, c.licence_no,
       array_agg(d.department_code ORDER BY cd.assigned_on, d.department_code) AS departments
  FROM clinician c
  JOIN staff s ON s.staff_id = c.clinician_id
  JOIN facility f ON f.facility_id = s.home_facility_id
  JOIN clinician_department cd ON cd.clinician_id = c.clinician_id
  JOIN department d USING (department_id)
 GROUP BY s.staff_id, s.staff_no, s.given_name, s.family_name, s.staff_role_code, f.facility_code, c.licence_no
 ORDER BY s.staff_id"""

STOCK = """
SELECT f.facility_code, d.drug_code, s.quantity, s.updated_at
  FROM stock_on_hand s JOIN facility f USING (facility_id) JOIN drug d USING (drug_id)
 ORDER BY f.facility_code, d.drug_code"""


def ts(value):
    return datetime.fromisoformat(value) if isinstance(value, str) else value


def day(value):
    return datetime.combine(value, dtime(0), tzinfo=timezone.utc)


def with_dates(items, *keys):
    for item in items or []:
        for key in keys:
            if item.get(key) is not None:
                item[key] = ts(item[key])
    return items or []


def patient_doc(r):
    return {
        "_id": r[0], "hospital_no": r[1],
        "name": {"given": r[2], "middle": r[3], "family": r[4]},
        "date_of_birth": day(r[5]), "national_id": r[6],
        "address": {"line": r[7], "city": r[8], "state": r[9]},
        "registered": {"facility": r[10], "at": r[11]},
        "phones": r[12] or [],
        "allergies": with_dates(r[13], "recorded_at"),
        "next_of_kin": r[14] or [],
        "consents": with_dates(r[15], "granted_at", "withdrawn_at"),
    }


def encounter_doc(r):
    prescriptions = with_dates(r[12], "issued_at")
    return {
        "_id": r[0], "patient_id": r[1], "patient_key": r[2], "facility": r[3],
        "clinician": {"staff_no": r[4], "name": r[5]},
        "type": r[6], "started_at": r[7], "ended_at": r[8], "appointment_id": r[9],
        "vitals": with_dates(r[10], "recorded_at"),
        "diagnoses": r[11] or [],
        "prescriptions": prescriptions,
        "notes": with_dates(r[13], "written_at"),
        "lab_orders": with_dates(r[14], "ordered_at"),
    }


def lab_result_doc(r):
    unit = r[6]
    if unit is None:
        result = {"kind": "qualitative", "text": r[14]}
    else:
        value, low, high = float(r[13]), r[7], r[8]
        flag = "low" if low is not None and value < float(low) else "high" if high is not None and value > float(high) else "normal"
        result = {"kind": "numeric", "value": value, "unit": unit,
                  "reference": {"low": float(low), "high": float(high)} if low is not None else None, "flag": flag}
    return {
        "_id": r[0], "lab_order_id": r[1], "encounter_id": r[2], "patient_id": r[3],
        "test": {"code": r[4], "name": r[5], "unit": unit, "target_hours": float(r[9])},
        "facility": r[10], "ordered_at": r[11], "recorded_at": r[12], "result": result,
        "supersedes": r[15], "correction_reason": r[16],
    }


def invoice_doc(r):
    return {
        "_id": r[0], "invoice_no": r[1], "patient_id": r[2], "facility": r[3], "encounter_id": r[4],
        "issued_at": r[5], "issued_by": r[6], "total_kobo": r[7],
        "lines": r[8], "payments": with_dates(r[9], "paid_at"),
    }


def clinician_doc(r):
    return {"_id": r[0], "staff_no": r[1], "name": f"{r[2]} {r[3]}", "role": r[4], "facility": r[5],
            "licence_no": r[6], "departments": list(r[7])}


def stream(pg, sql, collection, build, label):
    loaded = 0
    with pg.transaction(), pg.cursor(name=f"load_{label}") as cur:
        cur.itersize = BATCH
        cur.execute(sql)
        batch = []
        for row in cur:
            batch.append(build(row))
            if len(batch) == BATCH:
                collection.insert_many(batch, ordered=False)
                loaded += len(batch)
                batch = []
        if batch:
            collection.insert_many(batch, ordered=False)
            loaded += len(batch)
    log("ld", f"{label}: {loaded} documents")
    return loaded


def main():
    client = mongo()
    client.drop_database("itoju")
    db = client.itoju
    create_all(db)
    log("ld", "collections created with validators; database itoju (MongoDB) is empty")

    pg = postgres()
    pg.execute("SET work_mem = '512MB'")
    section("Loading from PostgreSQL")
    stream(pg, PATIENTS, db.patients, patient_doc, "patients")
    stream(pg, ENCOUNTERS, db.encounters, encounter_doc, "encounters")
    stream(pg, LAB_RESULTS, db.lab_results, lab_result_doc, "lab_results")
    stream(pg, INVOICES, db.invoices, invoice_doc, "invoices")
    stream(pg, CLINICIANS, db.clinicians, clinician_doc, "clinicians")
    stream(pg, STOCK, db.stock, lambda r: {"_id": f"{r[0]}|{r[1]}", "facility": r[0], "drug_code": r[1],
                                           "quantity": r[2], "updated_at": r[3]}, "stock")

    section("Counts and totals: PostgreSQL against MongoDB")
    one = lambda sql: pg.execute(sql).fetchone()[0]
    agg = lambda coll, pipeline: next(coll.aggregate(pipeline, allowDiskUse=True), {"v": 0})["v"]
    comparisons = [
        ("patients", one("SELECT count(*) FROM patient"), db.patients.count_documents({})),
        ("phone numbers", one("SELECT count(*) FROM patient_phone"),
         agg(db.patients, [{"$group": {"_id": None, "v": {"$sum": {"$size": "$phones"}}}}])),
        ("encounters", one("SELECT count(*) FROM encounter"), db.encounters.count_documents({})),
        ("vital-sign records", one("SELECT count(*) FROM vital_sign"),
         agg(db.encounters, [{"$group": {"_id": None, "v": {"$sum": {"$size": "$vitals"}}}}])),
        ("diagnoses", one("SELECT count(*) FROM encounter_diagnosis"),
         agg(db.encounters, [{"$group": {"_id": None, "v": {"$sum": {"$size": "$diagnoses"}}}}])),
        ("clinical notes", one("SELECT count(*) FROM clinical_note"),
         agg(db.encounters, [{"$group": {"_id": None, "v": {"$sum": {"$size": "$notes"}}}}])),
        ("prescribed units", one("SELECT sum(quantity) FROM prescription_item"),
         agg(db.encounters, [{"$unwind": "$prescriptions"}, {"$unwind": "$prescriptions.items"},
                             {"$group": {"_id": None, "v": {"$sum": "$prescriptions.items.quantity"}}}])),
        ("lab results", one("SELECT count(*) FROM lab_result"), db.lab_results.count_documents({})),
        ("invoices", one("SELECT count(*) FROM invoice"), db.invoices.count_documents({})),
        ("invoiced kobo", one("SELECT sum(total_kobo) FROM invoice"),
         agg(db.invoices, [{"$group": {"_id": None, "v": {"$sum": "$total_kobo"}}}])),
        ("paid kobo", one("SELECT sum(amount_kobo) FROM payment"),
         agg(db.invoices, [{"$unwind": "$payments"}, {"$group": {"_id": None, "v": {"$sum": "$payments.amount_kobo"}}}])),
        ("clinicians", one("SELECT count(*) FROM clinician"), db.clinicians.count_documents({})),
        ("units in stock", one("SELECT sum(quantity) FROM stock_on_hand"),
         agg(db.stock, [{"$group": {"_id": None, "v": {"$sum": "$quantity"}}}])),
    ]
    print(tabulate([[n, p, m, "match" if int(p) == int(m) else "DIFFERENT"] for n, p, m in comparisons],
                   headers=["measure", "PostgreSQL", "MongoDB", "result"], disable_numparse=True))
    for name, p, m in comparisons:
        check(f"{name}: MongoDB matches PostgreSQL", int(p) == int(m), f"{int(m)}")

    stats = db.command("dbStats", scale=1024 * 1024)
    log("ld", f"MongoDB database size: {stats['dataSize']:.0f} MB of documents, {stats['storageSize']:.0f} MB on disk, "
              f"{stats['indexSize']:.0f} MB of indexes")
    summary()


if __name__ == "__main__":
    main()
