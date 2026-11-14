SET ROLE itoju_owner;
SET search_path = itoju, public;

-- code tables

CREATE TABLE staff_role (
  staff_role_code text CONSTRAINT staff_role_pk PRIMARY KEY,
  description     text NOT NULL,
  is_clinical     boolean NOT NULL,
  CONSTRAINT staff_role_code_ck CHECK (staff_role_code ~ '^[A-Z][A-Z_]{1,29}$')
);

CREATE TABLE consent_purpose (
  consent_purpose_code text CONSTRAINT consent_purpose_pk PRIMARY KEY,
  description          text NOT NULL,
  CONSTRAINT consent_purpose_code_ck CHECK (consent_purpose_code ~ '^[A-Z][A-Z_]{1,29}$')
);

CREATE TABLE appointment_status (
  appointment_status_code text CONSTRAINT appointment_status_pk PRIMARY KEY,
  description             text NOT NULL,
  CONSTRAINT appointment_status_code_ck CHECK (appointment_status_code ~ '^[A-Z][A-Z_]{1,29}$')
);

CREATE TABLE encounter_type (
  encounter_type_code text CONSTRAINT encounter_type_pk PRIMARY KEY,
  description         text NOT NULL,
  CONSTRAINT encounter_type_code_ck CHECK (encounter_type_code ~ '^[A-Z][A-Z_]{1,29}$')
);

CREATE TABLE movement_type (
  movement_type_code    text CONSTRAINT movement_type_pk PRIMARY KEY,
  description           text NOT NULL,
  direction             smallint NOT NULL,
  requires_prescription boolean NOT NULL,
  requires_transfer_ref boolean NOT NULL,
  CONSTRAINT movement_type_code_ck CHECK (movement_type_code ~ '^[A-Z][A-Z_]{1,29}$'),
  CONSTRAINT movement_type_direction_ck CHECK (direction IN (-1, 1))
);

CREATE TABLE payment_method (
  payment_method_code text CONSTRAINT payment_method_pk PRIMARY KEY,
  description         text NOT NULL,
  requires_reference  boolean NOT NULL,
  CONSTRAINT payment_method_code_ck CHECK (payment_method_code ~ '^[A-Z][A-Z_]{1,29}$')
);

-- organisation and staff

CREATE TABLE facility (
  facility_id    bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT facility_pk PRIMARY KEY,
  facility_code  text NOT NULL CONSTRAINT facility_code_uk UNIQUE,
  name           text NOT NULL,
  city           text NOT NULL,
  state          text NOT NULL,
  has_laboratory boolean NOT NULL DEFAULT true,
  opened_on      date NOT NULL,
  CONSTRAINT facility_code_ck CHECK (facility_code ~ '^[A-Z]{3}-[A-Z]{3}$')
);

CREATE TABLE department (
  department_id   bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT department_pk PRIMARY KEY,
  department_code text NOT NULL CONSTRAINT department_code_uk UNIQUE,
  name            text NOT NULL CONSTRAINT department_name_uk UNIQUE,
  CONSTRAINT department_code_ck CHECK (department_code ~ '^[A-Z]{2,6}$')
);

CREATE TABLE staff (
  staff_id         bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT staff_pk PRIMARY KEY,
  staff_no         text NOT NULL CONSTRAINT staff_no_uk UNIQUE,
  given_name       text NOT NULL,
  family_name      text NOT NULL,
  staff_role_code  text NOT NULL CONSTRAINT staff_role_fk REFERENCES staff_role,
  home_facility_id bigint NOT NULL CONSTRAINT staff_home_facility_fk REFERENCES facility,
  employed_on      date NOT NULL,
  left_on          date,
  CONSTRAINT staff_no_ck CHECK (staff_no ~ '^ST-[0-9]{5}$'),
  CONSTRAINT staff_left_on_ck CHECK (left_on >= employed_on)
);

CREATE TABLE clinician (
  clinician_id bigint CONSTRAINT clinician_pk PRIMARY KEY
                      CONSTRAINT clinician_staff_fk REFERENCES staff (staff_id),
  licence_no   text NOT NULL CONSTRAINT clinician_licence_no_uk UNIQUE,
  CONSTRAINT clinician_licence_no_ck CHECK (licence_no ~ '^LIC-999-[0-9]{5}$')
);

CREATE TABLE clinician_department (
  clinician_id  bigint NOT NULL CONSTRAINT clinician_department_clinician_fk REFERENCES clinician,
  department_id bigint NOT NULL CONSTRAINT clinician_department_department_fk REFERENCES department,
  assigned_on   date NOT NULL,
  CONSTRAINT clinician_department_pk PRIMARY KEY (clinician_id, department_id)
);

-- patients

CREATE SEQUENCE patient_hospital_no_seq;

CREATE TABLE patient (
  patient_id             bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT patient_pk PRIMARY KEY,
  hospital_no            text NOT NULL CONSTRAINT patient_hospital_no_uk UNIQUE,
  given_name             text NOT NULL,
  middle_name            text,
  family_name            text NOT NULL,
  date_of_birth          date NOT NULL,
  national_id            text CONSTRAINT patient_national_id_uk UNIQUE,
  address_line           text NOT NULL,
  address_city           text NOT NULL,
  address_state          text NOT NULL,
  registered_facility_id bigint NOT NULL CONSTRAINT patient_registered_facility_fk REFERENCES facility,
  registered_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT patient_hospital_no_ck CHECK (hospital_no ~ '^HN-[0-9]{7}$'),
  CONSTRAINT patient_national_id_ck CHECK (national_id ~ '^999[0-9]{8}$'),
  CONSTRAINT patient_date_of_birth_ck CHECK (date_of_birth BETWEEN DATE '1900-01-01' AND CURRENT_DATE)
);

CREATE TABLE patient_phone (
  patient_id bigint NOT NULL CONSTRAINT patient_phone_patient_fk REFERENCES patient ON DELETE CASCADE,
  phone_no   text NOT NULL,
  is_primary boolean NOT NULL DEFAULT false,
  CONSTRAINT patient_phone_pk PRIMARY KEY (patient_id, phone_no),
  CONSTRAINT patient_phone_no_ck CHECK (phone_no ~ '^\+2340[0-9]{9}$')
);
CREATE UNIQUE INDEX patient_phone_primary_uk ON patient_phone (patient_id) WHERE is_primary;

CREATE TABLE patient_allergy (
  patient_id  bigint NOT NULL CONSTRAINT patient_allergy_patient_fk REFERENCES patient ON DELETE CASCADE,
  allergen    text NOT NULL,
  reaction    text,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT patient_allergy_pk PRIMARY KEY (patient_id, allergen),
  CONSTRAINT patient_allergy_allergen_ck CHECK (btrim(allergen) <> '')
);

CREATE TABLE next_of_kin (
  patient_id   bigint NOT NULL CONSTRAINT next_of_kin_patient_fk REFERENCES patient ON DELETE CASCADE,
  kin_no       smallint NOT NULL,
  full_name    text NOT NULL,
  relationship text NOT NULL,
  phone_no     text NOT NULL,
  CONSTRAINT next_of_kin_pk PRIMARY KEY (patient_id, kin_no),
  CONSTRAINT next_of_kin_kin_no_ck CHECK (kin_no BETWEEN 1 AND 5),
  CONSTRAINT next_of_kin_phone_no_ck CHECK (phone_no ~ '^\+2340[0-9]{9}$')
);

CREATE TABLE consent (
  consent_id           bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT consent_pk PRIMARY KEY,
  patient_id           bigint NOT NULL CONSTRAINT consent_patient_fk REFERENCES patient,
  consent_purpose_code text NOT NULL CONSTRAINT consent_purpose_fk REFERENCES consent_purpose,
  granted_at           timestamptz NOT NULL,
  withdrawn_at         timestamptz,
  recorded_by          bigint NOT NULL CONSTRAINT consent_recorded_by_fk REFERENCES staff,
  CONSTRAINT consent_withdrawn_at_ck CHECK (withdrawn_at > granted_at)
);
CREATE UNIQUE INDEX consent_patient_purpose_open_uk ON consent (patient_id, consent_purpose_code)
  WHERE withdrawn_at IS NULL;

-- appointments and encounters

CREATE TABLE appointment (
  appointment_id          bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT appointment_pk PRIMARY KEY,
  patient_id              bigint NOT NULL CONSTRAINT appointment_patient_fk REFERENCES patient,
  clinician_id            bigint NOT NULL,
  department_id           bigint NOT NULL,
  facility_id             bigint NOT NULL CONSTRAINT appointment_facility_fk REFERENCES facility,
  slot                    tstzrange NOT NULL,
  appointment_status_code text NOT NULL DEFAULT 'BOOKED' CONSTRAINT appointment_status_fk REFERENCES appointment_status,
  booked_at               timestamptz NOT NULL DEFAULT now(),
  booked_by               bigint CONSTRAINT appointment_booked_by_fk REFERENCES staff,
  request_key             uuid CONSTRAINT appointment_request_key_uk UNIQUE,
  reason                  text,
  CONSTRAINT appointment_clinician_department_fk FOREIGN KEY (clinician_id, department_id)
    REFERENCES clinician_department (clinician_id, department_id),
  CONSTRAINT appointment_id_patient_uk UNIQUE (appointment_id, patient_id),
  CONSTRAINT appointment_slot_ck CHECK (
    lower_inc(slot) AND NOT upper_inc(slot) AND NOT lower_inf(slot) AND NOT upper_inf(slot)
    AND upper(slot) - lower(slot) BETWEEN interval '10 minutes' AND interval '2 hours'),
  CONSTRAINT appointment_clinician_slot_ex EXCLUDE USING gist (clinician_id WITH =, slot WITH &&)
    WHERE (appointment_status_code <> 'CANCELLED'),
  CONSTRAINT appointment_patient_slot_ex EXCLUDE USING gist (patient_id WITH =, slot WITH &&)
    WHERE (appointment_status_code <> 'CANCELLED')
);

CREATE TABLE appointment_status_history (
  appointment_status_history_id bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT appointment_status_history_pk PRIMARY KEY,
  appointment_id          bigint NOT NULL CONSTRAINT appointment_status_history_appointment_fk REFERENCES appointment,
  appointment_status_code text NOT NULL CONSTRAINT appointment_status_history_status_fk REFERENCES appointment_status,
  changed_at              timestamptz NOT NULL,
  changed_by              bigint CONSTRAINT appointment_status_history_changed_by_fk REFERENCES staff
);

CREATE TABLE encounter (
  encounter_id        bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT encounter_pk PRIMARY KEY,
  patient_id          bigint NOT NULL CONSTRAINT encounter_patient_fk REFERENCES patient,
  clinician_id        bigint NOT NULL CONSTRAINT encounter_clinician_fk REFERENCES clinician,
  facility_id         bigint NOT NULL CONSTRAINT encounter_facility_fk REFERENCES facility,
  appointment_id      bigint CONSTRAINT encounter_appointment_uk UNIQUE,
  encounter_type_code text NOT NULL CONSTRAINT encounter_type_fk REFERENCES encounter_type,
  started_at          timestamptz NOT NULL,
  ended_at            timestamptz,
  CONSTRAINT encounter_appointment_fk FOREIGN KEY (appointment_id, patient_id)
    REFERENCES appointment (appointment_id, patient_id),
  CONSTRAINT encounter_id_patient_uk UNIQUE (encounter_id, patient_id),
  CONSTRAINT encounter_ended_at_ck CHECK (ended_at >= started_at)
);

CREATE TABLE vital_sign (
  vital_sign_id  bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT vital_sign_pk PRIMARY KEY,
  encounter_id   bigint NOT NULL CONSTRAINT vital_sign_encounter_fk REFERENCES encounter,
  recorded_at    timestamptz NOT NULL,
  recorded_by    bigint NOT NULL CONSTRAINT vital_sign_recorded_by_fk REFERENCES staff,
  temperature_c  numeric(4,1),
  pulse_bpm      smallint,
  systolic_mmhg  smallint,
  diastolic_mmhg smallint,
  spo2_pct       smallint,
  weight_kg      numeric(5,2),
  height_cm      numeric(4,1),
  CONSTRAINT vital_sign_any_ck CHECK (
    num_nonnulls(temperature_c, pulse_bpm, systolic_mmhg, diastolic_mmhg, spo2_pct, weight_kg, height_cm) > 0),
  CONSTRAINT vital_sign_blood_pressure_ck CHECK (
    (systolic_mmhg IS NULL) = (diastolic_mmhg IS NULL)
    AND systolic_mmhg BETWEEN 50 AND 300 AND diastolic_mmhg BETWEEN 20 AND 200
    AND systolic_mmhg > diastolic_mmhg),
  CONSTRAINT vital_sign_height_cm_ck CHECK (height_cm BETWEEN 20 AND 250),
  CONSTRAINT vital_sign_pulse_bpm_ck CHECK (pulse_bpm BETWEEN 20 AND 250),
  CONSTRAINT vital_sign_spo2_pct_ck CHECK (spo2_pct BETWEEN 50 AND 100),
  CONSTRAINT vital_sign_temperature_c_ck CHECK (temperature_c BETWEEN 30 AND 45),
  CONSTRAINT vital_sign_weight_kg_ck CHECK (weight_kg BETWEEN 0.3 AND 400)
);

CREATE TABLE diagnosis_code (
  diagnosis_code text CONSTRAINT diagnosis_code_pk PRIMARY KEY,
  description    text NOT NULL,
  is_chronic     boolean NOT NULL,
  CONSTRAINT diagnosis_code_ck CHECK (diagnosis_code ~ '^[A-Z][0-9]{2}(\.[0-9])?$')
);

CREATE TABLE encounter_diagnosis (
  encounter_id   bigint NOT NULL CONSTRAINT encounter_diagnosis_encounter_fk REFERENCES encounter,
  diagnosis_code text NOT NULL CONSTRAINT encounter_diagnosis_diagnosis_fk REFERENCES diagnosis_code,
  is_primary     boolean NOT NULL DEFAULT false,
  CONSTRAINT encounter_diagnosis_pk PRIMARY KEY (encounter_id, diagnosis_code)
);
CREATE UNIQUE INDEX encounter_diagnosis_primary_uk ON encounter_diagnosis (encounter_id) WHERE is_primary;

CREATE TABLE clinical_note (
  clinical_note_id bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT clinical_note_pk PRIMARY KEY,
  encounter_id     bigint NOT NULL CONSTRAINT clinical_note_encounter_fk REFERENCES encounter,
  author_id        bigint NOT NULL CONSTRAINT clinical_note_author_fk REFERENCES clinician,
  written_at       timestamptz NOT NULL DEFAULT now(),
  body             text NOT NULL,
  amends_note_id   bigint,
  amendment_reason text,
  CONSTRAINT clinical_note_id_encounter_uk UNIQUE (clinical_note_id, encounter_id),
  CONSTRAINT clinical_note_amends_fk FOREIGN KEY (amends_note_id, encounter_id)
    REFERENCES clinical_note (clinical_note_id, encounter_id),
  CONSTRAINT clinical_note_amendment_ck CHECK ((amends_note_id IS NULL) = (amendment_reason IS NULL)),
  CONSTRAINT clinical_note_body_ck CHECK (btrim(body) <> '')
);

-- pharmacy

CREATE TABLE drug (
  drug_id         bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT drug_pk PRIMARY KEY,
  drug_code       text NOT NULL CONSTRAINT drug_code_uk UNIQUE,
  name            text NOT NULL,
  form            text NOT NULL,
  strength        text NOT NULL,
  unit_price_kobo bigint NOT NULL,
  reorder_level   integer NOT NULL,
  CONSTRAINT drug_name_form_strength_uk UNIQUE (name, form, strength),
  CONSTRAINT drug_code_ck CHECK (drug_code ~ '^DRG-[0-9]{4}$'),
  CONSTRAINT drug_reorder_level_ck CHECK (reorder_level >= 0),
  CONSTRAINT drug_unit_price_kobo_ck CHECK (unit_price_kobo > 0)
);

CREATE TABLE prescription (
  prescription_id bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT prescription_pk PRIMARY KEY,
  encounter_id    bigint NOT NULL CONSTRAINT prescription_encounter_fk REFERENCES encounter,
  prescriber_id   bigint NOT NULL CONSTRAINT prescription_prescriber_fk REFERENCES clinician,
  issued_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE prescription_item (
  prescription_id bigint NOT NULL CONSTRAINT prescription_item_prescription_fk REFERENCES prescription,
  drug_id         bigint NOT NULL CONSTRAINT prescription_item_drug_fk REFERENCES drug,
  quantity        integer NOT NULL,
  dosage          text NOT NULL,
  CONSTRAINT prescription_item_pk PRIMARY KEY (prescription_id, drug_id),
  CONSTRAINT prescription_item_quantity_ck CHECK (quantity BETWEEN 1 AND 1000)
);

CREATE TABLE stock_on_hand (
  facility_id bigint NOT NULL CONSTRAINT stock_on_hand_facility_fk REFERENCES facility,
  drug_id     bigint NOT NULL CONSTRAINT stock_on_hand_drug_fk REFERENCES drug,
  quantity    integer NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_on_hand_pk PRIMARY KEY (facility_id, drug_id),
  CONSTRAINT stock_on_hand_quantity_ck CHECK (quantity >= 0)
);

CREATE TABLE stock_movement (
  stock_movement_id  bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT stock_movement_pk PRIMARY KEY,
  facility_id        bigint NOT NULL CONSTRAINT stock_movement_facility_fk REFERENCES facility,
  drug_id            bigint NOT NULL CONSTRAINT stock_movement_drug_fk REFERENCES drug,
  movement_type_code text NOT NULL CONSTRAINT stock_movement_type_fk REFERENCES movement_type,
  quantity           integer NOT NULL,
  moved_at           timestamptz NOT NULL DEFAULT now(),
  moved_by           bigint NOT NULL CONSTRAINT stock_movement_moved_by_fk REFERENCES staff,
  transfer_ref       uuid,
  prescription_id    bigint,
  note               text,
  CONSTRAINT stock_movement_prescription_item_fk FOREIGN KEY (prescription_id, drug_id)
    REFERENCES prescription_item (prescription_id, drug_id),
  CONSTRAINT stock_movement_prescription_item_uk UNIQUE (prescription_id, drug_id),
  CONSTRAINT stock_movement_transfer_ref_uk UNIQUE (transfer_ref, movement_type_code),
  CONSTRAINT stock_movement_quantity_ck CHECK (quantity > 0)
);

-- laboratory

CREATE TABLE lab_test (
  lab_test_id       bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT lab_test_pk PRIMARY KEY,
  test_code         text NOT NULL CONSTRAINT lab_test_code_uk UNIQUE,
  name              text NOT NULL,
  specimen          text NOT NULL,
  unit              text,
  reference_low     numeric,
  reference_high    numeric,
  price_kobo        bigint NOT NULL,
  target_turnaround interval NOT NULL,
  CONSTRAINT lab_test_code_ck CHECK (test_code ~ '^LT-[A-Z0-9]{2,8}$'),
  CONSTRAINT lab_test_price_kobo_ck CHECK (price_kobo > 0),
  CONSTRAINT lab_test_qualitative_ck CHECK (unit IS NOT NULL OR (reference_low IS NULL AND reference_high IS NULL)),
  CONSTRAINT lab_test_reference_range_ck CHECK (reference_low < reference_high),
  CONSTRAINT lab_test_target_turnaround_ck CHECK (target_turnaround > interval '0')
);

CREATE TABLE lab_order (
  lab_order_id bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT lab_order_pk PRIMARY KEY,
  encounter_id bigint NOT NULL CONSTRAINT lab_order_encounter_fk REFERENCES encounter,
  lab_test_id  bigint NOT NULL CONSTRAINT lab_order_lab_test_fk REFERENCES lab_test,
  facility_id  bigint NOT NULL CONSTRAINT lab_order_facility_fk REFERENCES facility,
  ordered_by   bigint NOT NULL CONSTRAINT lab_order_ordered_by_fk REFERENCES clinician,
  ordered_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lab_order_encounter_test_uk UNIQUE (encounter_id, lab_test_id)
);

CREATE TABLE lab_result (
  lab_result_id        bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT lab_result_pk PRIMARY KEY,
  lab_order_id         bigint NOT NULL CONSTRAINT lab_result_lab_order_fk REFERENCES lab_order,
  recorded_at          timestamptz NOT NULL DEFAULT now(),
  recorded_by          bigint NOT NULL CONSTRAINT lab_result_recorded_by_fk REFERENCES staff,
  value_numeric        numeric,
  value_text           text,
  supersedes_result_id bigint CONSTRAINT lab_result_supersedes_uk UNIQUE,
  correction_reason    text,
  CONSTRAINT lab_result_id_order_uk UNIQUE (lab_result_id, lab_order_id),
  CONSTRAINT lab_result_supersedes_fk FOREIGN KEY (supersedes_result_id, lab_order_id)
    REFERENCES lab_result (lab_result_id, lab_order_id),
  CONSTRAINT lab_result_correction_ck CHECK ((supersedes_result_id IS NULL) = (correction_reason IS NULL)),
  CONSTRAINT lab_result_value_ck CHECK (num_nonnulls(value_numeric, value_text) = 1)
);
CREATE UNIQUE INDEX lab_result_order_original_uk ON lab_result (lab_order_id) WHERE supersedes_result_id IS NULL;

-- billing

CREATE SEQUENCE invoice_no_seq;

CREATE TABLE invoice (
  invoice_id   bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT invoice_pk PRIMARY KEY,
  invoice_no   text NOT NULL CONSTRAINT invoice_no_uk UNIQUE,
  patient_id   bigint NOT NULL CONSTRAINT invoice_patient_fk REFERENCES patient,
  facility_id  bigint NOT NULL CONSTRAINT invoice_facility_fk REFERENCES facility,
  encounter_id bigint CONSTRAINT invoice_encounter_uk UNIQUE,
  issued_at    timestamptz NOT NULL DEFAULT now(),
  issued_by    bigint NOT NULL CONSTRAINT invoice_issued_by_fk REFERENCES staff,
  total_kobo   bigint NOT NULL,
  CONSTRAINT invoice_encounter_fk FOREIGN KEY (encounter_id, patient_id)
    REFERENCES encounter (encounter_id, patient_id),
  CONSTRAINT invoice_no_ck CHECK (invoice_no ~ '^INV-[0-9]{8}$'),
  CONSTRAINT invoice_total_kobo_ck CHECK (total_kobo >= 0)
);

CREATE TABLE invoice_line (
  invoice_id      bigint NOT NULL CONSTRAINT invoice_line_invoice_fk REFERENCES invoice ON DELETE CASCADE,
  line_no         smallint NOT NULL,
  description     text NOT NULL,
  drug_id         bigint CONSTRAINT invoice_line_drug_fk REFERENCES drug,
  lab_test_id     bigint CONSTRAINT invoice_line_lab_test_fk REFERENCES lab_test,
  quantity        integer NOT NULL,
  unit_price_kobo bigint NOT NULL,
  amount_kobo     bigint GENERATED ALWAYS AS (quantity * unit_price_kobo) STORED,
  CONSTRAINT invoice_line_pk PRIMARY KEY (invoice_id, line_no),
  CONSTRAINT invoice_line_item_ck CHECK (num_nonnulls(drug_id, lab_test_id) <= 1),
  CONSTRAINT invoice_line_line_no_ck CHECK (line_no > 0),
  CONSTRAINT invoice_line_quantity_ck CHECK (quantity > 0),
  CONSTRAINT invoice_line_unit_price_kobo_ck CHECK (unit_price_kobo >= 0)
);

CREATE TABLE payment (
  payment_id          bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT payment_pk PRIMARY KEY,
  invoice_id          bigint NOT NULL CONSTRAINT payment_invoice_fk REFERENCES invoice,
  payment_method_code text NOT NULL CONSTRAINT payment_method_fk REFERENCES payment_method,
  amount_kobo         bigint NOT NULL,
  paid_at             timestamptz NOT NULL DEFAULT now(),
  received_by         bigint NOT NULL CONSTRAINT payment_received_by_fk REFERENCES staff,
  reference           text,
  CONSTRAINT payment_amount_kobo_ck CHECK (amount_kobo > 0)
);

-- audit, rota and privacy

CREATE TABLE record_access_log (
  record_access_log_id bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT record_access_log_pk PRIMARY KEY,
  staff_id             bigint NOT NULL CONSTRAINT record_access_log_staff_fk REFERENCES staff,
  patient_id           bigint NOT NULL CONSTRAINT record_access_log_patient_fk REFERENCES patient,
  accessed_at          timestamptz NOT NULL DEFAULT now(),
  purpose              text NOT NULL,
  db_user              text NOT NULL DEFAULT session_user,
  CONSTRAINT record_access_log_purpose_ck CHECK (btrim(purpose) <> '')
);

CREATE TABLE on_call_shift (
  on_call_shift_id bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT on_call_shift_pk PRIMARY KEY,
  facility_id      bigint NOT NULL CONSTRAINT on_call_shift_facility_fk REFERENCES facility,
  clinician_id     bigint NOT NULL CONSTRAINT on_call_shift_clinician_fk REFERENCES clinician,
  shift_date       date NOT NULL,
  on_call          boolean NOT NULL DEFAULT true,
  CONSTRAINT on_call_shift_facility_clinician_date_uk UNIQUE (facility_id, clinician_id, shift_date)
);

CREATE TABLE pseudonym_key (
  pseudonym_key_id smallint CONSTRAINT pseudonym_key_pk PRIMARY KEY,
  secret           bytea NOT NULL,
  CONSTRAINT pseudonym_key_single_row_ck CHECK (pseudonym_key_id = 1)
);
INSERT INTO pseudonym_key VALUES (1, sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')));
