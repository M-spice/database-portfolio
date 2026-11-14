\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;

DROP SCHEMA IF EXISTS sandbox CASCADE;
CREATE SCHEMA sandbox AUTHORIZATION itoju_owner;
SET ROLE itoju_owner;
SET search_path = sandbox;

-- Deliberately without the safeguards of the real schema, so the anomalies they prevent can be shown.
CREATE TABLE stock (
  facility_code text NOT NULL,
  drug_code     text NOT NULL,
  quantity      integer NOT NULL,
  PRIMARY KEY (facility_code, drug_code)
);

CREATE TABLE booking (
  booking_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinician_no text NOT NULL,
  starts       timestamptz NOT NULL,
  hospital_no  text NOT NULL
);

CREATE TABLE queue_counter (
  facility_code text NOT NULL,
  queue_day     date NOT NULL,
  last_no       integer NOT NULL,
  PRIMARY KEY (facility_code, queue_day)
);

CREATE SEQUENCE queue_seq;

CREATE TABLE queue_ticket (
  ticket_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  facility_code text NOT NULL,
  queue_day     date NOT NULL,
  queue_no      bigint NOT NULL
);

CREATE FUNCTION transfer_naive(p_from text, p_to text, p_drug text, p_quantity integer, p_pause double precision)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE stock SET quantity = quantity - p_quantity WHERE facility_code = p_from AND drug_code = p_drug;
  PERFORM pg_sleep(p_pause);
  UPDATE stock SET quantity = quantity + p_quantity WHERE facility_code = p_to AND drug_code = p_drug;
END $$;

CREATE FUNCTION transfer_ordered(p_from text, p_to text, p_drug text, p_quantity integer, p_pause double precision)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM stock WHERE drug_code = p_drug AND facility_code IN (p_from, p_to)
   ORDER BY facility_code FOR UPDATE;
  UPDATE stock SET quantity = quantity - p_quantity WHERE facility_code = p_from AND drug_code = p_drug;
  PERFORM pg_sleep(p_pause);
  UPDATE stock SET quantity = quantity + p_quantity WHERE facility_code = p_to AND drug_code = p_drug;
END $$;

INSERT INTO stock VALUES ('LAG-IKJ', 'DRG-0002', 100), ('LAG-LEK', 'DRG-0002', 100);

\dt sandbox.*
