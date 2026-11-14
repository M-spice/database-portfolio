SET ROLE itoju_owner;
SET search_path = itoju, public;

CREATE FUNCTION age_band(p_date_of_birth date, p_on date) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN a < 5 THEN '00-04'
           WHEN a < 15 THEN '05-14'
           WHEN a < 25 THEN '15-24'
           WHEN a < 45 THEN '25-44'
           WHEN a < 65 THEN '45-64'
           ELSE '65+'
         END
  FROM (SELECT extract(year FROM age(p_on::timestamp, p_date_of_birth::timestamp))::int AS a) s
$$;

CREATE FUNCTION register_patient(
  p_staff_id      bigint,
  p_given_name    text,
  p_middle_name   text,
  p_family_name   text,
  p_date_of_birth date,
  p_phone_no      text,
  p_address_line  text,
  p_address_city  text,
  p_address_state text,
  p_national_id   text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_patient_id bigint;
  v_hospital_no text := 'HN-' || lpad(nextval('patient_hospital_no_seq')::text, 7, '0');
BEGIN
  INSERT INTO patient (hospital_no, given_name, middle_name, family_name, date_of_birth, national_id,
                       address_line, address_city, address_state, registered_facility_id)
  SELECT v_hospital_no, p_given_name, p_middle_name, p_family_name, p_date_of_birth, p_national_id,
         p_address_line, p_address_city, p_address_state, s.home_facility_id
    FROM staff s
   WHERE s.staff_id = p_staff_id
  RETURNING patient_id INTO v_patient_id;

  IF v_patient_id IS NULL THEN
    RAISE EXCEPTION 'unknown staff member %', p_staff_id
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'register_patient_staff_fn';
  END IF;

  INSERT INTO patient_phone (patient_id, phone_no, is_primary) VALUES (v_patient_id, p_phone_no, true);
  RETURN v_hospital_no;
END $$;

CREATE FUNCTION book_appointment(
  p_patient_id    bigint,
  p_clinician_id  bigint,
  p_department_id bigint,
  p_facility_id   bigint,
  p_start         timestamptz,
  p_minutes       integer,
  p_booked_by     bigint DEFAULT NULL,
  p_request_key   uuid DEFAULT NULL,
  p_reason        text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_appointment_id bigint;
BEGIN
  PERFORM set_config('itoju.staff_id', coalesce(p_booked_by::text, ''), true);

  INSERT INTO appointment (patient_id, clinician_id, department_id, facility_id, slot,
                           booked_by, request_key, reason)
  VALUES (p_patient_id, p_clinician_id, p_department_id, p_facility_id,
          tstzrange(p_start, p_start + make_interval(mins => p_minutes)),
          p_booked_by, p_request_key, p_reason)
  ON CONFLICT (request_key) DO NOTHING
  RETURNING appointment_id INTO v_appointment_id;

  IF v_appointment_id IS NULL THEN
    SELECT a.appointment_id INTO v_appointment_id FROM appointment a WHERE a.request_key = p_request_key;
  END IF;
  RETURN v_appointment_id;
END $$;

CREATE FUNCTION reschedule_appointment(
  p_appointment_id bigint,
  p_new_start      timestamptz,
  p_minutes        integer,
  p_staff_id       bigint
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
BEGIN
  PERFORM set_config('itoju.staff_id', p_staff_id::text, true);
  UPDATE appointment
     SET slot = tstzrange(p_new_start, p_new_start + make_interval(mins => p_minutes))
   WHERE appointment_id = p_appointment_id
     AND appointment_status_code = 'BOOKED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'appointment % is not a booked appointment that can be rescheduled', p_appointment_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'appointment_reschedule_fn';
  END IF;
END $$;

CREATE FUNCTION cancel_appointment(p_appointment_id bigint, p_staff_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
BEGIN
  PERFORM set_config('itoju.staff_id', p_staff_id::text, true);
  UPDATE appointment
     SET appointment_status_code = 'CANCELLED'
   WHERE appointment_id = p_appointment_id
     AND appointment_status_code IN ('BOOKED', 'CHECKED_IN');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'appointment % cannot be cancelled in its current state', p_appointment_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'appointment_cancel_fn';
  END IF;
END $$;

CREATE FUNCTION receive_stock(
  p_facility_id bigint,
  p_drug_id     bigint,
  p_quantity    integer,
  p_staff_id    bigint,
  p_note        text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by, note)
  VALUES (p_facility_id, p_drug_id, 'RECEIPT', p_quantity, p_staff_id, p_note)
  RETURNING stock_movement_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION dispense_prescription_item(
  p_prescription_id bigint,
  p_drug_id         bigint,
  p_facility_id     bigint,
  p_staff_id        bigint
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_quantity integer;
  v_id bigint;
BEGIN
  SELECT pi.quantity INTO v_quantity
    FROM prescription_item pi
   WHERE pi.prescription_id = p_prescription_id AND pi.drug_id = p_drug_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'prescription % has no item for drug %', p_prescription_id, p_drug_id
      USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'stock_movement_prescription_item_fk';
  END IF;

  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by, prescription_id)
  VALUES (p_facility_id, p_drug_id, 'DISPENSE', v_quantity, p_staff_id, p_prescription_id)
  RETURNING stock_movement_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION transfer_stock(
  p_drug_id          bigint,
  p_from_facility_id bigint,
  p_to_facility_id   bigint,
  p_quantity         integer,
  p_staff_id         bigint
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_ref uuid := gen_random_uuid();
BEGIN
  IF p_from_facility_id = p_to_facility_id THEN
    RAISE EXCEPTION 'a transfer needs two different facilities'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'stock_transfer_facilities_fn';
  END IF;

  -- Both stock rows are locked in facility order, so two opposite transfers cannot deadlock.
  PERFORM 1
     FROM stock_on_hand
    WHERE drug_id = p_drug_id AND facility_id IN (p_from_facility_id, p_to_facility_id)
    ORDER BY facility_id
      FOR UPDATE;

  INSERT INTO stock_movement (facility_id, drug_id, movement_type_code, quantity, moved_by, transfer_ref)
  VALUES (p_from_facility_id, p_drug_id, 'TRANSFER_OUT', p_quantity, p_staff_id, v_ref),
         (p_to_facility_id,   p_drug_id, 'TRANSFER_IN',  p_quantity, p_staff_id, v_ref);
  RETURN v_ref;
END $$;

CREATE FUNCTION record_lab_result(
  p_lab_order_id      bigint,
  p_staff_id          bigint,
  p_value_numeric     numeric,
  p_value_text        text,
  p_supersedes_result bigint DEFAULT NULL,
  p_correction_reason text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO lab_result (lab_order_id, recorded_by, value_numeric, value_text,
                          supersedes_result_id, correction_reason)
  VALUES (p_lab_order_id, p_staff_id, p_value_numeric, p_value_text,
          p_supersedes_result, p_correction_reason)
  RETURNING lab_result_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION patient_record(p_staff_id bigint, p_patient_id bigint, p_purpose text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM staff WHERE staff_id = p_staff_id AND left_on IS NOT NULL) THEN
    RAISE EXCEPTION 'staff member % has left and may not open patient records', p_staff_id
      USING ERRCODE = 'insufficient_privilege', CONSTRAINT = 'record_access_active_staff_fn';
  END IF;

  INSERT INTO record_access_log (staff_id, patient_id, purpose) VALUES (p_staff_id, p_patient_id, p_purpose);

  RETURN (
    SELECT jsonb_build_object(
      'hospital_no', p.hospital_no,
      'name', concat_ws(' ', p.given_name, p.middle_name, p.family_name),
      'date_of_birth', p.date_of_birth,
      'age_years', extract(year FROM age(current_date::timestamp, p.date_of_birth::timestamp))::int,
      'allergies', (SELECT coalesce(jsonb_agg(a.allergen ORDER BY a.allergen), '[]'::jsonb)
                      FROM patient_allergy a WHERE a.patient_id = p.patient_id),
      'encounters', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                 'started_at', e.started_at,
                 'facility', f.facility_code,
                 'type', e.encounter_type_code,
                 'diagnoses', (SELECT coalesce(jsonb_agg(d.diagnosis_code ORDER BY d.is_primary DESC, d.diagnosis_code), '[]'::jsonb)
                                 FROM encounter_diagnosis d WHERE d.encounter_id = e.encounter_id))
               ORDER BY e.started_at DESC), '[]'::jsonb)
          FROM (SELECT * FROM encounter WHERE patient_id = p.patient_id ORDER BY started_at DESC LIMIT 20) e
          JOIN facility f ON f.facility_id = e.facility_id))
    FROM patient p
   WHERE p.patient_id = p_patient_id);
END $$;

CREATE FUNCTION sign_off_on_call(p_on_call_shift_id bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_facility_id bigint;
  v_shift_date date;
BEGIN
  SELECT facility_id, shift_date INTO v_facility_id, v_shift_date
    FROM on_call_shift WHERE on_call_shift_id = p_on_call_shift_id AND on_call;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'shift % is not currently on call', p_on_call_shift_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'on_call_shift_fn';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM on_call_shift
                  WHERE facility_id = v_facility_id AND shift_date = v_shift_date
                    AND on_call AND on_call_shift_id <> p_on_call_shift_id) THEN
    RAISE EXCEPTION 'at least one clinician must stay on call at facility % on %', v_facility_id, v_shift_date
      USING ERRCODE = 'check_violation', CONSTRAINT = 'on_call_minimum_fn';
  END IF;

  UPDATE on_call_shift SET on_call = false WHERE on_call_shift_id = p_on_call_shift_id;
END $$;
