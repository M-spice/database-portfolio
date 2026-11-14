\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
SET TimeZone = 'UTC';
SET ROLE itoju_owner;
SET search_path = itoju, public;

CREATE TEMP TABLE test_result (
  seq       serial,
  suite     text,
  test_name text,
  run_as    text,
  expected  text,
  outcome   text,
  passed    boolean,
  message   text
);

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
CREATE FUNCTION pg_temp.enc(p_no text, p_date date) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT e.encounter_id FROM itoju.encounter e JOIN itoju.patient p USING (patient_id)
      WHERE p.hospital_no = p_no AND (e.started_at AT TIME ZONE 'Africa/Lagos')::date = p_date $$;
CREATE FUNCTION pg_temp.rx(p_no text, p_date date) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT prescription_id FROM itoju.prescription WHERE encounter_id = pg_temp.enc(p_no, p_date) $$;
CREATE FUNCTION pg_temp.ord(p_no text, p_test text) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT o.lab_order_id FROM itoju.lab_order o JOIN itoju.encounter e USING (encounter_id)
      WHERE e.patient_id = pg_temp.pat(p_no) AND o.lab_test_id = pg_temp.lab(p_test) $$;
CREATE FUNCTION pg_temp.inv(p_no text, p_date date) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT invoice_id FROM itoju.invoice WHERE encounter_id = pg_temp.enc(p_no, p_date) $$;

-- Runs one case inside a subtransaction that is always rolled back, and records which
-- named constraint, trigger rule or error stopped it ('ok' when nothing did).
CREATE FUNCTION pg_temp.check_case(p_suite text, p_name text, p_expected text, p_sql text, p_role text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
  v_constraint text;
  v_column text;
  v_message text;
  v_outcome text;
BEGIN
  BEGIN
    IF p_role IS NOT NULL THEN
      EXECUTE format('SET LOCAL ROLE %I', p_role);
    END IF;
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION USING ERRCODE = 'ZZ000', MESSAGE = 'completed';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_constraint = CONSTRAINT_NAME,
                            v_column = COLUMN_NAME, v_message = MESSAGE_TEXT;
  END;
  v_outcome := CASE
                 WHEN v_state = 'ZZ000' THEN 'ok'
                 WHEN v_constraint <> '' THEN v_constraint
                 WHEN v_state = '23502' THEN 'not_null:' || v_column
                 WHEN v_state = '42501' THEN 'permission_denied'
                 ELSE 'sqlstate:' || v_state
               END;
  INSERT INTO test_result (suite, test_name, run_as, expected, outcome, passed, message)
  VALUES (p_suite, p_name, coalesce(p_role, 'itoju_owner'), p_expected, v_outcome, v_outcome = p_expected,
          CASE WHEN v_state = 'ZZ000' THEN NULL ELSE v_message END);
END $$;
