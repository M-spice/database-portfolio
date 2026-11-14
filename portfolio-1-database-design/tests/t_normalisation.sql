\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
SET ROLE itoju_owner;
SET search_path = itoju, public;

\echo '== The unnormalised clinic visit report (one row per visit, repeating groups as lists)'
CREATE TEMP TABLE visit_report AS
SELECT e.encounter_id AS visit_no,
       (e.started_at AT TIME ZONE 'Africa/Lagos')::date AS visit_date,
       p.hospital_no,
       concat_ws(' ', p.given_name, p.family_name) AS patient_name,
       p.date_of_birth,
       (SELECT string_agg(ph.phone_no, ', ' ORDER BY ph.phone_no) FROM patient_phone ph WHERE ph.patient_id = p.patient_id) AS phones,
       f.facility_code, f.name AS facility_name, f.city AS facility_city,
       s.staff_no AS clinician_no, concat_ws(' ', s.given_name, s.family_name) AS clinician_name,
       (SELECT string_agg(d.diagnosis_code || ' ' || dc.description, '; ' ORDER BY d.diagnosis_code)
          FROM encounter_diagnosis d JOIN diagnosis_code dc USING (diagnosis_code)
         WHERE d.encounter_id = e.encounter_id) AS diagnoses,
       (SELECT string_agg(dr.drug_code || ' ' || dr.name || ' x' || pi.quantity || ' @ ' || dr.unit_price_kobo, '; '
                          ORDER BY dr.drug_code)
          FROM prescription rx JOIN prescription_item pi USING (prescription_id) JOIN drug dr USING (drug_id)
         WHERE rx.encounter_id = e.encounter_id) AS drugs
  FROM encounter e
  JOIN patient p USING (patient_id)
  JOIN facility f ON f.facility_id = e.facility_id
  JOIN staff s ON s.staff_id = e.clinician_id;

\x on
SELECT * FROM visit_report ORDER BY visit_no LIMIT 3;
\x off

\echo '== 1NF: repeating groups split out of the report itself'
CREATE TEMP TABLE visit_1nf AS
SELECT visit_no, visit_date, hospital_no, patient_name, date_of_birth,
       facility_code, facility_name, facility_city, clinician_no, clinician_name
  FROM visit_report;

CREATE TEMP TABLE patient_phone_1nf AS
SELECT DISTINCT r.hospital_no, btrim(ph) AS phone_no
  FROM visit_report r CROSS JOIN LATERAL unnest(string_to_array(r.phones, ',')) ph;

CREATE TEMP TABLE visit_diagnosis_1nf AS
SELECT r.visit_no, split_part(btrim(item), ' ', 1) AS diagnosis_code,
       substr(btrim(item), length(split_part(btrim(item), ' ', 1)) + 2) AS diagnosis_description
  FROM visit_report r CROSS JOIN LATERAL unnest(string_to_array(r.diagnoses, ';')) item;

CREATE TEMP TABLE visit_drug_1nf AS
SELECT r.visit_no, m[1] AS drug_code, m[2] AS drug_name, m[3]::int AS quantity, m[4]::bigint AS unit_price_kobo
  FROM visit_report r
  CROSS JOIN LATERAL unnest(string_to_array(r.drugs, ';')) item
  CROSS JOIN LATERAL regexp_match(btrim(item), '^(\S+) (.+) x([0-9]+) @ ([0-9]+)$') m;

SELECT 'visit_1nf' AS relation, count(*) AS rows FROM visit_1nf
UNION ALL SELECT 'patient_phone_1nf', count(*) FROM patient_phone_1nf
UNION ALL SELECT 'visit_diagnosis_1nf', count(*) FROM visit_diagnosis_1nf
UNION ALL SELECT 'visit_drug_1nf', count(*) FROM visit_drug_1nf;

\echo '== Functional dependencies tested against the data (violations must be 0)'
CREATE TEMP TABLE fd_check AS
SELECT * FROM (VALUES
  ('visit_no -> visit_date, hospital_no, facility_code, clinician_no',
   (SELECT count(*) FROM (SELECT visit_no FROM visit_1nf GROUP BY visit_no
                           HAVING count(DISTINCT (visit_date, hospital_no, facility_code, clinician_no)) > 1) g)),
  ('hospital_no -> patient_name, date_of_birth',
   (SELECT count(*) FROM (SELECT hospital_no FROM visit_1nf GROUP BY hospital_no
                           HAVING count(DISTINCT (patient_name, date_of_birth)) > 1) g)),
  ('facility_code -> facility_name, facility_city',
   (SELECT count(*) FROM (SELECT facility_code FROM visit_1nf GROUP BY facility_code
                           HAVING count(DISTINCT (facility_name, facility_city)) > 1) g)),
  ('clinician_no -> clinician_name',
   (SELECT count(*) FROM (SELECT clinician_no FROM visit_1nf GROUP BY clinician_no
                           HAVING count(DISTINCT clinician_name) > 1) g)),
  ('diagnosis_code -> diagnosis_description',
   (SELECT count(*) FROM (SELECT diagnosis_code FROM visit_diagnosis_1nf GROUP BY diagnosis_code
                           HAVING count(DISTINCT diagnosis_description) > 1) g)),
  ('drug_code -> drug_name, unit_price_kobo',
   (SELECT count(*) FROM (SELECT drug_code FROM visit_drug_1nf GROUP BY drug_code
                           HAVING count(DISTINCT (drug_name, unit_price_kobo)) > 1) g)),
  ('visit_no, drug_code -> quantity',
   (SELECT count(*) FROM (SELECT visit_no, drug_code FROM visit_drug_1nf GROUP BY visit_no, drug_code
                           HAVING count(DISTINCT quantity) > 1) g))
) AS t (dependency, violations);
SELECT dependency, violations, CASE WHEN violations = 0 THEN 'holds' ELSE 'BROKEN' END AS result FROM fd_check;

\echo '== Redundancy that the decomposition removes (copies of each fact in the 1NF relations)'
SELECT 'facility name and city' AS fact, count(*) AS stored_copies, count(DISTINCT facility_code) AS distinct_facts FROM visit_1nf
UNION ALL SELECT 'patient name and date of birth', count(*), count(DISTINCT hospital_no) FROM visit_1nf
UNION ALL SELECT 'clinician name', count(*), count(DISTINCT clinician_no) FROM visit_1nf
UNION ALL SELECT 'drug name and price', count(*), count(DISTINCT drug_code) FROM visit_drug_1nf
UNION ALL SELECT 'diagnosis description', count(*), count(DISTINCT diagnosis_code) FROM visit_diagnosis_1nf;

\echo '== BCNF relations projected from the 1NF relations'
CREATE TEMP TABLE r_patient AS SELECT DISTINCT hospital_no, patient_name, date_of_birth FROM visit_1nf;
CREATE TEMP TABLE r_facility AS SELECT DISTINCT facility_code, facility_name, facility_city FROM visit_1nf;
CREATE TEMP TABLE r_clinician AS SELECT DISTINCT clinician_no, clinician_name FROM visit_1nf;
CREATE TEMP TABLE r_visit AS SELECT visit_no, visit_date, hospital_no, facility_code, clinician_no FROM visit_1nf;
CREATE TEMP TABLE r_diagnosis AS SELECT DISTINCT diagnosis_code, diagnosis_description FROM visit_diagnosis_1nf;
CREATE TEMP TABLE r_visit_diagnosis AS SELECT visit_no, diagnosis_code FROM visit_diagnosis_1nf;
CREATE TEMP TABLE r_drug AS SELECT DISTINCT drug_code, drug_name, unit_price_kobo FROM visit_drug_1nf;
CREATE TEMP TABLE r_visit_drug AS SELECT visit_no, drug_code, quantity FROM visit_drug_1nf;
CREATE TEMP TABLE r_patient_phone AS SELECT hospital_no, phone_no FROM patient_phone_1nf;

CREATE TEMP TABLE key_check AS
SELECT * FROM (VALUES
  ('patient (hospital_no)',                 (SELECT count(*) - count(DISTINCT hospital_no) FROM r_patient)),
  ('facility (facility_code)',              (SELECT count(*) - count(DISTINCT facility_code) FROM r_facility)),
  ('clinician (clinician_no)',              (SELECT count(*) - count(DISTINCT clinician_no) FROM r_clinician)),
  ('visit (visit_no)',                      (SELECT count(*) - count(DISTINCT visit_no) FROM r_visit)),
  ('diagnosis (diagnosis_code)',            (SELECT count(*) - count(DISTINCT diagnosis_code) FROM r_diagnosis)),
  ('visit_diagnosis (visit_no, code)',      (SELECT count(*) - count(DISTINCT (visit_no, diagnosis_code)) FROM r_visit_diagnosis)),
  ('drug (drug_code)',                      (SELECT count(*) - count(DISTINCT drug_code) FROM r_drug)),
  ('visit_drug (visit_no, drug_code)',      (SELECT count(*) - count(DISTINCT (visit_no, drug_code)) FROM r_visit_drug)),
  ('patient_phone (hospital_no, phone_no)', (SELECT count(*) - count(DISTINCT (hospital_no, phone_no)) FROM r_patient_phone))
) AS t (relation_and_key, duplicate_keys);
SELECT relation_and_key, duplicate_keys, CASE WHEN duplicate_keys = 0 THEN 'key holds' ELSE 'BROKEN' END AS result FROM key_check;

\echo '== Lossless join: rejoin the BCNF relations and compare with what was decomposed'
CREATE TEMP TABLE lossless AS
WITH visit_rejoined AS (
  SELECT v.visit_no, v.visit_date, v.hospital_no, p.patient_name, p.date_of_birth,
         v.facility_code, f.facility_name, f.facility_city, v.clinician_no, c.clinician_name
    FROM r_visit v JOIN r_patient p USING (hospital_no) JOIN r_facility f USING (facility_code)
    JOIN r_clinician c USING (clinician_no)
), diagnosis_rejoined AS (
  SELECT vd.visit_no, vd.diagnosis_code, d.diagnosis_description FROM r_visit_diagnosis vd JOIN r_diagnosis d USING (diagnosis_code)
), drug_rejoined AS (
  SELECT vd.visit_no, vd.drug_code, d.drug_name, vd.quantity, d.unit_price_kobo FROM r_visit_drug vd JOIN r_drug d USING (drug_code)
), report_rebuilt AS (
  SELECT v.visit_no, v.visit_date, v.hospital_no, v.patient_name, v.date_of_birth,
         (SELECT string_agg(ph.phone_no, ', ' ORDER BY ph.phone_no) FROM r_patient_phone ph WHERE ph.hospital_no = v.hospital_no),
         v.facility_code, v.facility_name, v.facility_city, v.clinician_no, v.clinician_name,
         (SELECT string_agg(d.diagnosis_code || ' ' || d.diagnosis_description, '; ' ORDER BY d.diagnosis_code)
            FROM diagnosis_rejoined d WHERE d.visit_no = v.visit_no),
         (SELECT string_agg(d.drug_code || ' ' || d.drug_name || ' x' || d.quantity || ' @ ' || d.unit_price_kobo, '; '
                            ORDER BY d.drug_code)
            FROM drug_rejoined d WHERE d.visit_no = v.visit_no)
    FROM visit_rejoined v
)
SELECT * FROM (VALUES
  ('visit ⋈ patient ⋈ facility ⋈ clinician = visit_1nf',
   (SELECT count(*) FROM visit_1nf), (SELECT count(*) FROM visit_rejoined),
   (SELECT count(*) FROM (SELECT * FROM visit_1nf EXCEPT ALL SELECT * FROM visit_rejoined) x)
     + (SELECT count(*) FROM (SELECT * FROM visit_rejoined EXCEPT ALL SELECT * FROM visit_1nf) x)),
  ('visit_diagnosis ⋈ diagnosis = visit_diagnosis_1nf',
   (SELECT count(*) FROM visit_diagnosis_1nf), (SELECT count(*) FROM diagnosis_rejoined),
   (SELECT count(*) FROM (SELECT * FROM visit_diagnosis_1nf EXCEPT ALL SELECT * FROM diagnosis_rejoined) x)
     + (SELECT count(*) FROM (SELECT * FROM diagnosis_rejoined EXCEPT ALL SELECT * FROM visit_diagnosis_1nf) x)),
  ('visit_drug ⋈ drug = visit_drug_1nf',
   (SELECT count(*) FROM visit_drug_1nf), (SELECT count(*) FROM drug_rejoined),
   (SELECT count(*) FROM (SELECT visit_no, drug_code, drug_name, quantity, unit_price_kobo FROM visit_drug_1nf
                          EXCEPT ALL SELECT * FROM drug_rejoined) x)
     + (SELECT count(*) FROM (SELECT * FROM drug_rejoined
                              EXCEPT ALL SELECT visit_no, drug_code, drug_name, quantity, unit_price_kobo FROM visit_drug_1nf) x)),
  ('all BCNF relations rebuild the original report',
   (SELECT count(*) FROM visit_report), (SELECT count(*) FROM report_rebuilt),
   (SELECT count(*) FROM (SELECT * FROM visit_report EXCEPT ALL SELECT * FROM report_rebuilt) x)
     + (SELECT count(*) FROM (SELECT * FROM report_rebuilt EXCEPT ALL SELECT * FROM visit_report) x))
) AS t (join_tested, rows_before, rows_after, differing_rows);
SELECT join_tested, rows_before, rows_after, differing_rows,
       CASE WHEN differing_rows = 0 AND rows_before = rows_after THEN 'lossless' ELSE 'LOSSY' END AS result
  FROM lossless;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM fd_check WHERE violations > 0)
     OR EXISTS (SELECT 1 FROM key_check WHERE duplicate_keys > 0)
     OR EXISTS (SELECT 1 FROM lossless WHERE differing_rows > 0 OR rows_before <> rows_after) THEN
    RAISE EXCEPTION 'normalisation check failed';
  END IF;
END $$;
