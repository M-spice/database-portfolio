-- Q01 | Find a patient by phone number
SELECT p.hospital_no, p.given_name, p.family_name, p.date_of_birth, ph.phone_no
  FROM patient_phone ph
  JOIN patient p USING (patient_id)
 WHERE ph.phone_no = '+2340100104242';

-- Q02 | Patient timeline: latest 20 encounters with diagnoses
SELECT e.started_at, f.facility_code, e.encounter_type_code,
       (SELECT string_agg(d.diagnosis_code, ', ' ORDER BY d.is_primary DESC, d.diagnosis_code)
          FROM encounter_diagnosis d
         WHERE d.encounter_id = e.encounter_id) AS diagnoses
  FROM encounter e
  JOIN facility f USING (facility_id)
 WHERE e.patient_id = (SELECT patient_id FROM patient WHERE hospital_no = 'HN-0100046')
 ORDER BY e.started_at DESC
 LIMIT 20;

-- Q03 | A clinician's schedule for one day (active appointments)
SELECT lower(a.slot) AS starts, p.hospital_no, p.given_name, p.family_name, a.appointment_status_code
  FROM appointment a
  JOIN patient p USING (patient_id)
 WHERE a.clinician_id = (SELECT staff_id FROM staff WHERE staff_no = 'ST-01100')
   AND a.slot && tstzrange('2026-11-16 00:00+01', '2026-11-17 00:00+01')
   AND a.appointment_status_code <> 'CANCELLED'
 ORDER BY lower(a.slot);

-- Q03b | A clinician's schedule for one day (every status, including cancelled)
SELECT lower(a.slot) AS starts, p.hospital_no, p.given_name, p.family_name, a.appointment_status_code
  FROM appointment a
  JOIN patient p USING (patient_id)
 WHERE a.clinician_id = (SELECT staff_id FROM staff WHERE staff_no = 'ST-01100')
   AND a.slot && tstzrange('2026-11-16 00:00+01', '2026-11-17 00:00+01')
 ORDER BY lower(a.slot);

-- Q04 | Free 30-minute General Practice slots at Ikeja on one day
WITH grid AS (
  SELECT cd.clinician_id, gs AS starts
    FROM clinician_department cd
    JOIN department d USING (department_id)
    JOIN staff s ON s.staff_id = cd.clinician_id
   CROSS JOIN generate_series(timestamptz '2026-11-16 08:00+01', timestamptz '2026-11-16 15:30+01',
                              interval '30 minutes') gs
   WHERE d.department_code = 'GP'
     AND s.home_facility_id = (SELECT facility_id FROM facility WHERE facility_code = 'LAG-IKJ')
)
SELECT g.clinician_id, g.starts
  FROM grid g
 WHERE NOT EXISTS (SELECT 1
                     FROM appointment a
                    WHERE a.clinician_id = g.clinician_id
                      AND a.appointment_status_code <> 'CANCELLED'
                      AND a.slot && tstzrange(g.starts, g.starts + interval '30 minutes'))
 ORDER BY g.starts, g.clinician_id;

-- Q05 | Monthly diagnosis counts per branch over the last year
SELECT facility_code, month, diagnosis_code, cases
  FROM monthly_diagnosis
 WHERE month >= '2025-11-01' AND month < '2026-11-01'
   AND cases >= 20
 ORDER BY 1, 2, 4 DESC, 3;

-- Q06 | Pharmacy reorder report with the last 30 days of dispensing
SELECT f.facility_code, dr.drug_code, dr.name, s.quantity AS on_hand, dr.reorder_level,
       (SELECT coalesce(sum(m.quantity), 0)
          FROM stock_movement m
         WHERE m.facility_id = s.facility_id AND m.drug_id = s.drug_id
           AND m.movement_type_code = 'DISPENSE'
           AND m.moved_at >= '2026-10-15 00:00+01' AND m.moved_at < '2026-11-14 00:00+01') AS dispensed_30d
  FROM stock_on_hand s
  JOIN drug dr USING (drug_id)
  JOIN facility f USING (facility_id)
 WHERE s.quantity < dr.reorder_level
 ORDER BY f.facility_code, dr.drug_code;

-- Q07 | Laboratory turnaround by test over the last 30 days
SELECT t.test_code,
       count(*) AS results,
       round(avg(extract(epoch FROM r.recorded_at - o.ordered_at) / 3600)::numeric, 2) AS avg_hours,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY extract(epoch FROM r.recorded_at - o.ordered_at) / 3600)::numeric, 2) AS p90_hours,
       count(*) FILTER (WHERE r.recorded_at - o.ordered_at > t.target_turnaround) AS late
  FROM lab_order o
  JOIN lab_result r ON r.lab_order_id = o.lab_order_id AND r.supersedes_result_id IS NULL
  JOIN lab_test t ON t.lab_test_id = o.lab_test_id
 WHERE o.ordered_at >= '2026-10-15 00:00+01' AND o.ordered_at < '2026-11-14 00:00+01'
 GROUP BY t.test_code
 ORDER BY t.test_code;

-- Q08 | Patients with no visit in the last 12 months
SELECT p.hospital_no
  FROM patient p
 WHERE NOT EXISTS (SELECT 1 FROM encounter e
                    WHERE e.patient_id = p.patient_id AND e.started_at >= '2025-11-14 00:00+01')
 ORDER BY p.hospital_no;

-- Q08b | Patients with no visit in the last 12 months
-- set work_mem = '64MB'
SELECT p.hospital_no
  FROM patient p
 WHERE p.patient_id NOT IN (SELECT e.patient_id FROM encounter e WHERE e.started_at >= '2025-11-14 00:00+01')
 ORDER BY p.hospital_no;

-- Q09 | Frequent attenders: five or more visits in 30 days
SELECT p.hospital_no, count(*) AS visits
  FROM encounter e
  JOIN patient p USING (patient_id)
 WHERE e.started_at >= '2026-10-15 00:00+01' AND e.started_at < '2026-11-14 00:00+01'
 GROUP BY p.hospital_no
HAVING count(*) >= 5
 ORDER BY visits DESC, p.hospital_no;

-- Q10 | Average length of a consultation (matches most encounters)
SELECT encounter_type_code, count(*) AS encounters,
       round(avg(extract(epoch FROM ended_at - started_at) / 60)::numeric, 2) AS avg_minutes
  FROM encounter
 WHERE encounter_type_code = 'CONSULTATION'
 GROUP BY encounter_type_code;

-- Q11 | Reconcile every stock line against the movement ledger
SELECT count(*) AS stock_lines,
       count(*) FILTER (WHERE s.quantity IS DISTINCT FROM l.quantity) AS mismatches
  FROM stock_on_hand s
  FULL JOIN (SELECT m.facility_id, m.drug_id, sum(mt.direction * m.quantity) AS quantity
               FROM stock_movement m
               JOIN movement_type mt USING (movement_type_code)
              GROUP BY m.facility_id, m.drug_id) l USING (facility_id, drug_id);

-- Q12 | Stock on hand at Ikeja, read from the cached totals
SELECT d.drug_code, s.quantity
  FROM stock_on_hand s
  JOIN drug d USING (drug_id)
 WHERE s.facility_id = (SELECT facility_id FROM facility WHERE facility_code = 'LAG-IKJ')
 ORDER BY d.drug_code;

-- Q13 | Stock on hand at Ikeja, recomputed from the ledger
SELECT d.drug_code, sum(mt.direction * m.quantity) AS quantity
  FROM stock_movement m
  JOIN movement_type mt USING (movement_type_code)
  JOIN drug d USING (drug_id)
 WHERE m.facility_id = (SELECT facility_id FROM facility WHERE facility_code = 'LAG-IKJ')
 GROUP BY d.drug_code
 ORDER BY d.drug_code;
