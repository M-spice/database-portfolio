SET ROLE itoju_owner;
SET search_path = itoju, public;

CREATE FUNCTION pg_temp.fac(p_code text) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT facility_id FROM itoju.facility WHERE facility_code = p_code $$;
CREATE FUNCTION pg_temp.dep(p_code text) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT department_id FROM itoju.department WHERE department_code = p_code $$;
CREATE FUNCTION pg_temp.stf(p_no text) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT staff_id FROM itoju.staff WHERE staff_no = p_no $$;
CREATE FUNCTION pg_temp.pat(p_no text) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT patient_id FROM itoju.patient WHERE hospital_no = p_no $$;
CREATE FUNCTION pg_temp.drg(p_code text) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT drug_id FROM itoju.drug WHERE drug_code = p_code $$;
CREATE FUNCTION pg_temp.lab(p_code text) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT lab_test_id FROM itoju.lab_test WHERE test_code = p_code $$;
CREATE FUNCTION pg_temp.set_status(p_appointment bigint, p_status text, p_at timestamptz, p_staff bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('itoju.event_time', p_at::text, true);
  PERFORM set_config('itoju.staff_id', p_staff::text, true);
  UPDATE itoju.appointment SET appointment_status_code = p_status WHERE appointment_id = p_appointment;
  PERFORM set_config('itoju.event_time', '', true);
END $$;

INSERT INTO staff_role (staff_role_code, description, is_clinical) VALUES
  ('RECEPTIONIST',    'Front-desk registration and booking', false),
  ('DOCTOR',          'Medical doctor',                      true),
  ('NURSE',           'Nurse',                               true),
  ('PHARMACIST',      'Branch pharmacist',                   false),
  ('LAB_SCIENTIST',   'Medical laboratory scientist',        false),
  ('BILLING_OFFICER', 'Invoicing and payments',              false),
  ('RECORDS_OFFICER', 'Medical records and data protection', false),
  ('ANALYST',         'Reporting on de-identified data',     false),
  ('AUDITOR',         'Internal audit, read only',           false);

INSERT INTO consent_purpose (consent_purpose_code, description) VALUES
  ('TREATMENT',             'Processing health data to provide care'),
  ('SMS_REMINDERS',         'Appointment reminders by text message'),
  ('DEIDENTIFIED_RESEARCH', 'Use of de-identified data for service research');

INSERT INTO appointment_status (appointment_status_code, description) VALUES
  ('BOOKED',     'Booked and not yet attended'),
  ('CHECKED_IN', 'Patient has arrived'),
  ('COMPLETED',  'Seen by the clinician'),
  ('CANCELLED',  'Cancelled; the slot is free again'),
  ('NO_SHOW',    'Patient did not attend');

INSERT INTO encounter_type (encounter_type_code, description) VALUES
  ('CONSULTATION', 'Booked consultation'),
  ('FOLLOW_UP',    'Follow-up of an earlier consultation'),
  ('WALK_IN',      'Unbooked walk-in visit'),
  ('TELECONSULT',  'Remote consultation');

INSERT INTO movement_type (movement_type_code, description, direction, requires_prescription, requires_transfer_ref) VALUES
  ('RECEIPT',      'Delivery from a supplier',           1, false, false),
  ('DISPENSE',     'Dispensed against a prescription',  -1, true,  false),
  ('TRANSFER_OUT', 'Sent to another branch',            -1, false, true),
  ('TRANSFER_IN',  'Received from another branch',       1, false, true),
  ('ADJUST_IN',    'Stock-take gain',                    1, false, false),
  ('ADJUST_OUT',   'Stock-take loss, expiry or damage', -1, false, false);

INSERT INTO payment_method (payment_method_code, description, requires_reference) VALUES
  ('CASH',     'Cash at the till',           false),
  ('CARD',     'Debit or credit card',       true),
  ('HMO',      'Health maintenance organisation claim', true),
  ('TRANSFER', 'Bank transfer',              true);

INSERT INTO facility (facility_code, name, city, state, has_laboratory, opened_on) VALUES
  ('LAG-IKJ', 'Itoju Clinics Ikeja',               'Lagos',  'Lagos', true,  '2012-03-01'),
  ('LAG-LEK', 'Itoju Clinics Lekki',               'Lagos',  'Lagos', true,  '2015-06-15'),
  ('LAG-YAB', 'Itoju Clinics Yaba',                'Lagos',  'Lagos', true,  '2016-01-11'),
  ('LAG-SUR', 'Itoju Clinics Surulere',            'Lagos',  'Lagos', false, '2019-09-02'),
  ('ABJ-GRK', 'Itoju Clinics Garki',               'Abuja',  'FCT',   true,  '2014-04-07'),
  ('ABJ-WUS', 'Itoju Clinics Wuse',                'Abuja',  'FCT',   true,  '2017-10-23'),
  ('ABJ-GWA', 'Itoju Clinics Gwarinpa',            'Abuja',  'FCT',   true,  '2021-02-01'),
  ('IBD-BOD', 'Itoju Clinics Bodija',              'Ibadan', 'Oyo',   true,  '2016-08-08'),
  ('IBD-RRD', 'Itoju Clinics Ring Road',           'Ibadan', 'Oyo',   false, '2022-05-16'),
  ('ENU-IND', 'Itoju Clinics Independence Layout', 'Enugu',  'Enugu', true,  '2018-03-12'),
  ('ENU-NHV', 'Itoju Clinics New Haven',           'Enugu',  'Enugu', false, '2023-01-09'),
  ('KAN-NAS', 'Itoju Clinics Nassarawa',           'Kano',   'Kano',  true,  '2020-11-02');

INSERT INTO department (department_code, name) VALUES
  ('GP',    'General Practice'),
  ('PAED',  'Paediatrics'),
  ('OBGYN', 'Obstetrics and Gynaecology'),
  ('IM',    'Internal Medicine'),
  ('DERM',  'Dermatology'),
  ('OPHTH', 'Ophthalmology');

INSERT INTO staff (staff_no, given_name, family_name, staff_role_code, home_facility_id, employed_on, left_on) VALUES
  ('ST-00001', 'Adaeze',    'Okafor',    'DOCTOR',          pg_temp.fac('LAG-IKJ'), '2018-02-01', NULL),
  ('ST-00002', 'Babatunde', 'Adeyemi',   'DOCTOR',          pg_temp.fac('LAG-IKJ'), '2016-07-11', NULL),
  ('ST-00003', 'Chiamaka',  'Eze',       'DOCTOR',          pg_temp.fac('LAG-LEK'), '2019-01-14', NULL),
  ('ST-00004', 'Ibrahim',   'Musa',      'DOCTOR',          pg_temp.fac('KAN-NAS'), '2020-11-02', NULL),
  ('ST-00005', 'Funmilayo', 'Ogunleye',  'DOCTOR',          pg_temp.fac('IBD-BOD'), '2017-09-18', NULL),
  ('ST-00006', 'Emeka',     'Nwosu',     'DOCTOR',          pg_temp.fac('ENU-IND'), '2021-05-10', NULL),
  ('ST-00007', 'Zainab',    'Bello',     'DOCTOR',          pg_temp.fac('ABJ-GRK'), '2018-11-05', NULL),
  ('ST-00008', 'Tunde',     'Bakare',    'DOCTOR',          pg_temp.fac('ABJ-GRK'), '2015-04-20', NULL),
  ('ST-00009', 'Ngozi',     'Obi',       'NURSE',           pg_temp.fac('LAG-IKJ'), '2019-06-03', NULL),
  ('ST-00010', 'Aisha',     'Lawal',     'NURSE',           pg_temp.fac('ABJ-GRK'), '2020-08-17', NULL),
  ('ST-00011', 'Segun',     'Akande',    'NURSE',           pg_temp.fac('IBD-BOD'), '2022-01-10', NULL),
  ('ST-00012', 'Kemi',      'Adebayo',   'PHARMACIST',      pg_temp.fac('LAG-IKJ'), '2017-03-06', NULL),
  ('ST-00013', 'Uchenna',   'Okeke',     'PHARMACIST',      pg_temp.fac('ABJ-GRK'), '2018-05-21', NULL),
  ('ST-00014', 'Halima',    'Sani',      'PHARMACIST',      pg_temp.fac('KAN-NAS'), '2020-11-02', NULL),
  ('ST-00015', 'Bola',      'Ajayi',     'LAB_SCIENTIST',   pg_temp.fac('LAG-IKJ'), '2016-02-15', NULL),
  ('ST-00016', 'Obinna',    'Chukwu',    'LAB_SCIENTIST',   pg_temp.fac('ENU-IND'), '2018-03-12', NULL),
  ('ST-00017', 'Yetunde',   'Alabi',     'RECEPTIONIST',    pg_temp.fac('LAG-IKJ'), '2021-07-01', NULL),
  ('ST-00018', 'Musa',      'Abdullahi', 'RECEPTIONIST',    pg_temp.fac('ABJ-GRK'), '2022-09-12', NULL),
  ('ST-00019', 'Ifeoma',    'Nnaji',     'BILLING_OFFICER', pg_temp.fac('LAG-IKJ'), '2019-10-07', NULL),
  ('ST-00020', 'Dapo',      'Olatunji',  'BILLING_OFFICER', pg_temp.fac('ABJ-GRK'), '2020-01-20', NULL),
  ('ST-00021', 'Grace',     'Etim',      'RECORDS_OFFICER', pg_temp.fac('LAG-IKJ'), '2017-06-26', NULL),
  ('ST-00022', 'Sola',      'Ige',       'ANALYST',         pg_temp.fac('LAG-IKJ'), '2023-02-13', NULL),
  ('ST-00023', 'Fatima',    'Yusuf',     'AUDITOR',         pg_temp.fac('ABJ-GRK'), '2021-04-19', NULL),
  ('ST-00024', 'Peter',     'Okon',      'DOCTOR',          pg_temp.fac('LAG-YAB'), '2014-01-06', '2025-12-31');

INSERT INTO clinician (clinician_id, licence_no)
SELECT s.staff_id, 'LIC-999-' || substr(s.staff_no, 4)
  FROM staff s JOIN staff_role r USING (staff_role_code)
 WHERE r.is_clinical;

INSERT INTO clinician_department (clinician_id, department_id, assigned_on) VALUES
  (pg_temp.stf('ST-00001'), pg_temp.dep('GP'),    '2018-02-01'),
  (pg_temp.stf('ST-00001'), pg_temp.dep('IM'),    '2020-01-06'),
  (pg_temp.stf('ST-00002'), pg_temp.dep('GP'),    '2016-07-11'),
  (pg_temp.stf('ST-00003'), pg_temp.dep('PAED'),  '2019-01-14'),
  (pg_temp.stf('ST-00004'), pg_temp.dep('GP'),    '2020-11-02'),
  (pg_temp.stf('ST-00004'), pg_temp.dep('IM'),    '2020-11-02'),
  (pg_temp.stf('ST-00005'), pg_temp.dep('OBGYN'), '2017-09-18'),
  (pg_temp.stf('ST-00006'), pg_temp.dep('GP'),    '2021-05-10'),
  (pg_temp.stf('ST-00007'), pg_temp.dep('IM'),    '2018-11-05'),
  (pg_temp.stf('ST-00007'), pg_temp.dep('DERM'),  '2022-03-01'),
  (pg_temp.stf('ST-00008'), pg_temp.dep('GP'),    '2015-04-20'),
  (pg_temp.stf('ST-00009'), pg_temp.dep('GP'),    '2019-06-03'),
  (pg_temp.stf('ST-00010'), pg_temp.dep('PAED'),  '2020-08-17'),
  (pg_temp.stf('ST-00011'), pg_temp.dep('GP'),    '2022-01-10'),
  (pg_temp.stf('ST-00024'), pg_temp.dep('GP'),    '2014-01-06');

INSERT INTO patient (hospital_no, given_name, middle_name, family_name, date_of_birth, national_id,
                     address_line, address_city, address_state, registered_facility_id, registered_at) VALUES
  ('HN-0000001', 'Oluwaseun', 'Adewale', 'Bankole',   '1978-04-12', '99900000001', '14 Allen Avenue',        'Ikeja',    'Lagos', pg_temp.fac('LAG-IKJ'), '2024-01-15 09:12+01'),
  ('HN-0000002', 'Chinonso',  NULL,      'Okoro',     '1990-09-30', '99900000002', '7 Admiralty Way',        'Lekki',    'Lagos', pg_temp.fac('LAG-LEK'), '2024-03-02 11:40+01'),
  ('HN-0000003', 'Amina',     'Hauwa',   'Garba',     '1985-02-14', '99900000003', '22 Zoo Road',            'Kano',     'Kano',  pg_temp.fac('KAN-NAS'), '2024-05-20 10:05+01'),
  ('HN-0000004', 'Tolulope',  NULL,      'Adeniran',  '2019-06-01', NULL,          '3 Opebi Road',           'Ikeja',    'Lagos', pg_temp.fac('LAG-LEK'), '2024-06-11 08:55+01'),
  ('HN-0000005', 'Ebuka',     'Nnamdi',  'Eze',       '1960-11-20', '99900000005', '15 Ogui Road',           'Enugu',    'Enugu', pg_temp.fac('ENU-IND'), '2024-07-01 13:20+01'),
  ('HN-0000006', 'Rukayat',   NULL,      'Salami',    '1972-03-08', '99900000006', '40 Bodija Market Road',  'Ibadan',   'Oyo',   pg_temp.fac('IBD-BOD'), '2024-08-19 09:30+01'),
  ('HN-0000007', 'Daniel',    NULL,      'Udo',       '1999-12-25', '99900000007', '5 Ahmadu Bello Way',     'Garki',    'FCT',   pg_temp.fac('ABJ-GRK'), '2024-09-09 15:10+01'),
  ('HN-0000008', 'Folake',    'Abike',   'Odunsi',    '1955-07-07', '99900000008', '12 Herbert Macaulay Way','Yaba',     'Lagos', pg_temp.fac('LAG-YAB'), '2024-10-14 10:45+01'),
  ('HN-0000009', 'Ifeanyi',   NULL,      'Okonkwo',   '2015-03-03', NULL,          '9 Zik Avenue',           'Enugu',    'Enugu', pg_temp.fac('ENU-IND'), '2025-01-06 12:00+01'),
  ('HN-0000010', 'Hadiza',    NULL,      'Umar',      '1988-08-18', '99900000010', '31 Aminu Kano Crescent', 'Wuse',     'FCT',   pg_temp.fac('ABJ-WUS'), '2025-02-24 14:25+01'),
  ('HN-0000011', 'Kayode',    'Femi',    'Oyelaran',  '1945-01-30', '99900000011', '18 Ring Road',           'Ibadan',   'Oyo',   pg_temp.fac('IBD-BOD'), '2025-04-07 09:05+01'),
  ('HN-0000012', 'Nkechi',    NULL,      'Agu',       '2001-05-05', '99900000012', '27 Adeniran Ogunsanya Street', 'Surulere', 'Lagos', pg_temp.fac('LAG-SUR'), '2025-06-30 16:40+01');

SELECT setval('patient_hospital_no_seq', 12);

INSERT INTO patient_phone (patient_id, phone_no, is_primary) VALUES
  (pg_temp.pat('HN-0000001'), '+2340001000001', true),
  (pg_temp.pat('HN-0000001'), '+2340001000101', false),
  (pg_temp.pat('HN-0000002'), '+2340001000002', true),
  (pg_temp.pat('HN-0000003'), '+2340001000003', true),
  (pg_temp.pat('HN-0000004'), '+2340001000004', true),
  (pg_temp.pat('HN-0000005'), '+2340001000005', true),
  (pg_temp.pat('HN-0000005'), '+2340001000105', false),
  (pg_temp.pat('HN-0000006'), '+2340001000006', true),
  (pg_temp.pat('HN-0000007'), '+2340001000007', true),
  (pg_temp.pat('HN-0000008'), '+2340001000008', true),
  (pg_temp.pat('HN-0000009'), '+2340001000005', true),
  (pg_temp.pat('HN-0000010'), '+2340001000010', true),
  (pg_temp.pat('HN-0000011'), '+2340001000011', true),
  (pg_temp.pat('HN-0000012'), '+2340001000012', true);

INSERT INTO patient_allergy (patient_id, allergen, reaction, recorded_at) VALUES
  (pg_temp.pat('HN-0000001'), 'Penicillin',   'Rash',            '2024-01-15 09:20+01'),
  (pg_temp.pat('HN-0000001'), 'Sulfonamides', 'Hives',           '2024-01-15 09:20+01'),
  (pg_temp.pat('HN-0000005'), 'Aspirin',      'Wheeze',          '2024-07-01 13:30+01'),
  (pg_temp.pat('HN-0000008'), 'Penicillin',   'Facial swelling', '2024-10-14 10:50+01'),
  (pg_temp.pat('HN-0000011'), 'Latex',        'Contact rash',    '2025-04-07 09:15+01');

INSERT INTO next_of_kin (patient_id, kin_no, full_name, relationship, phone_no) VALUES
  (pg_temp.pat('HN-0000001'), 1, 'Bisi Bankole',     'Spouse', '+2340002000001'),
  (pg_temp.pat('HN-0000004'), 1, 'Funke Adeniran',   'Mother', '+2340002000004'),
  (pg_temp.pat('HN-0000004'), 2, 'Wale Adeniran',    'Father', '+2340002000104'),
  (pg_temp.pat('HN-0000009'), 1, 'Chika Okonkwo',    'Mother', '+2340002000009'),
  (pg_temp.pat('HN-0000011'), 1, 'Jide Oyelaran',    'Son',    '+2340002000011');

INSERT INTO consent (patient_id, consent_purpose_code, granted_at, withdrawn_at, recorded_by)
SELECT p.patient_id, 'TREATMENT', p.registered_at, NULL, pg_temp.stf('ST-00017')
  FROM patient p;

INSERT INTO consent (patient_id, consent_purpose_code, granted_at, withdrawn_at, recorded_by) VALUES
  (pg_temp.pat('HN-0000001'), 'SMS_REMINDERS',         '2024-01-15 09:15+01', NULL,                  pg_temp.stf('ST-00017')),
  (pg_temp.pat('HN-0000003'), 'SMS_REMINDERS',         '2024-05-20 10:10+01', '2025-02-01 08:00+01', pg_temp.stf('ST-00018')),
  (pg_temp.pat('HN-0000003'), 'DEIDENTIFIED_RESEARCH', '2024-05-20 10:10+01', NULL,                  pg_temp.stf('ST-00018')),
  (pg_temp.pat('HN-0000007'), 'SMS_REMINDERS',         '2024-09-09 15:15+01', NULL,                  pg_temp.stf('ST-00018'));

INSERT INTO diagnosis_code (diagnosis_code, description, is_chronic) VALUES
  ('A01.0', 'Typhoid fever',                              false),
  ('A09',   'Gastroenteritis',                            false),
  ('B50.0', 'Malaria, severe',                            false),
  ('B54',   'Malaria, uncomplicated',                     false),
  ('D50.9', 'Iron deficiency anaemia',                    false),
  ('E11.9', 'Type 2 diabetes mellitus',                   true),
  ('E78.5', 'Hyperlipidaemia',                            true),
  ('H10.9', 'Conjunctivitis',                             false),
  ('I10',   'Essential hypertension',                     true),
  ('J06.9', 'Acute upper respiratory infection',          false),
  ('J45.9', 'Asthma',                                     true),
  ('K29.7', 'Gastritis',                                  false),
  ('L30.9', 'Dermatitis',                                 false),
  ('M54.5', 'Low back pain',                              false),
  ('N39.0', 'Urinary tract infection',                    false),
  ('Z34.9', 'Antenatal review, normal pregnancy',         false);

INSERT INTO drug (drug_code, name, form, strength, unit_price_kobo, reorder_level) VALUES
  ('DRG-0001', 'Artemether-lumefantrine', 'tablet',  '20 mg/120 mg',    15000, 600),
  ('DRG-0002', 'Paracetamol',             'tablet',  '500 mg',           2000, 1000),
  ('DRG-0003', 'Amoxicillin',             'capsule', '500 mg',           8000, 500),
  ('DRG-0004', 'Amlodipine',              'tablet',  '5 mg',             5000, 400),
  ('DRG-0005', 'Metformin',               'tablet',  '500 mg',           4000, 600),
  ('DRG-0006', 'Lisinopril',              'tablet',  '10 mg',            6000, 300),
  ('DRG-0007', 'Oral rehydration salts',  'sachet',  '20.5 g',          15000, 200),
  ('DRG-0008', 'Ferrous sulphate',        'tablet',  '200 mg',           1500, 500),
  ('DRG-0009', 'Ciprofloxacin',           'tablet',  '500 mg',          10000, 300),
  ('DRG-0010', 'Salbutamol',              'inhaler', '100 mcg per dose', 350000, 20),
  ('DRG-0011', 'Ibuprofen',               'tablet',  '400 mg',           3000, 600),
  ('DRG-0012', 'Folic acid',              'tablet',  '5 mg',             1000, 400);

INSERT INTO lab_test (test_code, name, specimen, unit, reference_low, reference_high, price_kobo, target_turnaround) VALUES
  ('LT-HB',    'Haemoglobin',                  'Blood', 'g/dL',   12.0, 17.5, 150000, '4 hours'),
  ('LT-MPRDT', 'Malaria rapid diagnostic test','Blood', NULL,     NULL, NULL, 200000, '1 hour'),
  ('LT-FBG',   'Fasting blood glucose',        'Blood', 'mmol/L', 3.9,  5.5,  100000, '2 hours'),
  ('LT-HBA1C', 'HbA1c',                        'Blood', '%',      4.0,  5.6,  650000, '24 hours'),
  ('LT-CREAT', 'Serum creatinine',             'Blood', 'umol/L', 60,   110,  400000, '24 hours'),
  ('LT-WIDAL', 'Widal test',                   'Blood', NULL,     NULL, NULL, 250000, '6 hours'),
  ('LT-URINE', 'Urinalysis',                   'Urine', NULL,     NULL, NULL, 150000, '2 hours'),
  ('LT-CHOL',  'Total cholesterol',            'Blood', 'mmol/L', 3.0,  5.2,  350000, '24 hours');

INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_at, moved_by, note)
SELECT f.facility_id, d.drug_id, 'RECEIPT',
       CASE WHEN d.form = 'inhaler' THEN 40 ELSE d.reorder_level * 2 END,
       '2026-09-01 08:00+01', pg_temp.stf(CASE f.facility_code WHEN 'ABJ-GRK' THEN 'ST-00013'
                                                              WHEN 'KAN-NAS' THEN 'ST-00014'
                                                              ELSE 'ST-00012' END),
       'Opening delivery'
  FROM facility f CROSS JOIN drug d
 WHERE f.facility_code IN ('LAG-IKJ', 'LAG-LEK', 'ABJ-GRK', 'KAN-NAS', 'IBD-BOD', 'ENU-IND')
 ORDER BY f.facility_id, d.drug_id;

INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_at, moved_by, transfer_ref) VALUES
  (pg_temp.fac('LAG-IKJ'), pg_temp.drg('DRG-0001'), 'TRANSFER_OUT', 200, '2026-10-15 10:00+01', pg_temp.stf('ST-00012'), '6f1c2d3e-0000-4000-8000-000000000001'),
  (pg_temp.fac('LAG-YAB'), pg_temp.drg('DRG-0001'), 'TRANSFER_IN',  200, '2026-10-15 10:00+01', pg_temp.stf('ST-00012'), '6f1c2d3e-0000-4000-8000-000000000001');

INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_at, moved_by, note) VALUES
  (pg_temp.fac('ABJ-GRK'), pg_temp.drg('DRG-0007'), 'ADJUST_OUT', 12, '2026-10-31 17:00+01', pg_temp.stf('ST-00013'), 'Expired batch removed at stock-take');

INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot, booked_at, booked_by, reason) VALUES
  (pg_temp.pat('HN-0000001'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'),    pg_temp.fac('LAG-IKJ'), '[2026-10-05 09:00+01, 2026-10-05 09:30+01)', '2026-10-01 12:10+01', pg_temp.stf('ST-00017'), 'Fever and headache'),
  (pg_temp.pat('HN-0000004'), pg_temp.stf('ST-00003'), pg_temp.dep('PAED'),  pg_temp.fac('LAG-LEK'), '[2026-10-12 10:00+01, 2026-10-12 10:20+01)', '2026-10-10 09:00+01', NULL,                     'Cough'),
  (pg_temp.pat('HN-0000003'), pg_temp.stf('ST-00004'), pg_temp.dep('IM'),    pg_temp.fac('KAN-NAS'), '[2026-10-20 11:00+01, 2026-10-20 11:40+01)', '2026-10-13 14:30+01', pg_temp.stf('ST-00018'), 'Blood pressure and sugar review'),
  (pg_temp.pat('HN-0000007'), pg_temp.stf('ST-00007'), pg_temp.dep('IM'),    pg_temp.fac('ABJ-GRK'), '[2026-11-02 09:30+01, 2026-11-02 10:00+01)', '2026-10-30 16:00+01', pg_temp.stf('ST-00018'), 'Persistent fever'),
  (pg_temp.pat('HN-0000001'), pg_temp.stf('ST-00001'), pg_temp.dep('IM'),    pg_temp.fac('LAG-IKJ'), '[2026-11-09 09:00+01, 2026-11-09 09:30+01)', '2026-11-03 10:00+01', pg_temp.stf('ST-00017'), 'Blood pressure follow-up'),
  (pg_temp.pat('HN-0000002'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'),    pg_temp.fac('LAG-IKJ'), '[2026-11-09 09:30+01, 2026-11-09 10:00+01)', '2026-11-04 08:45+01', NULL,                     'Back pain'),
  (pg_temp.pat('HN-0000008'), pg_temp.stf('ST-00002'), pg_temp.dep('GP'),    pg_temp.fac('LAG-IKJ'), '[2026-11-10 14:00+01, 2026-11-10 14:30+01)', '2026-11-05 11:20+01', pg_temp.stf('ST-00017'), 'Routine check'),
  (pg_temp.pat('HN-0000005'), pg_temp.stf('ST-00006'), pg_temp.dep('GP'),    pg_temp.fac('ENU-IND'), '[2026-11-11 10:00+01, 2026-11-11 10:30+01)', '2026-11-08 18:05+01', NULL,                     'Diarrhoea'),
  (pg_temp.pat('HN-0000001'), pg_temp.stf('ST-00001'), pg_temp.dep('GP'),    pg_temp.fac('LAG-IKJ'), '[2026-11-17 09:00+01, 2026-11-17 09:30+01)', '2026-11-12 09:40+01', pg_temp.stf('ST-00017'), 'Review of results'),
  (pg_temp.pat('HN-0000010'), pg_temp.stf('ST-00007'), pg_temp.dep('IM'),    pg_temp.fac('ABJ-GRK'), '[2026-11-18 11:00+01, 2026-11-18 11:30+01)', '2026-11-12 13:15+01', pg_temp.stf('ST-00018'), 'Palpitations'),
  (pg_temp.pat('HN-0000006'), pg_temp.stf('ST-00005'), pg_temp.dep('OBGYN'), pg_temp.fac('IBD-BOD'), '[2026-11-19 10:00+01, 2026-11-19 10:40+01)', '2026-11-13 10:00+01', NULL,                     'Antenatal review'),
  (pg_temp.pat('HN-0000012'), pg_temp.stf('ST-00002'), pg_temp.dep('GP'),    pg_temp.fac('LAG-IKJ'), '[2026-11-17 09:00+01, 2026-11-17 09:30+01)', '2026-11-13 15:30+01', pg_temp.stf('ST-00017'), 'Sore throat');

SELECT pg_temp.set_status(a.appointment_id, s.status, s.at::timestamptz, pg_temp.stf(s.staff_no))
  FROM (VALUES
          ('HN-0000001', '2026-10-05 09:00+01', 'COMPLETED', '2026-10-05 09:35+01', 'ST-00001'),
          ('HN-0000004', '2026-10-12 10:00+01', 'COMPLETED', '2026-10-12 10:25+01', 'ST-00003'),
          ('HN-0000003', '2026-10-20 11:00+01', 'COMPLETED', '2026-10-20 11:45+01', 'ST-00004'),
          ('HN-0000007', '2026-11-02 09:30+01', 'COMPLETED', '2026-11-02 10:05+01', 'ST-00007'),
          ('HN-0000001', '2026-11-09 09:00+01', 'COMPLETED', '2026-11-09 09:30+01', 'ST-00001'),
          ('HN-0000002', '2026-11-09 09:30+01', 'NO_SHOW',   '2026-11-09 10:15+01', 'ST-00017'),
          ('HN-0000008', '2026-11-10 14:00+01', 'CANCELLED', '2026-11-08 12:00+01', 'ST-00017'),
          ('HN-0000005', '2026-11-11 10:00+01', 'COMPLETED', '2026-11-11 10:40+01', 'ST-00006')
       ) AS s (hospital_no, slot_start, status, at, staff_no)
  JOIN appointment a ON a.patient_id = pg_temp.pat(s.hospital_no) AND lower(a.slot) = s.slot_start::timestamptz;

INSERT INTO encounter (patient_id, clinician_id, facility_id, appointment_id, encounter_type_code, started_at, ended_at)
SELECT a.patient_id, a.clinician_id, a.facility_id, a.appointment_id,
       CASE WHEN a.reason ILIKE '%follow-up%' THEN 'FOLLOW_UP' ELSE 'CONSULTATION' END,
       lower(a.slot) + interval '4 minutes', upper(a.slot)
  FROM appointment a
 WHERE a.appointment_status_code = 'COMPLETED'
 ORDER BY lower(a.slot);

INSERT INTO encounter (patient_id, clinician_id, facility_id, appointment_id, encounter_type_code, started_at, ended_at)
VALUES (pg_temp.pat('HN-0000009'), pg_temp.stf('ST-00006'), pg_temp.fac('ENU-IND'), NULL, 'WALK_IN',
        '2026-11-12 15:05+01', '2026-11-12 15:25+01');

CREATE TEMP VIEW visit AS
SELECT e.encounter_id, p.hospital_no, e.started_at, e.clinician_id, e.facility_id
  FROM itoju.encounter e JOIN itoju.patient p USING (patient_id);

INSERT INTO vital_sign (encounter_id, recorded_at, recorded_by, temperature_c, pulse_bpm, systolic_mmhg, diastolic_mmhg, spo2_pct, weight_kg, height_cm)
SELECT v.encounter_id, v.started_at + interval '2 minutes', pg_temp.stf(x.nurse), x.temp, x.pulse, x.sys, x.dia, x.spo2, x.weight, x.height
  FROM (VALUES
          ('HN-0000001', '2026-10-05', 'ST-00009', 38.6, 102, 128, 84, 97, 82.4, 176.0),
          ('HN-0000004', '2026-10-12', 'ST-00009', 37.9, 118, NULL, NULL, 96, 21.3, 114.5),
          ('HN-0000003', '2026-10-20', 'ST-00004', 36.8,  84, 152, 96, 98, 88.0, 162.0),
          ('HN-0000007', '2026-11-02', 'ST-00010', 39.1, 108, 118, 76, 97, 70.2, 180.5),
          ('HN-0000001', '2026-11-09', 'ST-00009', 36.7,  76, 142, 92, 98, 81.9, 176.0),
          ('HN-0000005', '2026-11-11', 'ST-00006', 37.4,  96, 110, 70, 96, 74.5, 171.0),
          ('HN-0000009', '2026-11-12', 'ST-00006', 37.2,  98, NULL, NULL, 98, 38.0, 147.0)
       ) AS x (hospital_no, visit_date, nurse, temp, pulse, sys, dia, spo2, weight, height)
  JOIN visit v ON v.hospital_no = x.hospital_no AND (v.started_at AT TIME ZONE 'Africa/Lagos')::date = x.visit_date::date;

INSERT INTO encounter_diagnosis (encounter_id, diagnosis_code, is_primary)
SELECT v.encounter_id, x.code, x.is_primary
  FROM (VALUES
          ('HN-0000001', '2026-10-05', 'B54',   true),
          ('HN-0000004', '2026-10-12', 'J06.9', true),
          ('HN-0000003', '2026-10-20', 'I10',   true),
          ('HN-0000003', '2026-10-20', 'E11.9', false),
          ('HN-0000007', '2026-11-02', 'A01.0', true),
          ('HN-0000001', '2026-11-09', 'I10',   true),
          ('HN-0000005', '2026-11-11', 'A09',   true),
          ('HN-0000009', '2026-11-12', 'H10.9', true)
       ) AS x (hospital_no, visit_date, code, is_primary)
  JOIN visit v ON v.hospital_no = x.hospital_no AND (v.started_at AT TIME ZONE 'Africa/Lagos')::date = x.visit_date::date;

INSERT INTO clinical_note (encounter_id, author_id, written_at, body)
SELECT v.encounter_id, v.clinician_id, v.started_at + interval '15 minutes', x.body
  FROM (VALUES
          ('HN-0000001', '2026-10-05', 'Two days of fever and headache. Malaria RDT positive. Start artemether-lumefantrine; paracetamol for fever.'),
          ('HN-0000004', '2026-10-12', 'Three days of cough, no chest signs. Viral URTI. Fluids and paracetamol.'),
          ('HN-0000003', '2026-10-20', 'BP 152/96. Fasting glucose raised. Start amlodipine and metformin; recheck in four weeks.'),
          ('HN-0000007', '2026-11-02', 'High fever for a week with abdominal pain. Widal requested. Start ciprofloxacin.'),
          ('HN-0000001', '2026-11-09', 'BP 142/92 on second reading. Start amlodipine. Creatinine requested.'),
          ('HN-0000005', '2026-11-11', 'Watery diarrhoea for one day, mild dehydration. Oral rehydration.'),
          ('HN-0000009', '2026-11-12', 'Red, sticky left eye since yesterday. Bacterial conjunctivitis likely.')
       ) AS x (hospital_no, visit_date, body)
  JOIN visit v ON v.hospital_no = x.hospital_no AND (v.started_at AT TIME ZONE 'Africa/Lagos')::date = x.visit_date::date;

INSERT INTO clinical_note (encounter_id, author_id, written_at, body, amends_note_id, amendment_reason)
SELECT n.encounter_id, n.author_id, n.written_at + interval '1 day',
       'Correction: patient is allergic to aspirin, not ibuprofen as first noted; no change to treatment.',
       n.clinical_note_id, 'Allergy recorded against the wrong drug'
  FROM clinical_note n JOIN visit v USING (encounter_id)
 WHERE v.hospital_no = 'HN-0000005';

INSERT INTO prescription (encounter_id, prescriber_id, issued_at)
SELECT v.encounter_id, v.clinician_id, v.started_at + interval '18 minutes'
  FROM visit v
 WHERE (v.hospital_no, (v.started_at AT TIME ZONE 'Africa/Lagos')::date) IN
       (('HN-0000001', DATE '2026-10-05'), ('HN-0000004', DATE '2026-10-12'), ('HN-0000003', DATE '2026-10-20'),
        ('HN-0000007', DATE '2026-11-02'), ('HN-0000001', DATE '2026-11-09'), ('HN-0000005', DATE '2026-11-11'));

INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage)
SELECT rx.prescription_id, pg_temp.drg(x.drug), x.qty, x.dosage
  FROM (VALUES
          ('HN-0000001', '2026-10-05', 'DRG-0001', 24, '4 tablets twice daily for 3 days'),
          ('HN-0000001', '2026-10-05', 'DRG-0002', 18, '2 tablets three times daily for 3 days'),
          ('HN-0000004', '2026-10-12', 'DRG-0002', 10, 'Half a tablet three times daily as needed'),
          ('HN-0000003', '2026-10-20', 'DRG-0004', 30, '1 tablet daily'),
          ('HN-0000003', '2026-10-20', 'DRG-0005', 60, '1 tablet twice daily with meals'),
          ('HN-0000007', '2026-11-02', 'DRG-0009', 14, '1 tablet twice daily for 7 days'),
          ('HN-0000007', '2026-11-02', 'DRG-0002', 12, '2 tablets three times daily as needed'),
          ('HN-0000001', '2026-11-09', 'DRG-0004', 30, '1 tablet daily'),
          ('HN-0000005', '2026-11-11', 'DRG-0007', 6,  '1 sachet after each loose stool')
       ) AS x (hospital_no, visit_date, drug, qty, dosage)
  JOIN visit v ON v.hospital_no = x.hospital_no AND (v.started_at AT TIME ZONE 'Africa/Lagos')::date = x.visit_date::date
  JOIN prescription rx ON rx.encounter_id = v.encounter_id;

INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_at, moved_by, prescription_id)
SELECT e.facility_id, pi.drug_id, 'DISPENSE', pi.quantity, e.ended_at + interval '10 minutes',
       pg_temp.stf(CASE f.facility_code WHEN 'ABJ-GRK' THEN 'ST-00013' WHEN 'KAN-NAS' THEN 'ST-00014' ELSE 'ST-00012' END),
       pi.prescription_id
  FROM prescription_item pi
  JOIN prescription rx USING (prescription_id)
  JOIN encounter e USING (encounter_id)
  JOIN facility f ON f.facility_id = e.facility_id
 WHERE NOT (e.patient_id = pg_temp.pat('HN-0000001') AND e.started_at > '2026-11-01')
 ORDER BY e.started_at, pi.drug_id;

INSERT INTO lab_order (encounter_id, lab_test_id, facility_id, ordered_by, ordered_at)
SELECT v.encounter_id, pg_temp.lab(x.test), v.facility_id, v.clinician_id, v.started_at + interval '10 minutes'
  FROM (VALUES
          ('HN-0000001', '2026-10-05', 'LT-MPRDT'),
          ('HN-0000003', '2026-10-20', 'LT-FBG'),
          ('HN-0000003', '2026-10-20', 'LT-HBA1C'),
          ('HN-0000007', '2026-11-02', 'LT-WIDAL'),
          ('HN-0000001', '2026-11-09', 'LT-CREAT')
       ) AS x (hospital_no, visit_date, test)
  JOIN visit v ON v.hospital_no = x.hospital_no AND (v.started_at AT TIME ZONE 'Africa/Lagos')::date = x.visit_date::date;

INSERT INTO lab_result (lab_order_id, recorded_at, recorded_by, value_numeric, value_text)
SELECT o.lab_order_id, o.ordered_at + x.after::interval, pg_temp.stf(x.scientist), x.num, x.txt
  FROM (VALUES
          ('HN-0000001', 'LT-MPRDT', '40 minutes', 'ST-00015', NULL::numeric, 'Positive (P. falciparum)'),
          ('HN-0000003', 'LT-FBG',   '90 minutes', 'ST-00015', 78,            NULL),
          ('HN-0000003', 'LT-HBA1C', '20 hours',   'ST-00015', 7.2,           NULL),
          ('HN-0000007', 'LT-WIDAL', '5 hours',    'ST-00015', NULL,          'Reactive, O antigen 1:160'),
          ('HN-0000001', 'LT-CREAT', '26 hours',   'ST-00015', 98,            NULL)
       ) AS x (hospital_no, test, after, scientist, num, txt)
  JOIN lab_order o ON o.lab_test_id = pg_temp.lab(x.test)
  JOIN encounter e ON e.encounter_id = o.encounter_id AND e.patient_id = pg_temp.pat(x.hospital_no);

INSERT INTO lab_result (lab_order_id, recorded_at, recorded_by, value_numeric, value_text, supersedes_result_id, correction_reason)
SELECT r.lab_order_id, r.recorded_at + interval '25 minutes', r.recorded_by, 7.8, NULL, r.lab_result_id,
       'Decimal point missed at entry'
  FROM lab_result r JOIN lab_order o USING (lab_order_id)
 WHERE o.lab_test_id = pg_temp.lab('LT-FBG');

INSERT INTO invoice (invoice_no, patient_id, facility_id, encounter_id, issued_at, issued_by, total_kobo)
SELECT 'INV-' || lpad(row_number() OVER (ORDER BY e.started_at)::text, 8, '0'),
       e.patient_id, e.facility_id, e.encounter_id, e.ended_at + interval '15 minutes',
       pg_temp.stf(CASE f.state WHEN 'FCT' THEN 'ST-00020' ELSE 'ST-00019' END), 0
  FROM encounter e JOIN facility f ON f.facility_id = e.facility_id;

SELECT setval('invoice_no_seq', (SELECT count(*) FROM invoice));

INSERT INTO invoice_line (invoice_id, line_no, description, drug_id, lab_test_id, quantity, unit_price_kobo)
SELECT i.invoice_id, row_number() OVER (PARTITION BY i.invoice_id ORDER BY item.sort_key)::smallint,
       item.description, item.drug_id, item.lab_test_id, item.quantity, item.unit_price_kobo
  FROM invoice i
  CROSS JOIN LATERAL (
    SELECT 0 AS sort_key, 'Consultation' AS description, NULL::bigint AS drug_id, NULL::bigint AS lab_test_id,
           1 AS quantity, 500000::bigint AS unit_price_kobo
    UNION ALL
    SELECT 1, d.name || ' ' || d.strength || ' ' || d.form, d.drug_id, NULL, pi.quantity, d.unit_price_kobo
      FROM prescription rx JOIN prescription_item pi USING (prescription_id) JOIN drug d USING (drug_id)
     WHERE rx.encounter_id = i.encounter_id
    UNION ALL
    SELECT 2, t.name, NULL, t.lab_test_id, 1, t.price_kobo
      FROM lab_order o JOIN lab_test t USING (lab_test_id)
     WHERE o.encounter_id = i.encounter_id
  ) item;

UPDATE invoice i
   SET total_kobo = (SELECT sum(l.amount_kobo) FROM invoice_line l WHERE l.invoice_id = i.invoice_id);

INSERT INTO payment (invoice_id, payment_method_code, amount_kobo, paid_at, received_by, reference)
SELECT i.invoice_id, x.method,
       CASE WHEN x.share = 'full' THEN i.total_kobo ELSE i.total_kobo / 2 END,
       i.issued_at + interval '5 minutes', i.issued_by, x.reference
  FROM (VALUES
          ('HN-0000001', '2026-10-05', 'CASH',     'full', NULL),
          ('HN-0000004', '2026-10-12', 'HMO',      'full', 'HMO-CLAIM-77120'),
          ('HN-0000003', '2026-10-20', 'CARD',     'half', 'POS-310245'),
          ('HN-0000007', '2026-11-02', 'TRANSFER', 'full', 'TRF-889101'),
          ('HN-0000005', '2026-11-11', 'CASH',     'full', NULL),
          ('HN-0000009', '2026-11-12', 'CASH',     'full', NULL)
       ) AS x (hospital_no, visit_date, method, share, reference)
  JOIN visit v ON v.hospital_no = x.hospital_no AND (v.started_at AT TIME ZONE 'Africa/Lagos')::date = x.visit_date::date
  JOIN invoice i ON i.encounter_id = v.encounter_id;

INSERT INTO on_call_shift (facility_id, clinician_id, shift_date, on_call) VALUES
  (pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00001'), '2026-11-14', true),
  (pg_temp.fac('LAG-IKJ'), pg_temp.stf('ST-00002'), '2026-11-14', true),
  (pg_temp.fac('ABJ-GRK'), pg_temp.stf('ST-00007'), '2026-11-14', true),
  (pg_temp.fac('ABJ-GRK'), pg_temp.stf('ST-00008'), '2026-11-14', true),
  (pg_temp.fac('KAN-NAS'), pg_temp.stf('ST-00004'), '2026-11-14', true);

SELECT patient_record(pg_temp.stf('ST-00001'), pg_temp.pat('HN-0000001'), 'Pre-consultation review') IS NOT NULL AS opened;
SELECT patient_record(pg_temp.stf('ST-00004'), pg_temp.pat('HN-0000003'), 'Review of glucose results') IS NOT NULL AS opened;

DROP VIEW visit;
