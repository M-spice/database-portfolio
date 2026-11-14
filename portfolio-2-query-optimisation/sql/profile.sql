\set ON_ERROR_STOP on
\pset footer off
SET search_path = itoju, public;

\echo '== Visits per patient: the skew the optimiser has to cope with'
SELECT count(*) AS patients_with_visits,
       count(*) FILTER (WHERE n = 1) AS single_visit_patients,
       percentile_disc(0.1) WITHIN GROUP (ORDER BY n) AS p10,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY n) AS median,
       percentile_disc(0.9) WITHIN GROUP (ORDER BY n) AS p90,
       percentile_disc(0.99) WITHIN GROUP (ORDER BY n) AS p99,
       max(n) AS busiest_patient
  FROM (SELECT patient_id, count(*) AS n FROM encounter GROUP BY patient_id) s;

\echo '== Encounters per branch'
SELECT f.facility_code, count(*) AS encounters
  FROM encounter e JOIN facility f USING (facility_id)
 GROUP BY f.facility_code ORDER BY encounters DESC;

\echo '== Encounter types (selectivity of the Q10 filter)'
SELECT encounter_type_code, count(*) AS encounters, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS percent
  FROM encounter GROUP BY encounter_type_code ORDER BY encounters DESC;

\echo '== The parameters used by Q02 and Q03'
SELECT 'Q02 patient' AS used_by, p.hospital_no AS key, count(*) AS rows
  FROM encounter e JOIN patient p USING (patient_id)
 WHERE p.hospital_no = 'HN-0100046' GROUP BY p.hospital_no
UNION ALL
SELECT 'Q03 clinician, active appointments on 16 Nov 2026', s.staff_no, count(*)
  FROM appointment a JOIN staff s ON s.staff_id = a.clinician_id
 WHERE s.staff_no = 'ST-01100' AND a.appointment_status_code <> 'CANCELLED'
   AND a.slot && tstzrange('2026-11-16 00:00+01', '2026-11-17 00:00+01')
 GROUP BY s.staff_no;
