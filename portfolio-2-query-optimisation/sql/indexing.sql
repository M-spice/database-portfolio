\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
SET ROLE itoju_owner;
SET search_path = itoju, public;
SET maintenance_work_mem = '512MB';
\timing on

-- B+ tree on one column: phone lookup (Q01)
CREATE INDEX patient_phone_no_ix ON patient_phone (phone_no);

-- Multi-column index in the timeline's filter and sort order, so no Sort is needed (Q02)
CREATE INDEX encounter_patient_started_ix ON encounter (patient_id, started_at DESC);

-- Range index on encounter start time (Q09, and offered to Q05 and Q08)
CREATE INDEX encounter_started_ix ON encounter (started_at);

-- Partial covering index: dispenses only, with the quantity carried in the index (Q06)
CREATE INDEX stock_movement_dispense_ix ON stock_movement (facility_id, drug_id, moved_at)
  INCLUDE (quantity) WHERE movement_type_code = 'DISPENSE';

-- Covering index for the turnaround report, so the order rows need not be visited (Q07)
CREATE INDEX lab_order_ordered_ix ON lab_order (ordered_at) INCLUDE (lab_order_id, lab_test_id);

-- Index on a low-selectivity column, kept to show the planner declining it (Q10)
CREATE INDEX encounter_type_ix ON encounter (encounter_type_code);

\timing off
RESET ROLE;
VACUUM (ANALYZE) itoju.patient_phone, itoju.encounter, itoju.stock_movement, itoju.lab_order;

SELECT t.relname AS table_name, i.relname AS index_name, pg_size_pretty(pg_relation_size(i.oid)) AS size
  FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid
 WHERE i.relname IN ('patient_phone_no_ix', 'encounter_patient_started_ix', 'encounter_started_ix',
                     'stock_movement_dispense_ix', 'lab_order_ordered_ix', 'encounter_type_ix')
 ORDER BY 1, 2;
