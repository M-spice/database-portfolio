\ir harness.sql
\o /dev/null

SELECT pg_temp.check_case('privileges', 'reception registers a patient', 'ok', format($q$
  SELECT register_patient(%s, 'Temitope', NULL, 'Ajayi', '1993-04-21', '+2340009000003', '2 Toyin Street', 'Ikeja', 'Lagos')
  $q$, pg_temp.stf('ST-00017')), 'itoju_reception');
SELECT pg_temp.check_case('privileges', 'reception reads the patient directory', 'ok',
  'SELECT * FROM patient_directory', 'itoju_reception');
SELECT pg_temp.check_case('privileges', 'reception cannot read the patient table directly', 'permission_denied',
  'SELECT * FROM patient', 'itoju_reception');
SELECT pg_temp.check_case('privileges', 'reception cannot read clinical notes', 'permission_denied',
  'SELECT * FROM clinical_note', 'itoju_reception');
SELECT pg_temp.check_case('privileges', 'reception books an appointment', 'ok', format($q$
  SELECT book_appointment(%s, %s, %s, %s, '2026-11-17 14:00+01', 30, %s) $q$,
  pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00017')),
  'itoju_reception');
SELECT pg_temp.check_case('privileges', 'reception adds a next of kin', 'ok', format($q$
  INSERT INTO next_of_kin (patient_id, kin_no, full_name, relationship, phone_no) VALUES (%s, 1, 'Ada Okoro', 'Sister', '+2340002000002')
  $q$, pg_temp.pat('HN-0000002')), 'itoju_reception');
SELECT pg_temp.check_case('privileges', 'reception cannot open a clinical record', 'permission_denied', format($q$
  SELECT patient_record(%s, %s, 'Curiosity') $q$, pg_temp.stf('ST-00017'), pg_temp.pat('HN-0000001')), 'itoju_reception');
SELECT pg_temp.check_case('privileges', 'reception cannot record an encounter', 'permission_denied', format($q$
  INSERT INTO encounter (patient_id, clinician_id, facility_id, encounter_type_code, started_at)
  VALUES (%s, %s, %s, 'WALK_IN', now()) $q$, pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.fac('LAG-IKJ')),
  'itoju_reception');

SELECT pg_temp.check_case('privileges', 'a clinician opens a record through the audited function', 'ok', format($q$
  SELECT patient_record(%s, %s, 'Consultation') $q$, pg_temp.stf('ST-00001'), pg_temp.pat('HN-0000001')), 'itoju_clinician');
SELECT pg_temp.check_case('privileges', 'a clinician cannot read the patient table directly', 'permission_denied',
  'SELECT * FROM patient', 'itoju_clinician');
SELECT pg_temp.check_case('privileges', 'a clinician cannot read notes outside the audited function', 'permission_denied',
  'SELECT body FROM clinical_note', 'itoju_clinician');
SELECT pg_temp.check_case('privileges', 'a clinician records an encounter and a note', 'ok', format($q$
  DO $d$
  DECLARE e bigint;
  BEGIN
    INSERT INTO encounter (patient_id, clinician_id, facility_id, encounter_type_code, started_at)
    VALUES (%s, %s, %s, 'WALK_IN', '2026-11-13 12:00+01') RETURNING encounter_id INTO e;
    INSERT INTO clinical_note (encounter_id, author_id, body) VALUES (e, %s, 'Walk-in review, no concerns');
  END $d$ $q$, pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00001')),
  'itoju_clinician');
SELECT pg_temp.check_case('privileges', 'a clinician cannot edit a note', 'permission_denied',
  'UPDATE clinical_note SET body = ''edited''', 'itoju_clinician');
SELECT pg_temp.check_case('privileges', 'a clinician cannot dispense', 'permission_denied', format($q$
  SELECT dispense_prescription_item(%s, %s, %s, %s) $q$,
  pg_temp.rx('HN-0000001', '2026-11-09'), pg_temp.drg('DRG-0004'), pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00001')),
  'itoju_clinician');
SELECT pg_temp.check_case('privileges', 'a clinician reads the day''s appointments', 'ok', format($q$
  SELECT * FROM appointment WHERE clinician_id = %s $q$, pg_temp.stf('ST-00001')), 'itoju_clinician');
SELECT pg_temp.check_case('privileges', 'a clinician signs off on call', 'ok', format($q$
  SELECT sign_off_on_call(%s) $q$,
  (SELECT on_call_shift_id FROM on_call_shift WHERE clinician_id = pg_temp.stf('ST-00002') AND shift_date = '2026-11-14')),
  'itoju_clinician');

SELECT pg_temp.check_case('privileges', 'a pharmacist dispenses', 'ok', format($q$
  SELECT dispense_prescription_item(%s, %s, %s, %s) $q$,
  pg_temp.rx('HN-0000001', '2026-11-09'), pg_temp.drg('DRG-0004'), pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00012')),
  'itoju_pharmacy');
SELECT pg_temp.check_case('privileges', 'a pharmacist transfers stock', 'ok', format($q$
  SELECT transfer_stock(%s, %s, %s, 50, %s) $q$,
  pg_temp.drg('DRG-0003'), pg_temp.fac('LAG-IKJ'), pg_temp.fac('LAG-LEK'), pg_temp.stf('ST-00012')), 'itoju_pharmacy');
SELECT pg_temp.check_case('privileges', 'a pharmacist cannot set stock levels directly', 'permission_denied',
  'UPDATE stock_on_hand SET quantity = 0', 'itoju_pharmacy');
SELECT pg_temp.check_case('privileges', 'a pharmacist cannot write the ledger directly', 'permission_denied', format($q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by) VALUES (%s, %s, 'ADJUST_IN', 10, %s)
  $q$, pg_temp.fac('LAG-IKJ'), pg_temp.drg('DRG-0002'), pg_temp.stf('ST-00012')), 'itoju_pharmacy');
SELECT pg_temp.check_case('privileges', 'a pharmacist cannot read patient identities', 'permission_denied',
  'SELECT * FROM patient_directory', 'itoju_pharmacy');

SELECT pg_temp.check_case('privileges', 'a lab scientist records a corrected result', 'ok', format($q$
  SELECT record_lab_result(%s, %s, 97, NULL, %s, 'Re-run on a fresh sample') $q$,
  pg_temp.ord('HN-0000001', 'LT-CREAT'), pg_temp.stf('ST-00015'),
  (SELECT lab_result_id FROM lab_result WHERE lab_order_id = pg_temp.ord('HN-0000001', 'LT-CREAT'))), 'itoju_lab');
SELECT pg_temp.check_case('privileges', 'a lab scientist cannot read clinical notes', 'permission_denied',
  'SELECT * FROM clinical_note', 'itoju_lab');
SELECT pg_temp.check_case('privileges', 'a lab scientist cannot read patient identities', 'permission_denied',
  'SELECT * FROM patient_directory', 'itoju_lab');

SELECT pg_temp.check_case('privileges', 'billing raises a balanced invoice', 'ok', format($q$
  WITH i AS (
    INSERT INTO invoice (invoice_no, patient_id, facility_id, issued_by, total_kobo)
    VALUES ('INV-' || lpad(nextval('invoice_no_seq')::text, 8, '0'), %s, %s, %s, 500000)
    RETURNING invoice_id)
  INSERT INTO invoice_line (invoice_id, line_no, description, quantity, unit_price_kobo)
  SELECT invoice_id, 1, 'Consultation', 1, 500000 FROM i $q$,
  pg_temp.pat('HN-0000002'), pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00019')), 'itoju_billing');
SELECT pg_temp.check_case('privileges', 'billing takes a payment', 'ok', format($q$
  INSERT INTO payment (invoice_id, payment_method_code, amount_kobo, received_by) VALUES (%s, 'CASH', 100000, %s) $q$,
  pg_temp.inv('HN-0000003', '2026-10-20'), pg_temp.stf('ST-00019')), 'itoju_billing');
SELECT pg_temp.check_case('privileges', 'billing cannot alter a payment', 'permission_denied',
  'UPDATE payment SET amount_kobo = 1', 'itoju_billing');
SELECT pg_temp.check_case('privileges', 'billing cannot read clinical notes', 'permission_denied',
  'SELECT * FROM clinical_note', 'itoju_billing');
SELECT pg_temp.check_case('privileges', 'billing reads patient names for invoices', 'ok',
  'SELECT hospital_no, given_name, family_name FROM patient_directory', 'itoju_billing');

SELECT pg_temp.check_case('privileges', 'an analyst reads de-identified encounters', 'ok',
  'SELECT * FROM deid_encounter', 'itoju_analyst');
SELECT pg_temp.check_case('privileges', 'an analyst reads de-identified patients', 'ok',
  'SELECT * FROM deid_patient', 'itoju_analyst');
SELECT pg_temp.check_case('privileges', 'an analyst cannot read the patient table', 'permission_denied',
  'SELECT * FROM patient', 'itoju_analyst');
SELECT pg_temp.check_case('privileges', 'an analyst cannot read the patient directory', 'permission_denied',
  'SELECT * FROM patient_directory', 'itoju_analyst');
SELECT pg_temp.check_case('privileges', 'an analyst cannot read the pseudonym key', 'permission_denied',
  'SELECT * FROM pseudonym_key', 'itoju_analyst');
SELECT pg_temp.check_case('privileges', 'an analyst cannot book appointments', 'permission_denied', format($q$
  SELECT book_appointment(%s, %s, %s, %s, '2026-11-17 14:00+01', 30) $q$,
  pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ')), 'itoju_analyst');

SELECT pg_temp.check_case('privileges', 'an auditor reads the access log', 'ok',
  'SELECT * FROM record_access_log', 'itoju_auditor');
SELECT pg_temp.check_case('privileges', 'an auditor reads patient identities', 'ok',
  'SELECT * FROM patient', 'itoju_auditor');
SELECT pg_temp.check_case('privileges', 'an auditor cannot change data', 'permission_denied',
  'DELETE FROM record_access_log', 'itoju_auditor');
SELECT pg_temp.check_case('privileges', 'an auditor cannot read the pseudonym key', 'permission_denied',
  'SELECT * FROM pseudonym_key', 'itoju_auditor');

SELECT pg_temp.check_case('privileges', 'the clinic application books an appointment', 'ok', format($q$
  SELECT book_appointment(%s, %s, %s, %s, '2026-11-17 15:00+01', 30) $q$,
  pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ')), 'itoju_app');
SELECT pg_temp.check_case('privileges', 'the clinic application cannot read clinical notes', 'permission_denied',
  'SELECT * FROM clinical_note', 'itoju_app');

SELECT pg_temp.check_case('privileges', 'no function in the schema is executable by PUBLIC', 'ok', $q$
  DO $d$
  BEGIN
    ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'itoju' AND has_function_privilege('public', p.oid, 'EXECUTE'));
  END $d$ $q$);
SELECT pg_temp.check_case('privileges', 'every SECURITY DEFINER function pins its search_path', 'ok', $q$
  DO $d$
  BEGIN
    ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'itoju' AND p.prosecdef
                          AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'));
  END $d$ $q$);
SELECT pg_temp.check_case('privileges', 'every itoju group role is NOLOGIN', 'ok', $q$
  DO $d$
  BEGIN
    ASSERT (SELECT count(*) FROM pg_roles WHERE rolname LIKE 'itoju\_%' AND NOT rolcanlogin) = 9;
    ASSERT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname LIKE 'itoju\_%' AND rolcanlogin);
  END $d$ $q$);
SELECT pg_temp.check_case('privileges', 'de-identified views expose no direct identifier', 'ok', $q$
  DO $d$
  BEGIN
    ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'itoju' AND table_name IN ('deid_patient', 'deid_encounter')
                          AND column_name IN ('patient_id', 'hospital_no', 'given_name', 'middle_name', 'family_name',
                                              'date_of_birth', 'national_id', 'address_line', 'phone_no'));
  END $d$ $q$);

\o
\ir report.sql
