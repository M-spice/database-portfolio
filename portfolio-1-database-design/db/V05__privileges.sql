SET ROLE itoju_owner;
SET search_path = itoju, public;

CREATE VIEW patient_directory AS
SELECT p.patient_id,
       p.hospital_no,
       p.given_name,
       p.middle_name,
       p.family_name,
       p.date_of_birth,
       (SELECT ph.phone_no FROM patient_phone ph WHERE ph.patient_id = p.patient_id AND ph.is_primary) AS primary_phone,
       f.facility_code AS registered_facility
  FROM patient p
  JOIN facility f ON f.facility_id = p.registered_facility_id;

CREATE VIEW deid_patient AS
SELECT encode(substr(sha256(k.secret || int8send(p.patient_id)), 1, 8), 'hex') AS patient_key,
       age_band(p.date_of_birth, current_date) AS age_band,
       p.address_state AS state,
       f.facility_code AS registered_facility,
       date_trunc('month', p.registered_at)::date AS registered_month
  FROM patient p
  JOIN facility f ON f.facility_id = p.registered_facility_id
 CROSS JOIN pseudonym_key k;

CREATE VIEW deid_encounter AS
SELECT encode(substr(sha256(k.secret || int8send(e.patient_id)), 1, 8), 'hex') AS patient_key,
       f.facility_code,
       f.state,
       date_trunc('month', e.started_at)::date AS encounter_month,
       e.encounter_type_code,
       age_band(p.date_of_birth, e.started_at::date) AS age_band_at_visit,
       (SELECT array_agg(d.diagnosis_code ORDER BY d.is_primary DESC, d.diagnosis_code)
          FROM encounter_diagnosis d WHERE d.encounter_id = e.encounter_id) AS diagnosis_codes
  FROM encounter e
  JOIN patient p ON p.patient_id = e.patient_id
  JOIN facility f ON f.facility_id = e.facility_id
 CROSS JOIN pseudonym_key k;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA itoju FROM PUBLIC;

GRANT USAGE ON SCHEMA itoju
  TO itoju_app, itoju_reception, itoju_clinician, itoju_pharmacy, itoju_lab, itoju_billing, itoju_analyst, itoju_auditor;

GRANT SELECT ON staff_role, consent_purpose, appointment_status, encounter_type, movement_type, payment_method,
                facility, department, diagnosis_code, drug, lab_test, staff, clinician, clinician_department
  TO itoju_app, itoju_reception, itoju_clinician, itoju_pharmacy, itoju_lab, itoju_billing;

GRANT SELECT ON patient_directory, appointment TO itoju_app, itoju_reception, itoju_clinician;
GRANT INSERT ON patient_phone, next_of_kin, consent TO itoju_reception;
GRANT EXECUTE ON FUNCTION register_patient, book_appointment, reschedule_appointment, cancel_appointment
  TO itoju_app, itoju_reception;

GRANT INSERT ON encounter, vital_sign, encounter_diagnosis, clinical_note, prescription, prescription_item,
                lab_order, patient_allergy
  TO itoju_clinician;
GRANT SELECT (encounter_id) ON encounter TO itoju_clinician;
GRANT UPDATE (ended_at) ON encounter TO itoju_clinician;
GRANT SELECT (prescription_id) ON prescription TO itoju_clinician;
GRANT SELECT (clinical_note_id) ON clinical_note TO itoju_clinician;
GRANT SELECT (lab_order_id) ON lab_order TO itoju_clinician;
GRANT SELECT ON on_call_shift TO itoju_clinician;
GRANT EXECUTE ON FUNCTION patient_record, sign_off_on_call TO itoju_clinician;

GRANT SELECT ON prescription, prescription_item, stock_on_hand, stock_movement TO itoju_pharmacy;
GRANT EXECUTE ON FUNCTION receive_stock, dispense_prescription_item, transfer_stock TO itoju_pharmacy;

GRANT SELECT ON lab_order, lab_result TO itoju_lab;
GRANT EXECUTE ON FUNCTION record_lab_result TO itoju_lab;

GRANT SELECT, INSERT ON invoice, invoice_line, payment TO itoju_billing;
GRANT SELECT ON patient_directory, prescription_item, lab_order TO itoju_billing;
GRANT USAGE ON SEQUENCE invoice_no_seq TO itoju_billing;

GRANT SELECT ON deid_patient, deid_encounter TO itoju_analyst;
GRANT EXECUTE ON FUNCTION age_band TO itoju_analyst;

GRANT SELECT ON ALL TABLES IN SCHEMA itoju TO itoju_auditor;
REVOKE SELECT ON pseudonym_key FROM itoju_auditor;
GRANT EXECUTE ON FUNCTION age_band TO itoju_auditor;
