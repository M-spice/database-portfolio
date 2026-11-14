\ir harness.sql
\o /dev/null

SELECT pg_temp.check_case('routines', 'register_patient issues a hospital number and a primary phone', 'ok', $q$
  DO $d$
  DECLARE hn text;
  BEGIN
    hn := register_patient(pg_temp.stf('ST-00017'), 'Temitope', NULL, 'Ajayi', '1993-04-21', '+2340009000001',
                           '2 Toyin Street', 'Ikeja', 'Lagos');
    ASSERT hn ~ '^HN-[0-9]{7}$' AND substr(hn, 4)::int > 12, 'unexpected hospital number ' || hn;
    ASSERT (SELECT ph.is_primary FROM patient_phone ph JOIN patient p USING (patient_id) WHERE p.hospital_no = hn);
    ASSERT (SELECT registered_facility_id FROM patient WHERE hospital_no = hn) = pg_temp.fac('LAG-IKJ');
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'registration with a bad phone is refused', 'patient_phone_no_ck', $q$
  SELECT register_patient(pg_temp.stf('ST-00017'), 'Temitope', NULL, 'Ajayi', '1993-04-21', '+2348030000000',
                          '2 Toyin Street', 'Ikeja', 'Lagos') $q$);
SELECT pg_temp.check_case('routines', 'a failed registration leaves no patient behind', 'ok', $q$
  DO $d$
  DECLARE before bigint := (SELECT count(*) FROM patient);
  BEGIN
    BEGIN
      PERFORM register_patient(pg_temp.stf('ST-00017'), 'Temitope', NULL, 'Ajayi', '1993-04-21', '+2348030000000',
                               '2 Toyin Street', 'Ikeja', 'Lagos');
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    ASSERT (SELECT count(*) FROM patient) = before, 'a half-registered patient was left behind';
  END $d$ $q$);

SELECT pg_temp.check_case('routines', 'book_appointment books a slot and logs BOOKED', 'ok', $q$
  DO $d$
  DECLARE id bigint;
  BEGIN
    id := book_appointment(pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
                           '2026-11-17 11:00+01', 30, pg_temp.stf('ST-00017'));
    ASSERT (SELECT appointment_status_code FROM appointment WHERE appointment_id = id) = 'BOOKED';
    ASSERT (SELECT count(*) FROM appointment_status_history
             WHERE appointment_id = id AND appointment_status_code = 'BOOKED' AND changed_by = pg_temp.stf('ST-00017')) = 1;
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'book_appointment refuses an overlapping slot', 'appointment_clinician_slot_ex', $q$
  SELECT book_appointment(pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
                          '2026-11-17 09:10+01', 30, pg_temp.stf('ST-00017')) $q$);
SELECT pg_temp.check_case('routines', 'a repeated request key returns the original booking', 'ok', $q$
  DO $d$
  DECLARE
    k uuid := '00000000-0000-4000-8000-0000000000cc';
    a bigint;
    b bigint;
  BEGIN
    a := book_appointment(pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
                          '2026-11-18 09:00+01', 30, NULL, k);
    b := book_appointment(pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
                          '2026-11-18 09:00+01', 30, NULL, k);
    ASSERT a = b, 'the retry created a second appointment';
    ASSERT (SELECT count(*) FROM appointment WHERE request_key = k) = 1;
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'rescheduling moves a booking without a new status row', 'ok', $q$
  DO $d$
  DECLARE
    id bigint := (SELECT appointment_id FROM appointment
                   WHERE patient_id = pg_temp.pat('HN-0000001') AND lower(slot) = '2026-11-17 09:00+01');
    rows_before bigint := (SELECT count(*) FROM appointment_status_history WHERE appointment_id = id);
  BEGIN
    PERFORM reschedule_appointment(id, '2026-11-17 12:00+01', 30, pg_temp.stf('ST-00017'));
    ASSERT (SELECT lower(slot) FROM appointment WHERE appointment_id = id) = '2026-11-17 12:00+01';
    ASSERT (SELECT count(*) FROM appointment_status_history WHERE appointment_id = id) = rows_before;
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'a cancelled appointment cannot be rescheduled', 'appointment_reschedule_fn', $q$
  SELECT reschedule_appointment(a.appointment_id, '2026-11-20 14:00+01', 30, pg_temp.stf('ST-00017'))
    FROM appointment a WHERE a.patient_id = pg_temp.pat('HN-0000008') $q$);
SELECT pg_temp.check_case('routines', 'cancelling logs CANCELLED and frees the slot', 'ok', $q$
  DO $d$
  DECLARE
    id bigint := (SELECT appointment_id FROM appointment
                   WHERE patient_id = pg_temp.pat('HN-0000001') AND lower(slot) = '2026-11-17 09:00+01');
  BEGIN
    PERFORM cancel_appointment(id, pg_temp.stf('ST-00017'));
    ASSERT (SELECT appointment_status_code FROM appointment WHERE appointment_id = id) = 'CANCELLED';
    ASSERT EXISTS (SELECT 1 FROM appointment_status_history
                    WHERE appointment_id = id AND appointment_status_code = 'CANCELLED' AND changed_by = pg_temp.stf('ST-00017'));
    PERFORM book_appointment(pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
                             '2026-11-17 09:00+01', 30, pg_temp.stf('ST-00017'));
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'a completed appointment cannot be cancelled', 'appointment_cancel_fn', $q$
  SELECT cancel_appointment(e.appointment_id, pg_temp.stf('ST-00017'))
    FROM encounter e WHERE e.encounter_id = pg_temp.enc('HN-0000001', '2026-10-05') $q$);

SELECT pg_temp.check_case('routines', 'dispensing takes the prescribed quantity off the shelf', 'ok', $q$
  DO $d$
  DECLARE before integer := (SELECT quantity FROM stock_on_hand
                              WHERE facility_id = pg_temp.fac('LAG-IKJ') AND drug_id = pg_temp.drg('DRG-0004'));
  BEGIN
    PERFORM dispense_prescription_item(pg_temp.rx('HN-0000001', '2026-11-09'), pg_temp.drg('DRG-0004'),
                                       pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00012'));
    ASSERT (SELECT quantity FROM stock_on_hand
             WHERE facility_id = pg_temp.fac('LAG-IKJ') AND drug_id = pg_temp.drg('DRG-0004')) = before - 30;
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'dispensing more than the branch holds is refused', 'stock_on_hand_quantity_ck', $q$
  SELECT dispense_prescription_item(pg_temp.rx('HN-0000001', '2026-11-09'), pg_temp.drg('DRG-0004'),
                                    pg_temp.fac('LAG-YAB'), pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('routines', 'an item cannot be dispensed twice', 'stock_movement_prescription_item_uk', $q$
  SELECT dispense_prescription_item(pg_temp.rx('HN-0000001', '2026-10-05'), pg_temp.drg('DRG-0001'),
                                    pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('routines', 'only a prescribed drug can be dispensed', 'stock_movement_prescription_item_fk', $q$
  SELECT dispense_prescription_item(pg_temp.rx('HN-0000001', '2026-11-09'), pg_temp.drg('DRG-0010'),
                                    pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('routines', 'a transfer moves stock between branches as one pair', 'ok', $q$
  DO $d$
  DECLARE
    a0 integer := (SELECT quantity FROM stock_on_hand WHERE facility_id = pg_temp.fac('LAG-IKJ') AND drug_id = pg_temp.drg('DRG-0002'));
    b0 integer := (SELECT quantity FROM stock_on_hand WHERE facility_id = pg_temp.fac('LAG-LEK') AND drug_id = pg_temp.drg('DRG-0002'));
    ref uuid;
  BEGIN
    ref := transfer_stock(pg_temp.drg('DRG-0002'), pg_temp.fac('LAG-IKJ'), pg_temp.fac('LAG-LEK'), 100, pg_temp.stf('ST-00012'));
    SET CONSTRAINTS ALL IMMEDIATE;
    ASSERT (SELECT quantity FROM stock_on_hand WHERE facility_id = pg_temp.fac('LAG-IKJ') AND drug_id = pg_temp.drg('DRG-0002')) = a0 - 100;
    ASSERT (SELECT quantity FROM stock_on_hand WHERE facility_id = pg_temp.fac('LAG-LEK') AND drug_id = pg_temp.drg('DRG-0002')) = b0 + 100;
    ASSERT (SELECT count(*) FROM stock_movement WHERE transfer_ref = ref) = 2;
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'a transfer larger than the stock is refused', 'stock_on_hand_quantity_ck', $q$
  SELECT transfer_stock(pg_temp.drg('DRG-0002'), pg_temp.fac('LAG-IKJ'), pg_temp.fac('LAG-LEK'), 999999, pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('routines', 'a transfer needs two different branches', 'stock_transfer_facilities_fn', $q$
  SELECT transfer_stock(pg_temp.drg('DRG-0002'), pg_temp.fac('LAG-IKJ'), pg_temp.fac('LAG-IKJ'), 10, pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('routines', 'receiving stock opens a stock line at a new branch', 'ok', $q$
  DO $d$
  BEGIN
    PERFORM receive_stock(pg_temp.fac('LAG-SUR'), pg_temp.drg('DRG-0002'), 500, pg_temp.stf('ST-00012'), 'First delivery');
    ASSERT (SELECT quantity FROM stock_on_hand WHERE facility_id = pg_temp.fac('LAG-SUR') AND drug_id = pg_temp.drg('DRG-0002')) = 500;
  END $d$ $q$);

SELECT pg_temp.check_case('routines', 'a numeric result is recorded for a quantitative test', 'ok', $q$
  DO $d$
  DECLARE o bigint;
  BEGIN
    INSERT INTO lab_order (encounter_id, lab_test_id, facility_id, ordered_by, ordered_at)
    VALUES (pg_temp.enc('HN-0000005', '2026-11-11'), pg_temp.lab('LT-HB'), pg_temp.fac('ENU-IND'), pg_temp.stf('ST-00006'),
            '2026-11-11 10:20+01')
    RETURNING lab_order_id INTO o;
    ASSERT record_lab_result(o, pg_temp.stf('ST-00016'), 13.4, NULL) IS NOT NULL;
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'a correction supersedes the original result', 'ok', $q$
  DO $d$
  DECLARE
    original bigint := (SELECT lab_result_id FROM lab_result
                         WHERE lab_order_id = pg_temp.ord('HN-0000001', 'LT-CREAT') AND supersedes_result_id IS NULL);
    corrected bigint;
  BEGIN
    corrected := record_lab_result(pg_temp.ord('HN-0000001', 'LT-CREAT'), pg_temp.stf('ST-00015'), 96, NULL,
                                   original, 'Re-run on a fresh sample');
    ASSERT (SELECT supersedes_result_id FROM lab_result WHERE lab_result_id = corrected) = original;
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'a qualitative test refuses a numeric result', 'lab_result_value_kind_tg', $q$
  DO $d$
  DECLARE o bigint;
  BEGIN
    INSERT INTO lab_order (encounter_id, lab_test_id, facility_id, ordered_by, ordered_at)
    VALUES (pg_temp.enc('HN-0000005', '2026-11-11'), pg_temp.lab('LT-URINE'), pg_temp.fac('ENU-IND'), pg_temp.stf('ST-00006'),
            '2026-11-11 10:20+01')
    RETURNING lab_order_id INTO o;
    PERFORM record_lab_result(o, pg_temp.stf('ST-00016'), 5, NULL);
  END $d$ $q$);

SELECT pg_temp.check_case('routines', 'opening a record returns the timeline and writes one audit row', 'ok', $q$
  DO $d$
  DECLARE
    rows_before bigint := (SELECT count(*) FROM record_access_log);
    rec jsonb;
  BEGIN
    rec := patient_record(pg_temp.stf('ST-00001'), pg_temp.pat('HN-0000001'), 'Ward round');
    ASSERT rec->>'hospital_no' = 'HN-0000001';
    ASSERT jsonb_array_length(rec->'encounters') = 2;
    ASSERT (rec->'encounters'->0->>'started_at')::timestamptz > (rec->'encounters'->1->>'started_at')::timestamptz,
           'timeline is not newest first';
    ASSERT (SELECT count(*) FROM record_access_log) = rows_before + 1;
    ASSERT (SELECT staff_id = pg_temp.stf('ST-00001') AND db_user = session_user
              FROM record_access_log ORDER BY record_access_log_id DESC LIMIT 1);
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'staff who have left cannot open records', 'record_access_active_staff_fn', $q$
  SELECT patient_record(pg_temp.stf('ST-00024'), pg_temp.pat('HN-0000001'), 'Curiosity') $q$);
SELECT pg_temp.check_case('routines', 'an unknown patient cannot be opened', 'record_access_log_patient_fk', $q$
  SELECT patient_record(pg_temp.stf('ST-00001'), -1, 'Ward round') $q$);

SELECT pg_temp.check_case('routines', 'a clinician signs off while a colleague stays on call', 'ok', $q$
  SELECT sign_off_on_call(s.on_call_shift_id) FROM on_call_shift s
   WHERE s.clinician_id = pg_temp.stf('ST-00001') AND s.shift_date = '2026-11-14' $q$);
SELECT pg_temp.check_case('routines', 'the last clinician on call cannot sign off', 'on_call_minimum_fn', $q$
  SELECT sign_off_on_call(s.on_call_shift_id) FROM on_call_shift s
   WHERE s.clinician_id = pg_temp.stf('ST-00004') AND s.shift_date = '2026-11-14' $q$);

SELECT pg_temp.check_case('routines', 'paying the remaining balance settles an invoice', 'ok', $q$
  DO $d$
  DECLARE
    inv bigint := pg_temp.inv('HN-0000003', '2026-10-20');
    remaining bigint := (SELECT total_kobo FROM invoice WHERE invoice_id = inv)
                        - (SELECT sum(amount_kobo) FROM payment WHERE invoice_id = inv);
  BEGIN
    INSERT INTO payment (invoice_id, payment_method_code, amount_kobo, received_by, reference)
    VALUES (inv, 'CARD', remaining, pg_temp.stf('ST-00019'), 'POS-310300');
    ASSERT (SELECT sum(amount_kobo) FROM payment WHERE invoice_id = inv) = (SELECT total_kobo FROM invoice WHERE invoice_id = inv);
  END $d$ $q$);
SELECT pg_temp.check_case('routines', 'age band is derived from date of birth', 'ok', $q$
  DO $d$
  BEGIN
    ASSERT age_band('2019-06-01', '2026-11-14') = '05-14';
    ASSERT age_band('2001-11-15', '2026-11-14') = '15-24';
    ASSERT age_band('1945-01-30', '2026-11-14') = '65+';
  END $d$ $q$);

\o
\ir report.sql
