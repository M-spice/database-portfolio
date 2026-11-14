\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
SET TimeZone = 'UTC';

BEGIN;
\ir V01__extensions_roles.sql
\ir V02__tables.sql
\ir V03__integrity.sql
\ir V04__routines.sql
\ir V05__privileges.sql
\ir V06__sample_data.sql
COMMIT;

RESET ROLE;
ANALYZE;

SELECT c.relname AS table_name, c.reltuples::bigint AS row_estimate,
       (SELECT count(*) FROM pg_constraint k WHERE k.conrelid = c.oid) AS constraints
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'itoju' AND c.relkind = 'r'
 ORDER BY c.relname;
