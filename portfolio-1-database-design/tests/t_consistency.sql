\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
SET ROLE itoju_owner;
SET search_path = itoju, public;

CREATE TEMP TABLE consistency AS
WITH ledger AS (
  SELECT m.facility_id, m.drug_id, sum(mt.direction * m.quantity) AS quantity
    FROM stock_movement m JOIN movement_type mt USING (movement_type_code)
   GROUP BY m.facility_id, m.drug_id
), transfers AS (
  SELECT m.transfer_ref,
         count(*) FILTER (WHERE mt.direction < 0) AS legs_out,
         count(*) FILTER (WHERE mt.direction > 0) AS legs_in,
         count(DISTINCT m.drug_id) AS drugs, count(DISTINCT m.quantity) AS quantities,
         count(DISTINCT m.facility_id) AS facilities
    FROM stock_movement m JOIN movement_type mt USING (movement_type_code)
   WHERE m.transfer_ref IS NOT NULL
   GROUP BY m.transfer_ref
), active AS (
  SELECT appointment_id, patient_id, clinician_id, slot
    FROM appointment WHERE appointment_status_code <> 'CANCELLED'
), latest_status AS (
  SELECT DISTINCT ON (appointment_id) appointment_id, appointment_status_code
    FROM appointment_status_history
   ORDER BY appointment_id, changed_at DESC, appointment_status_history_id DESC
)
SELECT * FROM (VALUES
  (1, 'Stock on hand equals the movement ledger',
      (SELECT count(*) FROM stock_on_hand),
      (SELECT count(*) FROM stock_on_hand s FULL JOIN ledger l USING (facility_id, drug_id)
        WHERE s.quantity IS DISTINCT FROM l.quantity)),
  (2, 'No stock level is negative',
      (SELECT count(*) FROM stock_on_hand),
      (SELECT count(*) FROM stock_on_hand WHERE quantity < 0)),
  (3, 'Every transfer is one leg out and one in, same drug and quantity, two branches',
      (SELECT count(*) FROM transfers),
      (SELECT count(*) FROM transfers
        WHERE legs_out <> 1 OR legs_in <> 1 OR drugs <> 1 OR quantities <> 1 OR facilities <> 2)),
  (4, 'Every dispense matches its prescribed quantity',
      (SELECT count(*) FROM stock_movement WHERE movement_type_code = 'DISPENSE'),
      (SELECT count(*) FROM stock_movement m JOIN prescription_item pi USING (prescription_id, drug_id)
        WHERE m.quantity <> pi.quantity)),
  (5, 'Every invoice total equals the sum of its lines',
      (SELECT count(*) FROM invoice),
      (SELECT count(*) FROM invoice i
        WHERE i.total_kobo <> (SELECT coalesce(sum(l.amount_kobo), 0) FROM invoice_line l WHERE l.invoice_id = i.invoice_id))),
  (6, 'No invoice is paid beyond its total',
      (SELECT count(*) FROM invoice),
      (SELECT count(*) FROM invoice i
        WHERE (SELECT coalesce(sum(p.amount_kobo), 0) FROM payment p WHERE p.invoice_id = i.invoice_id) > i.total_kobo)),
  (7, 'No clinician has overlapping active appointments',
      (SELECT count(*) FROM active),
      (SELECT count(*) FROM active a JOIN active b
          ON a.clinician_id = b.clinician_id AND a.appointment_id < b.appointment_id AND a.slot && b.slot)),
  (8, 'No patient has overlapping active appointments',
      (SELECT count(*) FROM active),
      (SELECT count(*) FROM active a JOIN active b
          ON a.patient_id = b.patient_id AND a.appointment_id < b.appointment_id AND a.slot && b.slot)),
  (9, 'Each appointment''s latest history status is its current status',
      (SELECT count(*) FROM appointment),
      (SELECT count(*) FROM appointment a LEFT JOIN latest_status h USING (appointment_id)
        WHERE h.appointment_status_code IS DISTINCT FROM a.appointment_status_code)),
  (10, 'Every encounter booked through an appointment belongs to that appointment''s patient',
      (SELECT count(*) FROM encounter WHERE appointment_id IS NOT NULL),
      (SELECT count(*) FROM encounter e JOIN appointment a USING (appointment_id) WHERE e.patient_id <> a.patient_id)),
  (11, 'Every amendment and correction stays within its encounter or order',
      (SELECT count(*) FROM clinical_note WHERE amends_note_id IS NOT NULL)
        + (SELECT count(*) FROM lab_result WHERE supersedes_result_id IS NOT NULL),
      (SELECT count(*) FROM clinical_note n JOIN clinical_note o ON o.clinical_note_id = n.amends_note_id
        WHERE o.encounter_id <> n.encounter_id)
        + (SELECT count(*) FROM lab_result r JOIN lab_result o ON o.lab_result_id = r.supersedes_result_id
            WHERE o.lab_order_id <> r.lab_order_id)),
  (12, 'Every clinician holds a clinical role',
      (SELECT count(*) FROM clinician),
      (SELECT count(*) FROM clinician c JOIN staff s ON s.staff_id = c.clinician_id
        JOIN staff_role r USING (staff_role_code) WHERE NOT r.is_clinical)),
  (13, 'Every rostered facility and night keeps at least one clinician on call',
      (SELECT count(DISTINCT (facility_id, shift_date)) FROM on_call_shift),
      (SELECT count(*) FROM (SELECT facility_id, shift_date FROM on_call_shift
                              GROUP BY facility_id, shift_date HAVING NOT bool_or(on_call)) g)),
  (14, 'Every lab result is recorded after its order',
      (SELECT count(*) FROM lab_result),
      (SELECT count(*) FROM lab_result r JOIN lab_order o USING (lab_order_id) WHERE r.recorded_at < o.ordered_at))
) AS c (n, rule, rows_checked, violations);

SELECT n AS "#", rule, rows_checked, violations, CASE WHEN violations = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM consistency ORDER BY n;

SELECT count(*) AS checks, count(*) FILTER (WHERE violations = 0) AS passed, count(*) FILTER (WHERE violations > 0) AS failed
  FROM consistency;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM consistency WHERE violations > 0) THEN
    RAISE EXCEPTION 'consistency check failed';
  END IF;
END $$;
