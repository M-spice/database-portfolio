SET ROLE itoju_owner;
SET search_path = itoju, public;

CREATE FUNCTION forbid_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: record a correction as a new row', TG_TABLE_NAME
    USING ERRCODE = 'integrity_constraint_violation',
          CONSTRAINT = TG_TABLE_NAME || '_append_only_tg', TABLE = TG_TABLE_NAME, SCHEMA = TG_TABLE_SCHEMA;
END $$;

CREATE TRIGGER clinical_note_append_only_tg BEFORE UPDATE OR DELETE ON clinical_note
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER lab_result_append_only_tg BEFORE UPDATE OR DELETE ON lab_result
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER stock_movement_append_only_tg BEFORE UPDATE OR DELETE ON stock_movement
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER payment_append_only_tg BEFORE UPDATE OR DELETE ON payment
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER record_access_log_append_only_tg BEFORE UPDATE OR DELETE ON record_access_log
  FOR EACH ROW EXECUTE FUNCTION forbid_change();
CREATE TRIGGER appointment_status_history_append_only_tg BEFORE UPDATE OR DELETE ON appointment_status_history
  FOR EACH ROW EXECUTE FUNCTION forbid_change();

CREATE FUNCTION clinician_check_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM staff s JOIN staff_role r USING (staff_role_code)
                 WHERE s.staff_id = NEW.clinician_id AND r.is_clinical) THEN
    RAISE EXCEPTION 'staff % does not hold a clinical role', NEW.clinician_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'clinician_clinical_role_tg', TABLE = 'clinician';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER clinician_clinical_role_tg BEFORE INSERT OR UPDATE ON clinician
  FOR EACH ROW EXECUTE FUNCTION clinician_check_role();

CREATE FUNCTION appointment_log_status() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.appointment_status_code IS DISTINCT FROM OLD.appointment_status_code THEN
    INSERT INTO appointment_status_history (appointment_id, appointment_status_code, changed_at, changed_by)
    VALUES (NEW.appointment_id,
            NEW.appointment_status_code,
            coalesce(nullif(current_setting('itoju.event_time', true), '')::timestamptz,
                     CASE WHEN TG_OP = 'INSERT' THEN NEW.booked_at ELSE now() END),
            nullif(current_setting('itoju.staff_id', true), '')::bigint);
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER appointment_status_history_tg AFTER INSERT OR UPDATE OF appointment_status_code ON appointment
  FOR EACH ROW EXECUTE FUNCTION appointment_log_status();

CREATE FUNCTION stock_movement_apply() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  mt movement_type%ROWTYPE;
BEGIN
  SELECT * INTO mt FROM movement_type WHERE movement_type_code = NEW.movement_type_code;
  IF mt.requires_prescription <> (NEW.prescription_id IS NOT NULL) THEN
    RAISE EXCEPTION 'a % movement % reference a prescription item', NEW.movement_type_code,
      CASE WHEN mt.requires_prescription THEN 'must' ELSE 'must not' END
      USING ERRCODE = 'check_violation', CONSTRAINT = 'stock_movement_prescription_tg', TABLE = 'stock_movement';
  END IF;
  IF mt.requires_transfer_ref <> (NEW.transfer_ref IS NOT NULL) THEN
    RAISE EXCEPTION 'a % movement % carry a transfer reference', NEW.movement_type_code,
      CASE WHEN mt.requires_transfer_ref THEN 'must' ELSE 'must not' END
      USING ERRCODE = 'check_violation', CONSTRAINT = 'stock_movement_transfer_ref_tg', TABLE = 'stock_movement';
  END IF;

  INSERT INTO stock_on_hand (facility_id, drug_id, quantity, updated_at)
  VALUES (NEW.facility_id, NEW.drug_id, 0, NEW.moved_at)
  ON CONFLICT (facility_id, drug_id) DO NOTHING;

  UPDATE stock_on_hand
     SET quantity = quantity + mt.direction * NEW.quantity,
         updated_at = greatest(updated_at, NEW.moved_at)
   WHERE facility_id = NEW.facility_id AND drug_id = NEW.drug_id;
  RETURN NULL;
END $$;

CREATE TRIGGER stock_movement_apply_tg AFTER INSERT ON stock_movement
  FOR EACH ROW EXECUTE FUNCTION stock_movement_apply();

CREATE FUNCTION stock_on_hand_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF pg_trigger_depth() < 2 THEN
    RAISE EXCEPTION 'stock on hand changes only through the stock movement ledger'
      USING ERRCODE = 'integrity_constraint_violation', CONSTRAINT = 'stock_on_hand_ledger_only_tg',
            TABLE = 'stock_on_hand';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER stock_on_hand_ledger_only_tg BEFORE INSERT OR UPDATE OR DELETE ON stock_on_hand
  FOR EACH ROW EXECUTE FUNCTION stock_on_hand_guard();

CREATE FUNCTION stock_transfer_check() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  n_out integer;
  n_in integer;
  consistent boolean;
BEGIN
  SELECT count(*) FILTER (WHERE mt.direction < 0),
         count(*) FILTER (WHERE mt.direction > 0),
         count(DISTINCT m.drug_id) = 1 AND count(DISTINCT m.quantity) = 1 AND count(DISTINCT m.facility_id) = 2
    INTO n_out, n_in, consistent
    FROM stock_movement m JOIN movement_type mt USING (movement_type_code)
   WHERE m.transfer_ref = NEW.transfer_ref;
  IF n_out <> 1 OR n_in <> 1 OR NOT consistent THEN
    RAISE EXCEPTION 'transfer % needs exactly one movement out and one in, for the same drug and quantity, between two facilities',
      NEW.transfer_ref
      USING ERRCODE = 'integrity_constraint_violation', CONSTRAINT = 'stock_movement_transfer_pair_tg',
            TABLE = 'stock_movement';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER stock_movement_transfer_pair_tg AFTER INSERT ON stock_movement
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (NEW.transfer_ref IS NOT NULL) EXECUTE FUNCTION stock_transfer_check();

CREATE FUNCTION invoice_check_total() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_invoice bigint := CASE WHEN TG_OP = 'DELETE' THEN OLD.invoice_id ELSE NEW.invoice_id END;
  v_total bigint;
  v_lines bigint;
BEGIN
  SELECT i.total_kobo, (SELECT coalesce(sum(l.amount_kobo), 0) FROM invoice_line l WHERE l.invoice_id = i.invoice_id)
    INTO v_total, v_lines
    FROM invoice i WHERE i.invoice_id = v_invoice;
  IF FOUND AND v_total <> v_lines THEN
    RAISE EXCEPTION 'invoice % total of % kobo does not equal the sum of its lines (% kobo)', v_invoice, v_total, v_lines
      USING ERRCODE = 'integrity_constraint_violation', CONSTRAINT = 'invoice_total_tg', TABLE = 'invoice';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER invoice_total_tg AFTER INSERT OR UPDATE ON invoice
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION invoice_check_total();
CREATE CONSTRAINT TRIGGER invoice_line_total_tg AFTER INSERT OR UPDATE OR DELETE ON invoice_line
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION invoice_check_total();

CREATE FUNCTION payment_check() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_total bigint;
  v_paid bigint;
  v_needs_reference boolean;
BEGIN
  SELECT total_kobo INTO v_total FROM invoice WHERE invoice_id = NEW.invoice_id FOR UPDATE;
  SELECT coalesce(sum(amount_kobo), 0) INTO v_paid FROM payment WHERE invoice_id = NEW.invoice_id;
  IF NEW.amount_kobo > v_total - v_paid THEN
    RAISE EXCEPTION 'payment of % kobo exceeds the % kobo outstanding on invoice %',
      NEW.amount_kobo, v_total - v_paid, NEW.invoice_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'payment_outstanding_tg', TABLE = 'payment';
  END IF;
  SELECT requires_reference INTO v_needs_reference
    FROM payment_method WHERE payment_method_code = NEW.payment_method_code;
  IF coalesce(v_needs_reference, false) AND NEW.reference IS NULL THEN
    RAISE EXCEPTION '% payments need a reference', NEW.payment_method_code
      USING ERRCODE = 'check_violation', CONSTRAINT = 'payment_reference_tg', TABLE = 'payment';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER payment_rules_tg BEFORE INSERT ON payment
  FOR EACH ROW EXECUTE FUNCTION payment_check();

CREATE FUNCTION lab_order_check() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM facility WHERE facility_id = NEW.facility_id AND has_laboratory) THEN
    RAISE EXCEPTION 'facility % has no laboratory', NEW.facility_id
      USING ERRCODE = 'check_violation', CONSTRAINT = 'lab_order_facility_laboratory_tg', TABLE = 'lab_order';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER lab_order_facility_laboratory_tg BEFORE INSERT OR UPDATE ON lab_order
  FOR EACH ROW EXECUTE FUNCTION lab_order_check();

CREATE FUNCTION lab_result_check() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = itoju, pg_temp AS $$
DECLARE
  v_unit text;
  v_ordered_at timestamptz;
BEGIN
  SELECT t.unit, o.ordered_at INTO v_unit, v_ordered_at
    FROM lab_order o JOIN lab_test t USING (lab_test_id)
   WHERE o.lab_order_id = NEW.lab_order_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;
  IF (v_unit IS NULL) <> (NEW.value_numeric IS NULL) THEN
    RAISE EXCEPTION 'a % test needs a % result',
      CASE WHEN v_unit IS NULL THEN 'qualitative' ELSE 'quantitative' END,
      CASE WHEN v_unit IS NULL THEN 'text' ELSE 'numeric' END
      USING ERRCODE = 'check_violation', CONSTRAINT = 'lab_result_value_kind_tg', TABLE = 'lab_result';
  END IF;
  IF NEW.recorded_at < v_ordered_at THEN
    RAISE EXCEPTION 'a result cannot be recorded before its order was placed'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'lab_result_after_order_tg', TABLE = 'lab_result';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER lab_result_rules_tg BEFORE INSERT ON lab_result
  FOR EACH ROW EXECUTE FUNCTION lab_result_check();
