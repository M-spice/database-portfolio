RESET ROLE;
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;

DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['itoju_owner', 'itoju_app', 'itoju_reception', 'itoju_clinician',
                           'itoju_pharmacy', 'itoju_lab', 'itoju_billing', 'itoju_analyst', 'itoju_auditor']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

DROP SCHEMA IF EXISTS itoju CASCADE;
CREATE SCHEMA itoju AUTHORIZATION itoju_owner;
REVOKE ALL ON SCHEMA itoju FROM PUBLIC;
