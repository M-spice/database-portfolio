\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
SET TimeZone = 'UTC';
SET ROLE itoju_owner;
SET search_path = itoju, public;
SET max_parallel_workers_per_gather = 0;
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';

\timing on
BEGIN;

-- Uniform value in [0, 1) derived from a row number and a seed, so every rebuild yields the same data.
CREATE FUNCTION pg_temp.u(i bigint, seed bigint) RETURNS double precision
LANGUAGE sql IMMUTABLE AS
$$ SELECT ((hashint8extended(i, seed) >> 11) & 9007199254740991)::double precision / 9007199254740992 $$;

CREATE FUNCTION pg_temp.pick(i bigint, seed bigint, n integer) RETURNS integer
LANGUAGE sql IMMUTABLE AS
$$ SELECT floor(pg_temp.u(i, seed) * n)::integer $$;

CREATE TEMP TABLE name_list AS
SELECT ARRAY['Adaeze','Babatunde','Chiamaka','Ibrahim','Funmilayo','Emeka','Zainab','Tunde','Ngozi','Aisha',
             'Segun','Kemi','Uchenna','Halima','Bola','Obinna','Yetunde','Musa','Ifeoma','Dapo',
             'Grace','Sola','Fatima','Peter','Chinedu','Amaka','Usman','Bisi','Kelechi','Hauwa',
             'Femi','Nneka','Sani','Tobi','Chidi','Rukayat','Yusuf','Ebere','Lola','Garba'] AS given,
       ARRAY['Okafor','Adeyemi','Eze','Musa','Ogunleye','Nwosu','Bello','Bakare','Obi','Lawal',
             'Akande','Adebayo','Okeke','Sani','Ajayi','Chukwu','Alabi','Abdullahi','Nnaji','Olatunji',
             'Etim','Ige','Yusuf','Okon','Balogun','Danjuma','Ibe','Onyeka','Salami','Garba',
             'Umar','Okoro','Adeniran','Odunsi','Okonkwo','Agu','Bankole','Udo','Ojo','Ekwueme'] AS family,
       ARRAY['Allen Avenue','Herbert Macaulay Way','Ahmadu Bello Way','Zik Avenue','Ring Road','Zoo Road',
             'Ogui Road','Opebi Road','Admiralty Way','Aminu Kano Crescent','Bodija Road','Murtala Mohammed Way'] AS street;

-- Busy branches get more clinicians and therefore more patients and appointments.
CREATE TEMP TABLE fac_weight AS
SELECT f.facility_id, f.facility_code, f.city, f.state, f.has_laboratory,
       coalesce(sum(w.weight) OVER (ORDER BY w.facility_code ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) / 100.0 AS lo,
       sum(w.weight) OVER (ORDER BY w.facility_code) / 100.0 AS hi,
       coalesce(lab.facility_id, f.facility_id) AS lab_facility_id
  FROM (VALUES ('LAG-IKJ', 18), ('LAG-LEK', 14), ('ABJ-GRK', 13), ('LAG-YAB', 9), ('ABJ-WUS', 8), ('IBD-BOD', 8),
               ('ENU-IND', 7), ('KAN-NAS', 7), ('LAG-SUR', 5), ('ABJ-GWA', 5), ('IBD-RRD', 3), ('ENU-NHV', 3))
       AS w (facility_code, weight)
  JOIN facility f USING (facility_code)
  LEFT JOIN facility lab ON NOT f.has_laboratory
       AND lab.facility_code = CASE f.facility_code WHEN 'LAG-SUR' THEN 'LAG-YAB' WHEN 'IBD-RRD' THEN 'IBD-BOD'
                                                    WHEN 'ENU-NHV' THEN 'ENU-IND' END;

-- Foreign keys and exclusion constraints are dropped for the bulk load and re-added at the end,
-- which re-validates every row in one pass instead of one trigger call per row.
CREATE TEMP TABLE held_constraint AS
SELECT c.conrelid::regclass::text AS table_name, c.conname, pg_get_constraintdef(c.oid) AS definition, c.contype
  FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
 WHERE n.nspname = 'itoju' AND c.contype IN ('f', 'x');

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM held_constraint ORDER BY contype, table_name, conname LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.table_name, r.conname);
  END LOOP;
  FOR r IN SELECT DISTINCT c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'itoju' AND NOT t.tgisinternal LOOP
    EXECUTE format('ALTER TABLE %I DISABLE TRIGGER USER', r.relname);
  END LOOP;
END $$;

-- staff: 290 clinicians plus pharmacists, laboratory scientists, receptionists and billing officers per branch

INSERT INTO staff (staff_no, given_name, family_name, staff_role_code, home_facility_id, employed_on)
SELECT 'ST-' || lpad((1000 + i)::text, 5, '0'),
       n.given[1 + pg_temp.pick(i, 101, 40)], n.family[1 + pg_temp.pick(i, 102, 40)],
       CASE WHEN pg_temp.u(i, 103) < 0.8 THEN 'DOCTOR' ELSE 'NURSE' END,
       fw.facility_id, DATE '2010-01-04' + pg_temp.pick(i, 104, 5000)
  FROM generate_series(1, 290) i
 CROSS JOIN name_list n
  JOIN fac_weight fw ON pg_temp.u(i, 105) >= fw.lo AND pg_temp.u(i, 105) < fw.hi
 ORDER BY i;

INSERT INTO clinician (clinician_id, licence_no)
SELECT staff_id, 'LIC-999-' || substr(staff_no, 4) FROM staff WHERE staff_no >= 'ST-01001' AND staff_no <= 'ST-01290';

INSERT INTO staff (staff_no, given_name, family_name, staff_role_code, home_facility_id, employed_on)
SELECT 'ST-' || lpad((2000 + row_number() OVER (ORDER BY fw.facility_code, r.role, k))::text, 5, '0'),
       n.given[1 + pg_temp.pick(fw.facility_id * 1000 + k * 100 + length(r.role), 106, 40)],
       n.family[1 + pg_temp.pick(fw.facility_id * 1000 + k * 100 + length(r.role), 107, 40)],
       r.role, fw.facility_id, DATE '2015-01-05' + pg_temp.pick(fw.facility_id * 100 + k, 108, 3000)
  FROM fac_weight fw
 CROSS JOIN name_list n
 CROSS JOIN (VALUES ('PHARMACIST', 2), ('LAB_SCIENTIST', 2), ('RECEPTIONIST', 3), ('BILLING_OFFICER', 2)) AS r (role, how_many)
 CROSS JOIN LATERAL generate_series(1, r.how_many) k
 WHERE r.role <> 'LAB_SCIENTIST' OR fw.has_laboratory
 ORDER BY fw.facility_code, r.role, k;

CREATE TEMP TABLE fac_staff AS
SELECT home_facility_id AS facility_id, staff_role_code, min(staff_id) AS staff_id
  FROM staff WHERE staff_no >= 'ST-02001' GROUP BY 1, 2;

CREATE TEMP TABLE vol_clinician AS
SELECT s.staff_id AS clinician_id, s.home_facility_id AS facility_id,
       0.13 + 0.66 * pg_temp.u(s.staff_id, 110) ^ 2 AS fill,
       (SELECT department_id FROM department WHERE department_code =
          CASE WHEN pg_temp.u(s.staff_id, 111) < 0.45 THEN 'GP' WHEN pg_temp.u(s.staff_id, 111) < 0.65 THEN 'IM'
               WHEN pg_temp.u(s.staff_id, 111) < 0.80 THEN 'PAED' WHEN pg_temp.u(s.staff_id, 111) < 0.90 THEN 'OBGYN'
               WHEN pg_temp.u(s.staff_id, 111) < 0.95 THEN 'DERM' ELSE 'OPHTH' END) AS department_id
  FROM staff s WHERE s.staff_no BETWEEN 'ST-01001' AND 'ST-01290';

INSERT INTO clinician_department (clinician_id, department_id, assigned_on)
SELECT c.clinician_id, c.department_id, s.employed_on FROM vol_clinician c JOIN staff s ON s.staff_id = c.clinician_id
UNION ALL
SELECT c.clinician_id, d.department_id, s.employed_on + 365
  FROM vol_clinician c JOIN staff s ON s.staff_id = c.clinician_id
  JOIN department d ON d.department_id <> c.department_id
       AND d.department_code = (ARRAY['GP','IM','PAED','OBGYN','DERM','OPHTH'])[1 + pg_temp.pick(c.clinician_id, 112, 6)]
 WHERE pg_temp.u(c.clinician_id, 113) < 0.30;

-- patients: 60,000, registered at a branch in proportion to its size

INSERT INTO patient (hospital_no, given_name, middle_name, family_name, date_of_birth, national_id,
                     address_line, address_city, address_state, registered_facility_id, registered_at)
SELECT 'HN-' || lpad((100000 + i)::text, 7, '0'),
       n.given[1 + pg_temp.pick(i, 120, 40)],
       CASE WHEN pg_temp.u(i, 121) < 0.4 THEN n.given[1 + pg_temp.pick(i, 122, 40)] END,
       n.family[1 + pg_temp.pick(i, 123, 40)],
       dob,
       CASE WHEN pg_temp.u(i, 124) < 0.7 THEN '999' || lpad((10000000 + i)::text, 8, '0') END,
       (1 + pg_temp.pick(i, 125, 180))::text || ' ' || n.street[1 + pg_temp.pick(i, 126, 12)],
       fw.city, fw.state, fw.facility_id,
       greatest(timestamptz '2012-03-01 08:00+01' + pg_temp.pick(i, 127, 4627) * interval '1 day'
                  + pg_temp.pick(i, 128, 32400) * interval '1 second',
                dob + interval '1 day')
  FROM generate_series(1, 60000) i
 CROSS JOIN name_list n
  JOIN fac_weight fw ON pg_temp.u(i, 129) >= fw.lo AND pg_temp.u(i, 129) < fw.hi
 CROSS JOIN LATERAL (SELECT DATE '2026-11-13' - floor(pg_temp.u(i, 130) ^ 1.3 * 90 * 365.25)::integer AS dob) d
 ORDER BY i;

CREATE TEMP TABLE vol_patient AS
SELECT p.patient_id, p.registered_facility_id AS facility_id, p.date_of_birth,
       row_number() OVER (PARTITION BY p.registered_facility_id ORDER BY p.hospital_no) AS rank,
       count(*) OVER (PARTITION BY p.registered_facility_id) AS n
  FROM patient p WHERE p.hospital_no >= 'HN-0100001';
CREATE UNIQUE INDEX ON vol_patient (facility_id, rank);

-- 8% of each branch's patients are chronic (heavy users), 32% regular and 60% occasional.
CREATE TEMP TABLE fac_count AS
SELECT facility_id, n, ceil(n * 0.08)::int AS n_chronic, ceil(n * 0.32)::int AS n_regular
  FROM (SELECT facility_id, max(n) AS n FROM vol_patient GROUP BY facility_id) s;

INSERT INTO patient_phone (patient_id, phone_no, is_primary)
SELECT v.patient_id, '+23401' || lpad(substr(p.hospital_no, 4)::int::text, 8, '0'), true
  FROM vol_patient v JOIN patient p USING (patient_id)
UNION ALL
SELECT v.patient_id, '+23402' || lpad(substr(p.hospital_no, 4)::int::text, 8, '0'), false
  FROM vol_patient v JOIN patient p USING (patient_id)
 WHERE pg_temp.u(v.patient_id, 131) < 0.25;

INSERT INTO patient_allergy (patient_id, allergen, reaction, recorded_at)
SELECT v.patient_id,
       (ARRAY['Penicillin','Sulfonamides','Aspirin','Latex','Ibuprofen','Chloroquine'])[1 + pg_temp.pick(v.patient_id, 132, 6)],
       (ARRAY['Rash','Hives','Wheeze','Swelling'])[1 + pg_temp.pick(v.patient_id, 133, 4)], p.registered_at
  FROM vol_patient v JOIN patient p USING (patient_id)
 WHERE pg_temp.u(v.patient_id, 134) < 0.10;

INSERT INTO next_of_kin (patient_id, kin_no, full_name, relationship, phone_no)
SELECT v.patient_id, 1,
       n.given[1 + pg_temp.pick(v.patient_id, 135, 40)] || ' ' || p.family_name,
       (ARRAY['Spouse','Mother','Father','Sibling','Son','Daughter'])[1 + pg_temp.pick(v.patient_id, 136, 6)],
       '+23403' || lpad(substr(p.hospital_no, 4)::int::text, 8, '0')
  FROM vol_patient v JOIN patient p USING (patient_id) CROSS JOIN name_list n
 WHERE pg_temp.u(v.patient_id, 137) < 0.5;

INSERT INTO consent (patient_id, consent_purpose_code, granted_at, recorded_by)
SELECT v.patient_id, c.purpose, p.registered_at, fs.staff_id
  FROM vol_patient v JOIN patient p USING (patient_id)
  JOIN fac_staff fs ON fs.facility_id = v.facility_id AND fs.staff_role_code = 'RECEPTIONIST'
 CROSS JOIN (VALUES ('TREATMENT', 1.0), ('SMS_REMINDERS', 0.6), ('DEIDENTIFIED_RESEARCH', 0.2)) AS c (purpose, share)
 WHERE pg_temp.u(v.patient_id * 10 + length(c.purpose), 138) < c.share
 ORDER BY v.patient_id, c.purpose;

-- appointments: a 30-minute grid, 08:00 to 16:00 Lagos time on weekdays, 1 Nov 2024 to 30 Nov 2026

CREATE TEMP TABLE work_day AS
SELECT d::date AS day, d::date - DATE '2024-11-01' AS day_no
  FROM generate_series(DATE '2024-11-01', DATE '2026-11-30', interval '1 day') d
 WHERE extract(isodow FROM d) < 6;

CREATE TEMP TABLE vol_appt AS
WITH candidate AS (
  SELECT c.clinician_id, c.department_id, c.facility_id, w.day, s.slot_no,
         c.clinician_id * 100000 + w.day_no * 16 + s.slot_no AS k
    FROM vol_clinician c CROSS JOIN work_day w CROSS JOIN generate_series(0, 15) s (slot_no)
   WHERE pg_temp.u(c.clinician_id * 100000 + w.day_no * 16 + s.slot_no, 201) < c.fill
), chosen AS (
  SELECT cd.*,
         CASE WHEN pg_temp.u(k, 202) < 0.35 THEN 1 + floor(fc.n_chronic * pg_temp.u(k, 203) ^ 1.15)::int
              WHEN pg_temp.u(k, 202) < 0.85 THEN fc.n_chronic + 1 + floor(fc.n_regular * pg_temp.u(k, 204))::int
              ELSE least(fc.n, fc.n_chronic + fc.n_regular + 1
                               + floor((fc.n - fc.n_chronic - fc.n_regular) * pg_temp.u(k, 205) ^ 1.15)::int) END AS rank
    FROM candidate cd JOIN fac_count fc USING (facility_id)
)
SELECT DISTINCT ON (vp.patient_id, ch.day, ch.slot_no)
       ch.k, ch.clinician_id, ch.department_id, ch.facility_id, vp.patient_id, vp.date_of_birth,
       ch.rank <= (SELECT n_chronic FROM fac_count WHERE facility_id = ch.facility_id) AS chronic,
       ((ch.day + time '08:00' + ch.slot_no * interval '30 minutes') AT TIME ZONE 'Africa/Lagos') AS starts
  FROM chosen ch JOIN vol_patient vp ON vp.facility_id = ch.facility_id AND vp.rank = ch.rank
 ORDER BY vp.patient_id, ch.day, ch.slot_no, ch.clinician_id;

ALTER TABLE vol_appt
  ADD COLUMN status text, ADD COLUMN booked_at timestamptz, ADD COLUMN booked_by bigint,
  ADD COLUMN appointment_id bigint;

UPDATE vol_appt a
   SET status = CASE
                  WHEN a.starts >= timestamptz '2026-11-14 12:00+01'
                    THEN CASE WHEN pg_temp.u(a.k, 210) < 0.04 THEN 'CANCELLED' ELSE 'BOOKED' END
                  WHEN pg_temp.u(a.k, 210) < 0.80 THEN 'COMPLETED'
                  WHEN pg_temp.u(a.k, 210) < 0.88 THEN 'NO_SHOW'
                  ELSE 'CANCELLED' END,
       booked_at = a.starts - (1 + pg_temp.pick(a.k, 211, 20)) * interval '1 day' - pg_temp.pick(a.k, 212, 36000) * interval '1 second',
       booked_by = CASE WHEN pg_temp.u(a.k, 213) < 0.6 THEN fs.staff_id END
  FROM fac_staff fs
 WHERE fs.facility_id = a.facility_id AND fs.staff_role_code = 'RECEPTIONIST';

UPDATE vol_appt a
   SET appointment_id = s.base + s.rn
  FROM (SELECT k, row_number() OVER (ORDER BY starts, clinician_id) AS rn,
               (SELECT max(appointment_id) FROM appointment) AS base
          FROM vol_appt) s
 WHERE s.k = a.k;

INSERT INTO appointment (appointment_id, patient_id, clinician_id, department_id, facility_id, slot,
                         appointment_status_code, booked_at, booked_by)
OVERRIDING SYSTEM VALUE
SELECT appointment_id, patient_id, clinician_id, department_id, facility_id,
       tstzrange(starts, starts + interval '30 minutes'), status, booked_at, booked_by
  FROM vol_appt ORDER BY appointment_id;

INSERT INTO appointment_status_history (appointment_id, appointment_status_code, changed_at, changed_by)
SELECT appointment_id, appointment_status_code, changed_at, changed_by FROM (
  SELECT appointment_id, 'BOOKED' AS appointment_status_code, booked_at AS changed_at, booked_by AS changed_by, 1 AS step
    FROM vol_appt
  UNION ALL
  SELECT a.appointment_id, a.status,
         CASE a.status WHEN 'CANCELLED' THEN a.booked_at + (a.starts - a.booked_at) * pg_temp.u(a.k, 214)
                       ELSE a.starts + interval '45 minutes' END,
         CASE WHEN a.status = 'COMPLETED' THEN a.clinician_id ELSE fs.staff_id END, 2
    FROM vol_appt a JOIN fac_staff fs ON fs.facility_id = a.facility_id AND fs.staff_role_code = 'RECEPTIONIST'
   WHERE a.status <> 'BOOKED'
) h ORDER BY changed_at, appointment_id, step;

-- encounters for completed appointments

CREATE TEMP TABLE vol_enc AS
SELECT a.k, a.appointment_id, a.patient_id, a.clinician_id, a.facility_id, a.chronic, a.date_of_birth,
       a.starts + floor(35 * pg_temp.u(a.k, 220) ^ 2) * interval '1 minute' AS started_at,
       CASE WHEN a.chronic THEN CASE WHEN pg_temp.u(a.k, 221) < 0.6 THEN 'FOLLOW_UP' ELSE 'CONSULTATION' END
            WHEN pg_temp.u(a.k, 221) < 0.12 THEN 'FOLLOW_UP'
            WHEN pg_temp.u(a.k, 221) < 0.15 THEN 'TELECONSULT'
            ELSE 'CONSULTATION' END AS encounter_type_code
  FROM vol_appt a WHERE a.status = 'COMPLETED';

ALTER TABLE vol_enc ADD COLUMN ended_at timestamptz, ADD COLUMN encounter_id bigint;
UPDATE vol_enc e
   SET ended_at = e.started_at + (8 + pg_temp.pick(e.k, 222, 17)) * interval '1 minute',
       encounter_id = s.base + s.rn
  FROM (SELECT k, row_number() OVER (ORDER BY started_at, appointment_id) AS rn,
               (SELECT max(encounter_id) FROM encounter) AS base FROM vol_enc) s
 WHERE s.k = e.k;
CREATE UNIQUE INDEX ON vol_enc (encounter_id);

INSERT INTO encounter (encounter_id, patient_id, clinician_id, facility_id, appointment_id, encounter_type_code, started_at, ended_at)
OVERRIDING SYSTEM VALUE
SELECT encounter_id, patient_id, clinician_id, facility_id, appointment_id, encounter_type_code, started_at, ended_at
  FROM vol_enc ORDER BY encounter_id;

INSERT INTO vital_sign (encounter_id, recorded_at, recorded_by, temperature_c, pulse_bpm, systolic_mmhg, diastolic_mmhg,
                        spo2_pct, weight_kg, height_cm)
SELECT e.encounter_id, e.started_at + interval '2 minutes', e.clinician_id,
       round((36.1 + 3.2 * pg_temp.u(e.k, 230) ^ 3)::numeric, 1),
       60 + pg_temp.pick(e.k, 231, 60),
       CASE WHEN age.years >= 12 THEN sys END,
       CASE WHEN age.years >= 12 THEN sys - 30 - pg_temp.pick(e.k, 233, 20) END,
       92 + pg_temp.pick(e.k, 234, 9),
       CASE WHEN age.years < 12 THEN round((8 + 2.6 * age.years + 4 * pg_temp.u(e.k, 235))::numeric, 2)
            ELSE round((45 + 55 * pg_temp.u(e.k, 235))::numeric, 2) END,
       CASE WHEN age.years < 12 THEN round((75 + 6.5 * age.years + 5 * pg_temp.u(e.k, 236))::numeric, 1)
            ELSE round((150 + 40 * pg_temp.u(e.k, 236))::numeric, 1) END
  FROM vol_enc e
 CROSS JOIN LATERAL (SELECT extract(year FROM age(e.started_at::date::timestamp, e.date_of_birth::timestamp))::int AS years) age
 CROSS JOIN LATERAL (SELECT CASE WHEN e.chronic THEN 125 + pg_temp.pick(e.k, 232, 50) ELSE 100 + pg_temp.pick(e.k, 232, 45) END AS sys) bp
 ORDER BY e.encounter_id;

-- diagnoses: chronic patients mostly return for chronic conditions; acute codes follow a skewed mix

CREATE TEMP TABLE dx_weight AS
SELECT chronic_set, diagnosis_code,
       coalesce(sum(weight) OVER (PARTITION BY chronic_set ORDER BY diagnosis_code
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) / 100.0 AS lo,
       sum(weight) OVER (PARTITION BY chronic_set ORDER BY diagnosis_code) / 100.0 AS hi
  FROM (VALUES (true, 'I10', 45), (true, 'E11.9', 30), (true, 'J45.9', 10), (true, 'E78.5', 15),
               (false, 'B54', 24), (false, 'J06.9', 18), (false, 'A09', 9), (false, 'A01.0', 6), (false, 'K29.7', 7),
               (false, 'M54.5', 7), (false, 'N39.0', 6), (false, 'L30.9', 4), (false, 'H10.9', 4), (false, 'D50.9', 5),
               (false, 'B50.0', 1), (false, 'Z34.9', 5), (false, 'I10', 2), (false, 'E11.9', 2)) AS w (chronic_set, diagnosis_code, weight);

CREATE TEMP TABLE vol_dx AS
SELECT e.encounter_id, e.k, e.facility_id, e.started_at, e.ended_at, e.clinician_id, e.chronic, w.diagnosis_code AS primary_code,
       1 + (pg_temp.u(e.k, 241) < 0.22)::int + (pg_temp.u(e.k, 242) < 0.05)::int AS n_codes
  FROM vol_enc e
  JOIN dx_weight w ON w.chronic_set = (e.chronic AND pg_temp.u(e.k, 243) < 0.7)
                  AND pg_temp.u(e.k, 244) >= w.lo AND pg_temp.u(e.k, 244) < w.hi;

INSERT INTO encounter_diagnosis (encounter_id, diagnosis_code, is_primary)
SELECT x.encounter_id,
       CASE WHEN j = 0 THEN x.primary_code
            ELSE c.codes[1 + ((array_position(c.codes, x.primary_code) - 1 + j * 5) % 16)] END,
       j = 0
  FROM vol_dx x
 CROSS JOIN (SELECT array_agg(diagnosis_code ORDER BY diagnosis_code) AS codes FROM diagnosis_code) c
 CROSS JOIN LATERAL generate_series(0, x.n_codes - 1) j
 ORDER BY x.encounter_id, j;

INSERT INTO clinical_note (encounter_id, author_id, written_at, body)
SELECT x.encounter_id, x.clinician_id, x.started_at + interval '12 minutes',
       'Seen for ' || lower(d.description) || '. '
       || (ARRAY['Treatment started; review in two weeks.', 'Advised fluids and rest.',
                 'Results discussed; continue current medication.', 'Referred for further tests.',
                 'Symptoms improving; no change to plan.', 'Medication adjusted; follow-up booked.',
                 'Health education given.', 'Safety-netting advice given.'])[1 + pg_temp.pick(x.k, 250, 8)]
  FROM vol_dx x JOIN diagnosis_code d ON d.diagnosis_code = x.primary_code
 ORDER BY x.encounter_id;

INSERT INTO clinical_note (encounter_id, author_id, written_at, body, amends_note_id, amendment_reason)
SELECT n.encounter_id, n.author_id, n.written_at + interval '1 day',
       'Addendum: plan confirmed after review of results.', n.clinical_note_id, 'Information added after results'
  FROM clinical_note n JOIN vol_dx x USING (encounter_id)
 WHERE pg_temp.u(x.k, 251) < 0.003
 ORDER BY n.clinical_note_id;

-- prescriptions follow the primary diagnosis; most items are dispensed at the branch

CREATE TEMP TABLE dx_drug AS
SELECT x.code, d.drug_id, x.drug_no, x.quantity, x.probability
  FROM (VALUES ('B54', 'DRG-0001', 1, 24, 0.95), ('B54', 'DRG-0002', 2, 18, 0.80),
               ('B50.0', 'DRG-0001', 1, 24, 1.00), ('B50.0', 'DRG-0002', 2, 18, 0.90),
               ('J06.9', 'DRG-0002', 1, 12, 0.85), ('J06.9', 'DRG-0003', 2, 15, 0.30),
               ('A09', 'DRG-0007', 1, 6, 0.90),
               ('A01.0', 'DRG-0009', 1, 14, 0.95), ('A01.0', 'DRG-0002', 2, 12, 0.50),
               ('K29.7', 'DRG-0002', 1, 10, 0.40),
               ('M54.5', 'DRG-0011', 1, 15, 0.85),
               ('N39.0', 'DRG-0009', 1, 6, 0.90),
               ('D50.9', 'DRG-0008', 1, 60, 0.95), ('D50.9', 'DRG-0012', 2, 30, 0.60),
               ('Z34.9', 'DRG-0012', 1, 30, 0.90), ('Z34.9', 'DRG-0008', 2, 30, 0.70),
               ('I10', 'DRG-0004', 1, 30, 0.80), ('I10', 'DRG-0006', 2, 30, 0.35),
               ('E11.9', 'DRG-0005', 1, 60, 0.90),
               ('J45.9', 'DRG-0010', 1, 1, 0.70)) AS x (code, drug_code, drug_no, quantity, probability)
  JOIN drug d ON d.drug_code = x.drug_code;

CREATE TEMP TABLE vol_item AS
SELECT x.encounter_id, x.k, x.facility_id, x.started_at, x.ended_at, x.clinician_id, m.drug_id, m.quantity,
       CASE m.quantity WHEN 1 THEN '2 puffs as needed' ELSE 'As directed on the label' END AS dosage
  FROM vol_dx x JOIN dx_drug m ON m.code = x.primary_code
 WHERE pg_temp.u(x.k * 4 + m.drug_no, 260) < m.probability;

CREATE TEMP TABLE vol_rx AS
SELECT encounter_id, k, facility_id, started_at, ended_at, clinician_id,
       (SELECT max(prescription_id) FROM prescription) + row_number() OVER (ORDER BY encounter_id) AS prescription_id
  FROM (SELECT DISTINCT encounter_id, k, facility_id, started_at, ended_at, clinician_id FROM vol_item) s;
CREATE UNIQUE INDEX ON vol_rx (encounter_id);

INSERT INTO prescription (prescription_id, encounter_id, prescriber_id, issued_at)
OVERRIDING SYSTEM VALUE
SELECT prescription_id, encounter_id, clinician_id, started_at + interval '15 minutes' FROM vol_rx ORDER BY prescription_id;

INSERT INTO prescription_item (prescription_id, drug_id, quantity, dosage)
SELECT r.prescription_id, i.drug_id, i.quantity, i.dosage
  FROM vol_item i JOIN vol_rx r USING (encounter_id)
 ORDER BY r.prescription_id, i.drug_id;

CREATE TEMP TABLE vol_dispense AS
SELECT i.facility_id, i.drug_id, i.quantity, r.prescription_id, i.ended_at + interval '10 minutes' AS moved_at,
       fs.staff_id AS moved_by
  FROM vol_item i JOIN vol_rx r USING (encounter_id)
  JOIN fac_staff fs ON fs.facility_id = i.facility_id AND fs.staff_role_code = 'PHARMACIST'
 WHERE pg_temp.u(i.k * 4 + i.drug_id, 261) < 0.93
   AND i.ended_at + interval '10 minutes' < timestamptz '2026-11-14 12:00+01';

-- deliveries arrive on the first of each month and cover that month's dispensing plus a branch-specific margin,
-- so the ledger never dips below zero and some lines end below their reorder level

INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_at, moved_by, note)
SELECT m.facility_id, m.drug_id, 'RECEIPT',
       m.dispensed + 1 + floor(dr.reorder_level * 0.10 * pg_temp.u(m.facility_id * 100 + m.drug_id, 270))::int,
       (m.month + time '07:00') AT TIME ZONE 'Africa/Lagos', fs.staff_id, 'Monthly delivery'
  FROM (SELECT facility_id, drug_id, date_trunc('month', moved_at AT TIME ZONE 'Africa/Lagos') AS month,
               sum(quantity) AS dispensed
          FROM vol_dispense GROUP BY 1, 2, 3) m
  JOIN drug dr USING (drug_id)
  JOIN fac_staff fs ON fs.facility_id = m.facility_id AND fs.staff_role_code = 'PHARMACIST'
 ORDER BY 5, 1, 2;

INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_at, moved_by, prescription_id)
SELECT facility_id, drug_id, 'DISPENSE', quantity, moved_at, moved_by, prescription_id
  FROM vol_dispense ORDER BY moved_at, prescription_id, drug_id;

INSERT INTO stock_on_hand (facility_id, drug_id, quantity, updated_at)
SELECT m.facility_id, m.drug_id, sum(mt.direction * m.quantity), max(m.moved_at)
  FROM stock_movement m JOIN movement_type mt USING (movement_type_code)
 GROUP BY m.facility_id, m.drug_id
ON CONFLICT (facility_id, drug_id) DO UPDATE SET quantity = EXCLUDED.quantity, updated_at = EXCLUDED.updated_at;

-- laboratory: about 30% of visits order a test chosen by the diagnosis; results arrive after a skewed turnaround

CREATE TEMP TABLE vol_order AS
SELECT x.encounter_id, x.k, x.clinician_id, fw.lab_facility_id AS facility_id, t.lab_test_id, t.unit, t.test_code,
       t.target_turnaround, x.started_at + interval '10 minutes' AS ordered_at, x.primary_code
  FROM vol_dx x
  JOIN fac_weight fw ON fw.facility_id = x.facility_id
  JOIN lab_test t ON t.test_code = CASE x.primary_code
                                     WHEN 'B54' THEN 'LT-MPRDT' WHEN 'B50.0' THEN 'LT-MPRDT' WHEN 'A01.0' THEN 'LT-WIDAL'
                                     WHEN 'E11.9' THEN 'LT-FBG' WHEN 'I10' THEN 'LT-CREAT' WHEN 'D50.9' THEN 'LT-HB'
                                     WHEN 'N39.0' THEN 'LT-URINE' WHEN 'E78.5' THEN 'LT-CHOL' ELSE 'LT-HB' END
 WHERE pg_temp.u(x.k, 280) < CASE WHEN x.chronic THEN 0.5 ELSE 0.25 END;

ALTER TABLE vol_order ADD COLUMN lab_order_id bigint;
UPDATE vol_order o SET lab_order_id = s.base + s.rn
  FROM (SELECT encounter_id, row_number() OVER (ORDER BY ordered_at, encounter_id) AS rn,
               (SELECT max(lab_order_id) FROM lab_order) AS base FROM vol_order) s
 WHERE s.encounter_id = o.encounter_id;

INSERT INTO lab_order (lab_order_id, encounter_id, lab_test_id, facility_id, ordered_by, ordered_at)
OVERRIDING SYSTEM VALUE
SELECT lab_order_id, encounter_id, lab_test_id, facility_id, clinician_id, ordered_at FROM vol_order ORDER BY lab_order_id;

CREATE TEMP TABLE vol_result AS
SELECT o.lab_order_id, o.k, o.facility_id,
       o.ordered_at + o.target_turnaround * (0.2 + 1.2 * pg_temp.u(o.k, 281) ^ 2) AS recorded_at,
       CASE WHEN o.unit IS NOT NULL THEN round(CASE o.test_code
              WHEN 'LT-HB' THEN 8 + 8 * pg_temp.u(o.k, 282)
              WHEN 'LT-FBG' THEN 3.5 + 10.5 * pg_temp.u(o.k, 282) ^ 1.5
              WHEN 'LT-HBA1C' THEN 4.5 + 6.5 * pg_temp.u(o.k, 282) ^ 1.5
              WHEN 'LT-CREAT' THEN 50 + 170 * pg_temp.u(o.k, 282) ^ 2
              ELSE 3 + 5 * pg_temp.u(o.k, 282) END::numeric, 1) END AS value_numeric,
       CASE o.test_code
         WHEN 'LT-MPRDT' THEN CASE WHEN pg_temp.u(o.k, 283) < 0.6 THEN 'Positive (P. falciparum)' ELSE 'Negative' END
         WHEN 'LT-WIDAL' THEN CASE WHEN pg_temp.u(o.k, 283) < 0.5 THEN 'Reactive, O antigen 1:160' ELSE 'Non-reactive' END
         WHEN 'LT-URINE' THEN CASE WHEN pg_temp.u(o.k, 283) < 0.6 THEN 'Nitrite positive, leucocytes ++' ELSE 'Normal' END
       END AS value_text
  FROM vol_order o;

INSERT INTO lab_result (lab_order_id, recorded_at, recorded_by, value_numeric, value_text)
SELECT r.lab_order_id, r.recorded_at, fs.staff_id, r.value_numeric, r.value_text
  FROM vol_result r JOIN fac_staff fs ON fs.facility_id = r.facility_id AND fs.staff_role_code = 'LAB_SCIENTIST'
 WHERE r.recorded_at < timestamptz '2026-11-14 12:00+01'
 ORDER BY r.recorded_at, r.lab_order_id;

INSERT INTO lab_result (lab_order_id, recorded_at, recorded_by, value_numeric, value_text, supersedes_result_id, correction_reason)
SELECT lr.lab_order_id, lr.recorded_at + interval '45 minutes', lr.recorded_by,
       CASE WHEN lr.value_numeric IS NOT NULL THEN round(lr.value_numeric * 0.9, 1) END,
       CASE WHEN lr.value_text IS NOT NULL THEN lr.value_text || ' (repeat sample)' END,
       lr.lab_result_id, 'Repeat test on a fresh sample'
  FROM lab_result lr JOIN vol_result r USING (lab_order_id)
 WHERE pg_temp.u(r.k, 284) < 0.004
 ORDER BY lr.lab_result_id;

-- billing for the most recent 90 days only

CREATE TEMP TABLE vol_invoice AS
SELECT e.encounter_id, e.k, e.patient_id, e.facility_id, e.ended_at + interval '15 minutes' AS issued_at, fs.staff_id AS issued_by,
       'INV-' || lpad((1000000 + row_number() OVER (ORDER BY e.ended_at, e.encounter_id))::text, 8, '0') AS invoice_no,
       (SELECT max(invoice_id) FROM invoice) + row_number() OVER (ORDER BY e.ended_at, e.encounter_id) AS invoice_id
  FROM vol_enc e JOIN fac_staff fs ON fs.facility_id = e.facility_id AND fs.staff_role_code = 'BILLING_OFFICER'
 WHERE e.started_at >= timestamptz '2026-08-16 00:00+01' AND e.ended_at < timestamptz '2026-11-14 11:00+01';

CREATE TEMP TABLE vol_line AS
SELECT v.invoice_id, row_number() OVER (PARTITION BY v.invoice_id ORDER BY l.sort_key, l.item_id)::smallint AS line_no,
       l.description, l.drug_id, l.lab_test_id, l.quantity, l.unit_price_kobo
  FROM vol_invoice v
  JOIN (
   SELECT encounter_id, 0 AS sort_key, 0::bigint AS item_id, 'Consultation' AS description, NULL::bigint AS drug_id,
          NULL::bigint AS lab_test_id, 1 AS quantity, 500000::bigint AS unit_price_kobo
     FROM vol_invoice
   UNION ALL
   SELECT i.encounter_id, 1, d.drug_id, d.name || ' ' || d.strength || ' ' || d.form, d.drug_id, NULL, i.quantity, d.unit_price_kobo
     FROM vol_item i JOIN drug d USING (drug_id)
   UNION ALL
   SELECT o.encounter_id, 2, t.lab_test_id, t.name, NULL, t.lab_test_id, 1, t.price_kobo
     FROM vol_order o JOIN lab_test t USING (lab_test_id)
 ) l USING (encounter_id);

INSERT INTO invoice (invoice_id, invoice_no, patient_id, facility_id, encounter_id, issued_at, issued_by, total_kobo)
OVERRIDING SYSTEM VALUE
SELECT v.invoice_id, v.invoice_no, v.patient_id, v.facility_id, v.encounter_id, v.issued_at, v.issued_by, t.total_kobo
  FROM vol_invoice v
  JOIN (SELECT invoice_id, sum(quantity * unit_price_kobo) AS total_kobo FROM vol_line GROUP BY invoice_id) t USING (invoice_id)
 ORDER BY v.invoice_id;

INSERT INTO invoice_line (invoice_id, line_no, description, drug_id, lab_test_id, quantity, unit_price_kobo)
SELECT invoice_id, line_no, description, drug_id, lab_test_id, quantity, unit_price_kobo
  FROM vol_line ORDER BY invoice_id, line_no;

INSERT INTO payment (invoice_id, payment_method_code, amount_kobo, paid_at, received_by, reference)
SELECT i.invoice_id, m.method,
       CASE WHEN pg_temp.u(v.k, 290) < 0.88 THEN i.total_kobo ELSE i.total_kobo / 2 END,
       i.issued_at + interval '5 minutes', i.issued_by,
       CASE WHEN m.method <> 'CASH' THEN m.prefix || lpad((v.k % 1000000)::text, 6, '0') END
  FROM invoice i JOIN vol_invoice v USING (invoice_id)
 CROSS JOIN LATERAL (SELECT CASE WHEN pg_temp.u(v.k, 291) < 0.40 THEN 'CASH' WHEN pg_temp.u(v.k, 291) < 0.70 THEN 'CARD'
                                 WHEN pg_temp.u(v.k, 291) < 0.90 THEN 'HMO' ELSE 'TRANSFER' END AS method) mm
 CROSS JOIN LATERAL (SELECT mm.method, CASE mm.method WHEN 'CARD' THEN 'POS-' WHEN 'HMO' THEN 'HMO-CLAIM-' ELSE 'TRF-' END AS prefix) m
 WHERE pg_temp.u(v.k, 292) < 0.95
 ORDER BY i.invoice_id;

-- record access and the on-call rota

INSERT INTO record_access_log (staff_id, patient_id, accessed_at, purpose, db_user)
SELECT e.clinician_id, e.patient_id, e.started_at - interval '3 minutes', 'Consultation', 'clinic_app'
  FROM vol_enc e WHERE pg_temp.u(e.k, 300) < 0.30
 ORDER BY e.started_at, e.encounter_id;

INSERT INTO on_call_shift (facility_id, clinician_id, shift_date, on_call)
SELECT c.facility_id, c.clinician_id, d::date, true
  FROM generate_series(DATE '2026-09-15', DATE '2026-11-14', interval '1 day') d
  JOIN LATERAL (SELECT facility_id, clinician_id,
                       row_number() OVER (PARTITION BY facility_id ORDER BY pg_temp.u(clinician_id * 1000 + (d::date - DATE '2026-01-01'), 310)) AS slot
                  FROM vol_clinician) c ON c.slot <= 2
 ORDER BY 3, 1, 2;

-- restore the sequences, the triggers and every constraint (re-validated against all rows)

DO $$
DECLARE
  r record;
  top bigint;
BEGIN
  FOR r IN SELECT c.relname, a.attname
             FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'itoju' AND a.attidentity <> '' AND c.relkind = 'r' LOOP
    EXECUTE format('SELECT max(%I) FROM itoju.%I', r.attname, r.relname) INTO top;
    IF top IS NOT NULL THEN
      PERFORM setval(pg_get_serial_sequence(format('itoju.%I', r.relname), r.attname), top);
    END IF;
  END LOOP;
END $$;
SELECT setval('patient_hospital_no_seq', (SELECT max(substr(hospital_no, 4)::int) FROM patient));
SELECT setval('invoice_no_seq', (SELECT max(substr(invoice_no, 5)::int) FROM invoice));

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'itoju' AND NOT t.tgisinternal LOOP
    EXECUTE format('ALTER TABLE %I ENABLE TRIGGER USER', r.relname);
  END LOOP;
  FOR r IN SELECT * FROM held_constraint ORDER BY contype DESC, table_name, conname LOOP
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', r.table_name, r.conname, r.definition);
  END LOOP;
END $$;

SELECT contype AS kind, count(*) AS constraints_revalidated FROM held_constraint GROUP BY contype ORDER BY contype;

COMMIT;
\timing off

RESET ROLE;
VACUUM (ANALYZE);

SELECT relname AS table_name, n_live_tup AS rows
  FROM pg_stat_user_tables WHERE schemaname = 'itoju' ORDER BY n_live_tup DESC;

\echo '== Data fingerprint: a hash of every row, identical on every rebuild'
SET TimeZone = 'UTC';
SELECT 'patient' AS table_name, count(*) AS rows, sum(hashtext(t::text)::bigint) AS fingerprint FROM itoju.patient t
UNION ALL SELECT 'staff', count(*), sum(hashtext(t::text)::bigint) FROM itoju.staff t
UNION ALL SELECT 'appointment', count(*), sum(hashtext(t::text)::bigint) FROM itoju.appointment t
UNION ALL SELECT 'encounter', count(*), sum(hashtext(t::text)::bigint) FROM itoju.encounter t
UNION ALL SELECT 'encounter_diagnosis', count(*), sum(hashtext(t::text)::bigint) FROM itoju.encounter_diagnosis t
UNION ALL SELECT 'prescription_item', count(*), sum(hashtext(t::text)::bigint) FROM itoju.prescription_item t
UNION ALL SELECT 'stock_movement', count(*), sum(hashtext(t::text)::bigint) FROM itoju.stock_movement t
UNION ALL SELECT 'lab_result', count(*), sum(hashtext(t::text)::bigint) FROM itoju.lab_result t
UNION ALL SELECT 'invoice_line', count(*), sum(hashtext(t::text)::bigint) FROM itoju.invoice_line t
UNION ALL SELECT 'payment', count(*), sum(hashtext(t::text)::bigint) FROM itoju.payment t;
