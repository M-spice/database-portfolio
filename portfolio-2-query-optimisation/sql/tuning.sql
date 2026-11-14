\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
SET ROLE itoju_owner;
SET search_path = itoju, public;
SET jit = off;

\echo '== Statistics: distinct patients among encounters, estimated from the default sample, then from a larger one'
CREATE TEMP TABLE stats_check AS
SELECT 'default target (100)' AS statistics, n_distinct::bigint AS estimated_distinct
  FROM pg_stats WHERE schemaname = 'itoju' AND tablename = 'encounter' AND attname = 'patient_id';

ALTER TABLE encounter ALTER COLUMN patient_id SET STATISTICS 1000;
ANALYZE encounter;

INSERT INTO stats_check
SELECT 'raised target (1000)', n_distinct::bigint
  FROM pg_stats WHERE schemaname = 'itoju' AND tablename = 'encounter' AND attname = 'patient_id';

SELECT s.statistics, s.estimated_distinct, a.actual_distinct,
       round(100.0 * s.estimated_distinct / a.actual_distinct, 1) AS percent_of_actual,
       round((SELECT count(*) FROM encounter)::numeric / s.estimated_distinct, 1) AS planner_rows_per_patient
  FROM stats_check s CROSS JOIN (SELECT count(DISTINCT patient_id) AS actual_distinct FROM encounter) a;

\echo '== Materialised view for the monthly diagnosis report (Q05)'
\timing on
CREATE MATERIALIZED VIEW monthly_diagnosis AS
SELECT f.facility_code,
       date_trunc('month', e.started_at AT TIME ZONE 'Africa/Lagos')::date AS month,
       d.diagnosis_code,
       count(*) AS cases
  FROM encounter e
  JOIN encounter_diagnosis d USING (encounter_id)
  JOIN facility f USING (facility_id)
 GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX monthly_diagnosis_uk ON monthly_diagnosis (facility_code, month, diagnosis_code);

\echo '== Refresh cost: a full refresh, then a concurrent refresh that does not block readers'
REFRESH MATERIALIZED VIEW monthly_diagnosis;
REFRESH MATERIALIZED VIEW CONCURRENTLY monthly_diagnosis;
\timing off

ANALYZE monthly_diagnosis;
SELECT count(*) AS mv_rows, pg_size_pretty(pg_total_relation_size('monthly_diagnosis')) AS mv_size FROM monthly_diagnosis;
