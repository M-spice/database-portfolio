\ir harness.sql
\o /dev/null

SELECT pg_temp.check_case('constraints', 'valid facility is accepted', 'ok', $q$
  INSERT INTO facility (facility_code, name, city, state, opened_on)
  VALUES ('KAN-TAR', 'Itoju Clinics Tarauni', 'Kano', 'Kano', '2026-12-01') $q$);
SELECT pg_temp.check_case('constraints', 'facility code must look like AAA-AAA', 'facility_code_ck', $q$
  INSERT INTO facility (facility_code, name, city, state, opened_on)
  VALUES ('KANO1', 'Itoju Clinics Tarauni', 'Kano', 'Kano', '2026-12-01') $q$);
SELECT pg_temp.check_case('constraints', 'facility code is unique', 'facility_code_uk', $q$
  INSERT INTO facility (facility_code, name, city, state, opened_on)
  VALUES ('LAG-IKJ', 'Duplicate Ikeja', 'Lagos', 'Lagos', '2026-12-01') $q$);
SELECT pg_temp.check_case('constraints', 'staff role must be a known code', 'staff_role_fk', $q$
  INSERT INTO staff (staff_no, given_name, family_name, staff_role_code, home_facility_id, employed_on)
  VALUES ('ST-09001', 'Test', 'Person', 'SURGEON', pg_temp.fac('LAG-IKJ'), '2026-01-01') $q$);
SELECT pg_temp.check_case('constraints', 'leaving date cannot precede employment', 'staff_left_on_ck', $q$
  INSERT INTO staff (staff_no, given_name, family_name, staff_role_code, home_facility_id, employed_on, left_on)
  VALUES ('ST-09002', 'Test', 'Person', 'NURSE', pg_temp.fac('LAG-IKJ'), '2026-01-01', '2025-01-01') $q$);
SELECT pg_temp.check_case('constraints', 'only clinical staff can be clinicians', 'clinician_clinical_role_tg', $q$
  INSERT INTO clinician (clinician_id, licence_no) VALUES (pg_temp.stf('ST-00017'), 'LIC-999-00017') $q$);
SELECT pg_temp.check_case('constraints', 'licence number must use the synthetic format', 'clinician_licence_no_ck', $q$
  UPDATE clinician SET licence_no = 'MDCN-12345' WHERE clinician_id = pg_temp.stf('ST-00001') $q$);

SELECT pg_temp.check_case('constraints', 'valid patient is accepted', 'ok', $q$
  INSERT INTO patient (hospital_no, given_name, family_name, date_of_birth, address_line, address_city,
                       address_state, registered_facility_id)
  VALUES ('HN-0009001', 'Test', 'Patient', '2000-01-01', '1 Test Road', 'Ikeja', 'Lagos', pg_temp.fac('LAG-IKJ')) $q$);
SELECT pg_temp.check_case('constraints', 'hospital number must look like HN-0000000', 'patient_hospital_no_ck', $q$
  INSERT INTO patient (hospital_no, given_name, family_name, date_of_birth, address_line, address_city,
                       address_state, registered_facility_id)
  VALUES ('HN-12', 'Test', 'Patient', '2000-01-01', '1 Test Road', 'Ikeja', 'Lagos', pg_temp.fac('LAG-IKJ')) $q$);
SELECT pg_temp.check_case('constraints', 'hospital number is unique', 'patient_hospital_no_uk', $q$
  INSERT INTO patient (hospital_no, given_name, family_name, date_of_birth, address_line, address_city,
                       address_state, registered_facility_id)
  VALUES ('HN-0000001', 'Test', 'Patient', '2000-01-01', '1 Test Road', 'Ikeja', 'Lagos', pg_temp.fac('LAG-IKJ')) $q$);
SELECT pg_temp.check_case('constraints', 'national ID must be a synthetic 999 number', 'patient_national_id_ck', $q$
  INSERT INTO patient (hospital_no, given_name, family_name, date_of_birth, national_id, address_line,
                       address_city, address_state, registered_facility_id)
  VALUES ('HN-0009002', 'Test', 'Patient', '2000-01-01', '12345678901', '1 Test Road', 'Ikeja', 'Lagos',
          pg_temp.fac('LAG-IKJ')) $q$);
SELECT pg_temp.check_case('constraints', 'date of birth cannot be in the future', 'patient_date_of_birth_ck', $q$
  INSERT INTO patient (hospital_no, given_name, family_name, date_of_birth, address_line, address_city,
                       address_state, registered_facility_id)
  VALUES ('HN-0009003', 'Test', 'Patient', current_date + 1, '1 Test Road', 'Ikeja', 'Lagos', pg_temp.fac('LAG-IKJ')) $q$);
SELECT pg_temp.check_case('constraints', 'family name is required', 'not_null:family_name', $q$
  INSERT INTO patient (hospital_no, given_name, date_of_birth, address_line, address_city, address_state,
                       registered_facility_id)
  VALUES ('HN-0009004', 'Test', '2000-01-01', '1 Test Road', 'Ikeja', 'Lagos', pg_temp.fac('LAG-IKJ')) $q$);
SELECT pg_temp.check_case('constraints', 'phone numbers must be in the synthetic range', 'patient_phone_no_ck', $q$
  INSERT INTO patient_phone (patient_id, phone_no) VALUES (pg_temp.pat('HN-0000002'), '+2348031234567') $q$);
SELECT pg_temp.check_case('constraints', 'a patient has at most one primary phone', 'patient_phone_primary_uk', $q$
  INSERT INTO patient_phone (patient_id, phone_no, is_primary) VALUES (pg_temp.pat('HN-0000001'), '+2340001000999', true) $q$);
SELECT pg_temp.check_case('constraints', 'an allergy is recorded once per patient', 'patient_allergy_pk', $q$
  INSERT INTO patient_allergy (patient_id, allergen) VALUES (pg_temp.pat('HN-0000001'), 'Penicillin') $q$);
SELECT pg_temp.check_case('constraints', 'next-of-kin number is between 1 and 5', 'next_of_kin_kin_no_ck', $q$
  INSERT INTO next_of_kin (patient_id, kin_no, full_name, relationship, phone_no)
  VALUES (pg_temp.pat('HN-0000002'), 9, 'Ada Okoro', 'Sister', '+2340002000002') $q$);
SELECT pg_temp.check_case('constraints', 'only one open consent per purpose', 'consent_patient_purpose_open_uk', $q$
  INSERT INTO consent (patient_id, consent_purpose_code, granted_at, recorded_by)
  VALUES (pg_temp.pat('HN-0000001'), 'TREATMENT', now(), pg_temp.stf('ST-00017')) $q$);
SELECT pg_temp.check_case('constraints', 'consent cannot be withdrawn before it was given', 'consent_withdrawn_at_ck', $q$
  INSERT INTO consent (patient_id, consent_purpose_code, granted_at, withdrawn_at, recorded_by)
  VALUES (pg_temp.pat('HN-0000002'), 'SMS_REMINDERS', '2026-01-02', '2026-01-01', pg_temp.stf('ST-00017')) $q$);

SELECT pg_temp.check_case('constraints', 'valid appointment is accepted', 'ok', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
          '[2026-11-17 10:00+01, 2026-11-17 10:30+01)') $q$);
SELECT pg_temp.check_case('constraints', 'a clinician cannot be double-booked', 'appointment_clinician_slot_ex', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
          '[2026-11-17 09:15+01, 2026-11-17 09:45+01)') $q$);
SELECT pg_temp.check_case('constraints', 'a patient cannot be in two appointments at once', 'appointment_patient_slot_ex', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot)
  VALUES (pg_temp.pat('HN-0000001'), pg_temp.stf('ST-00008'), pg_temp.dep('GP'), pg_temp.fac('ABJ-GRK'),
          '[2026-11-17 09:00+01, 2026-11-17 09:30+01)') $q$);
SELECT pg_temp.check_case('constraints', 'a cancelled appointment frees its slot', 'ok', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00002'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
          '[2026-11-10 14:00+01, 2026-11-10 14:30+01)') $q$);
SELECT pg_temp.check_case('constraints', 'a slot lasts between 10 minutes and 2 hours', 'appointment_slot_ck', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
          '[2026-11-18 10:00+01, 2026-11-18 10:05+01)') $q$);
SELECT pg_temp.check_case('constraints', 'the clinician must work in the department', 'appointment_clinician_department_fk', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00003'), pg_temp.dep('GP'), pg_temp.fac('LAG-LEK'),
          '[2026-11-18 10:00+01, 2026-11-18 10:30+01)') $q$);
SELECT pg_temp.check_case('constraints', 'appointment status must be a known code', 'appointment_status_fk', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot, appointment_status_code)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
          '[2026-11-18 10:00+01, 2026-11-18 10:30+01)', 'PENDING') $q$);
SELECT pg_temp.check_case('constraints', 'a booking request key is used once', 'appointment_request_key_uk', $q$
  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot, request_key)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
          '[2026-11-18 10:00+01, 2026-11-18 10:30+01)', '00000000-0000-4000-8000-0000000000aa'),
         (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'), pg_temp.fac('LAG-IKJ'),
          '[2026-11-18 11:00+01, 2026-11-18 11:30+01)', '00000000-0000-4000-8000-0000000000aa') $q$);
SELECT pg_temp.check_case('constraints', 'status history is append-only', 'appointment_status_history_append_only_tg', $q$
  UPDATE appointment_status_history SET appointment_status_code = 'NO_SHOW' $q$);

SELECT pg_temp.check_case('constraints', 'an encounter cannot use another patient''s appointment', 'encounter_appointment_fk', $q$
  INSERT INTO encounter (patient_id, clinician_id, facility_id, appointment_id, encounter_type_code, started_at)
  SELECT pg_temp.pat('HN-0000002'), a.clinician_id, a.facility_id, a.appointment_id, 'CONSULTATION', lower(a.slot)
    FROM appointment a
   WHERE a.patient_id = pg_temp.pat('HN-0000001') AND lower(a.slot) = '2026-11-17 09:00+01' $q$);
SELECT pg_temp.check_case('constraints', 'an appointment leads to at most one encounter', 'encounter_appointment_uk', $q$
  INSERT INTO encounter (patient_id, clinician_id, facility_id, appointment_id, encounter_type_code, started_at)
  SELECT e.patient_id, e.clinician_id, e.facility_id, e.appointment_id, 'CONSULTATION', e.started_at
    FROM encounter e WHERE e.encounter_id = pg_temp.enc('HN-0000001', '2026-10-05') $q$);
SELECT pg_temp.check_case('constraints', 'an encounter cannot end before it starts', 'encounter_ended_at_ck', $q$
  INSERT INTO encounter (patient_id, clinician_id, facility_id, encounter_type_code, started_at, ended_at)
  VALUES (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.fac('LAG-IKJ'), 'WALK_IN',
          '2026-11-13 10:00+01', '2026-11-13 09:00+01') $q$);
SELECT pg_temp.check_case('constraints', 'a vital-sign row records at least one measurement', 'vital_sign_any_ck', $q$
  INSERT INTO vital_sign (encounter_id, recorded_at, recorded_by)
  VALUES (pg_temp.enc('HN-0000001', '2026-10-05'), now(), pg_temp.stf('ST-00009')) $q$);
SELECT pg_temp.check_case('constraints', 'systolic pressure must exceed diastolic', 'vital_sign_blood_pressure_ck', $q$
  INSERT INTO vital_sign (encounter_id, recorded_at, recorded_by, systolic_mmhg, diastolic_mmhg)
  VALUES (pg_temp.enc('HN-0000001', '2026-10-05'), now(), pg_temp.stf('ST-00009'), 80, 90) $q$);
SELECT pg_temp.check_case('constraints', 'oxygen saturation cannot exceed 100 per cent', 'vital_sign_spo2_pct_ck', $q$
  INSERT INTO vital_sign (encounter_id, recorded_at, recorded_by, spo2_pct)
  VALUES (pg_temp.enc('HN-0000001', '2026-10-05'), now(), pg_temp.stf('ST-00009'), 120) $q$);
SELECT pg_temp.check_case('constraints', 'an encounter has one primary diagnosis', 'encounter_diagnosis_primary_uk', $q$
  INSERT INTO encounter_diagnosis (encounter_id, diagnosis_code, is_primary)
  VALUES (pg_temp.enc('HN-0000003', '2026-10-20'), 'E78.5', true) $q$);
SELECT pg_temp.check_case('constraints', 'diagnosis must be a catalogued code', 'encounter_diagnosis_diagnosis_fk', $q$
  INSERT INTO encounter_diagnosis (encounter_id, diagnosis_code) VALUES (pg_temp.enc('HN-0000003', '2026-10-20'), 'Q99.9') $q$);
SELECT pg_temp.check_case('constraints', 'a clinical note cannot be edited', 'clinical_note_append_only_tg', $q$
  UPDATE clinical_note SET body = 'edited' WHERE encounter_id = pg_temp.enc('HN-0000001', '2026-10-05') $q$);
SELECT pg_temp.check_case('constraints', 'a clinical note cannot be deleted', 'clinical_note_append_only_tg', $q$
  DELETE FROM clinical_note WHERE encounter_id = pg_temp.enc('HN-0000001', '2026-10-05') $q$);
SELECT pg_temp.check_case('constraints', 'an amendment must give a reason', 'clinical_note_amendment_ck', $q$
  INSERT INTO clinical_note (encounter_id, author_id, body, amends_note_id)
  SELECT n.encounter_id, n.author_id, 'Corrected dose', n.clinical_note_id
    FROM clinical_note n WHERE n.encounter_id = pg_temp.enc('HN-0000001', '2026-10-05') $q$);
SELECT pg_temp.check_case('constraints', 'an amendment stays within its encounter', 'clinical_note_amends_fk', $q$
  INSERT INTO clinical_note (encounter_id, author_id, body, amends_note_id, amendment_reason)
  SELECT pg_temp.enc('HN-0000004', '2026-10-12'), n.author_id, 'Corrected dose', n.clinical_note_id, 'Wrong dose'
    FROM clinical_note n WHERE n.encounter_id = pg_temp.enc('HN-0000001', '2026-10-05') $q$);
SELECT pg_temp.check_case('constraints', 'a valid amendment is accepted', 'ok', $q$
  INSERT INTO clinical_note (encounter_id, author_id, body, amends_note_id, amendment_reason)
  SELECT n.encounter_id, n.author_id, 'Paracetamol dose is 1 g, not 2 g', n.clinical_note_id, 'Dose mistyped'
    FROM clinical_note n WHERE n.encounter_id = pg_temp.enc('HN-0000001', '2026-10-05') $q$);

SELECT pg_temp.check_case('constraints', 'stock can never go negative', 'stock_on_hand_quantity_ck', $q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by, prescription_id)
  VALUES (pg_temp.fac('LAG-SUR'), pg_temp.drg('DRG-0004'), 'DISPENSE', 30, pg_temp.stf('ST-00012'),
          pg_temp.rx('HN-0000001', '2026-11-09')) $q$);
SELECT pg_temp.check_case('constraints', 'stock on hand changes only through the ledger', 'stock_on_hand_ledger_only_tg', $q$
  UPDATE stock_on_hand SET quantity = quantity + 1000 WHERE facility_id = pg_temp.fac('LAG-IKJ') $q$);
SELECT pg_temp.check_case('constraints', 'a dispense must cite a prescription item', 'stock_movement_prescription_tg', $q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by)
  VALUES (pg_temp.fac('LAG-IKJ'), pg_temp.drg('DRG-0002'), 'DISPENSE', 5, pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('constraints', 'a receipt must not cite a prescription', 'stock_movement_prescription_tg', $q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by, prescription_id)
  VALUES (pg_temp.fac('LAG-IKJ'), pg_temp.drg('DRG-0004'), 'RECEIPT', 30, pg_temp.stf('ST-00012'),
          pg_temp.rx('HN-0000001', '2026-11-09')) $q$);
SELECT pg_temp.check_case('constraints', 'a movement quantity is positive', 'stock_movement_quantity_ck', $q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by)
  VALUES (pg_temp.fac('LAG-IKJ'), pg_temp.drg('DRG-0002'), 'RECEIPT', 0, pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('constraints', 'a transfer needs both legs by commit', 'stock_movement_transfer_pair_tg', $q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by, transfer_ref)
  VALUES (pg_temp.fac('LAG-IKJ'), pg_temp.drg('DRG-0002'), 'TRANSFER_OUT', 50, pg_temp.stf('ST-00012'),
          '00000000-0000-4000-8000-0000000000bb') $q$);
SELECT pg_temp.check_case('constraints', 'a transfer leg needs a transfer reference', 'stock_movement_transfer_ref_tg', $q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by)
  VALUES (pg_temp.fac('LAG-LEK'), pg_temp.drg('DRG-0002'), 'TRANSFER_IN', 50, pg_temp.stf('ST-00012')) $q$);
SELECT pg_temp.check_case('constraints', 'the stock ledger is append-only', 'stock_movement_append_only_tg', $q$
  UPDATE stock_movement SET quantity = 1 WHERE movement_type_code = 'RECEIPT' $q$);
SELECT pg_temp.check_case('constraints', 'a prescription item is dispensed once', 'stock_movement_prescription_item_uk', $q$
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by, prescription_id)
  VALUES (pg_temp.fac('LAG-IKJ'), pg_temp.drg('DRG-0001'), 'DISPENSE', 24, pg_temp.stf('ST-00012'),
          pg_temp.rx('HN-0000001', '2026-10-05')) $q$);
SELECT pg_temp.check_case('constraints', 'a prescribed quantity is at least 1', 'prescription_item_quantity_ck', $q$
  INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage)
  VALUES (pg_temp.rx('HN-0000001', '2026-11-09'), pg_temp.drg('DRG-0002'), 0, 'as needed') $q$);

SELECT pg_temp.check_case('constraints', 'a test is ordered only where there is a laboratory', 'lab_order_facility_laboratory_tg', $q$
  INSERT INTO lab_order (encounter_id, lab_test_id, facility_id, ordered_by)
  VALUES (pg_temp.enc('HN-0000001', '2026-10-05'), pg_temp.lab('LT-HB'), pg_temp.fac('LAG-SUR'), pg_temp.stf('ST-00001')) $q$);
SELECT pg_temp.check_case('constraints', 'a qualitative test takes a text result', 'lab_result_value_kind_tg', $q$
  DO $d$
  DECLARE o bigint;
  BEGIN
    INSERT INTO lab_order (encounter_id, lab_test_id, facility_id, ordered_by, ordered_at)
    VALUES (pg_temp.enc('HN-0000005', '2026-11-11'), pg_temp.lab('LT-URINE'), pg_temp.fac('ENU-IND'),
            pg_temp.stf('ST-00006'), '2026-11-11 10:20+01')
    RETURNING lab_order_id INTO o;
    INSERT INTO lab_result (lab_order_id, recorded_at, recorded_by, value_numeric)
    VALUES (o, '2026-11-11 11:00+01', pg_temp.stf('ST-00016'), 5);
  END $d$ $q$);
SELECT pg_temp.check_case('constraints', 'a result holds exactly one value', 'lab_result_value_ck', $q$
  INSERT INTO lab_result (lab_order_id, recorded_by, value_numeric, value_text)
  VALUES (pg_temp.ord('HN-0000001', 'LT-CREAT'), pg_temp.stf('ST-00015'), 99, 'normal') $q$);
SELECT pg_temp.check_case('constraints', 'an order has one original result', 'lab_result_order_original_uk', $q$
  INSERT INTO lab_result (lab_order_id, recorded_by, value_numeric)
  VALUES (pg_temp.ord('HN-0000001', 'LT-CREAT'), pg_temp.stf('ST-00015'), 100) $q$);
SELECT pg_temp.check_case('constraints', 'a correction must give a reason', 'lab_result_correction_ck', $q$
  INSERT INTO lab_result (lab_order_id, recorded_by, value_numeric, supersedes_result_id)
  SELECT r.lab_order_id, r.recorded_by, 97, r.lab_result_id
    FROM lab_result r WHERE r.lab_order_id = pg_temp.ord('HN-0000001', 'LT-CREAT') $q$);
SELECT pg_temp.check_case('constraints', 'a lab result cannot be edited', 'lab_result_append_only_tg', $q$
  UPDATE lab_result SET value_numeric = 1 WHERE lab_order_id = pg_temp.ord('HN-0000001', 'LT-CREAT') $q$);
SELECT pg_temp.check_case('constraints', 'a result cannot predate its order', 'lab_result_after_order_tg', $q$
  INSERT INTO lab_result (lab_order_id, recorded_at, recorded_by, value_numeric, supersedes_result_id, correction_reason)
  SELECT r.lab_order_id, '2026-01-01', r.recorded_by, 97, r.lab_result_id, 'Re-run'
    FROM lab_result r WHERE r.lab_order_id = pg_temp.ord('HN-0000001', 'LT-CREAT') $q$);
SELECT pg_temp.check_case('constraints', 'a reference range runs low to high', 'lab_test_reference_range_ck', $q$
  INSERT INTO lab_test (test_code, name, specimen, unit, reference_low, reference_high, price_kobo, target_turnaround)
  VALUES ('LT-TRIG', 'Triglycerides', 'Blood', 'mmol/L', 1.7, 0.5, 300000, '24 hours') $q$);

SELECT pg_temp.check_case('constraints', 'an invoice total must equal its lines', 'invoice_total_tg', $q$
  INSERT INTO invoice (invoice_no, patient_id, facility_id, issued_by, total_kobo)
  VALUES ('INV-09000001', pg_temp.pat('HN-0000002'), pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00019'), 100000) $q$);
SELECT pg_temp.check_case('constraints', 'a balanced invoice is accepted', 'ok', $q$
  WITH i AS (
    INSERT INTO invoice (invoice_no, patient_id, facility_id, issued_by, total_kobo)
    VALUES ('INV-09000002', pg_temp.pat('HN-0000002'), pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00019'), 520000)
    RETURNING invoice_id)
  INSERT INTO invoice_line (invoice_id, line_no, description, drug_id, quantity, unit_price_kobo)
  SELECT invoice_id, 1, 'Consultation', NULL, 1, 500000 FROM i
  UNION ALL
  SELECT invoice_id, 2, 'Paracetamol 500 mg tablet', pg_temp.drg('DRG-0002'), 10, 2000 FROM i $q$);
SELECT pg_temp.check_case('constraints', 'a payment cannot exceed the amount outstanding', 'payment_outstanding_tg', $q$
  INSERT INTO payment (invoice_id, payment_method_code, amount_kobo, received_by)
  SELECT i.invoice_id, 'CASH', i.total_kobo, pg_temp.stf('ST-00019')
    FROM invoice i WHERE i.invoice_id = pg_temp.inv('HN-0000003', '2026-10-20') $q$);
SELECT pg_temp.check_case('constraints', 'an HMO payment needs a claim reference', 'payment_reference_tg', $q$
  INSERT INTO payment (invoice_id, payment_method_code, amount_kobo, received_by)
  VALUES (pg_temp.inv('HN-0000003', '2026-10-20'), 'HMO', 1000, pg_temp.stf('ST-00019')) $q$);
SELECT pg_temp.check_case('constraints', 'a payment cannot be deleted', 'payment_append_only_tg', $q$
  DELETE FROM payment WHERE invoice_id = pg_temp.inv('HN-0000001', '2026-10-05') $q$);
SELECT pg_temp.check_case('constraints', 'an invoice price cannot be negative', 'invoice_line_unit_price_kobo_ck', $q$
  INSERT INTO invoice_line (invoice_id, line_no, description, quantity, unit_price_kobo)
  VALUES (pg_temp.inv('HN-0000001', '2026-11-09'), 9, 'Discount', 1, -10000) $q$);
SELECT pg_temp.check_case('constraints', 'an invoice line is a drug, a test or neither', 'invoice_line_item_ck', $q$
  INSERT INTO invoice_line (invoice_id, line_no, description, drug_id, lab_test_id, quantity, unit_price_kobo)
  VALUES (pg_temp.inv('HN-0000001', '2026-11-09'), 9, 'Mixed', pg_temp.drg('DRG-0002'), pg_temp.lab('LT-HB'), 1, 1000) $q$);
SELECT pg_temp.check_case('constraints', 'an invoice cannot bill another patient''s encounter', 'invoice_encounter_fk', $q$
  WITH e AS (
    INSERT INTO encounter (patient_id, clinician_id, facility_id, encounter_type_code, started_at)
    VALUES (pg_temp.pat('HN-0000001'), pg_temp.stf('ST-00001'), pg_temp.fac('LAG-IKJ'), 'WALK_IN', '2026-11-13 12:00+01')
    RETURNING encounter_id)
  INSERT INTO invoice (invoice_no, patient_id, facility_id, encounter_id, issued_by, total_kobo)
  SELECT 'INV-09000003', pg_temp.pat('HN-0000002'), pg_temp.fac('LAG-IKJ'), encounter_id, pg_temp.stf('ST-00019'), 0 FROM e $q$);

SELECT pg_temp.check_case('constraints', 'the access log is append-only', 'record_access_log_append_only_tg', $q$
  DELETE FROM record_access_log $q$);
SELECT pg_temp.check_case('constraints', 'a clinician appears once per facility rota per night', 'on_call_shift_facility_clinician_date_uk', $q$
  INSERT INTO on_call_shift (facility_id, clinician_id, shift_date)
  VALUES (pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00001'), '2026-11-14') $q$);

\o
\ir report.sql
