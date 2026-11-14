\set ON_ERROR_STOP on
\pset footer off

SELECT t.relname AS table_name,
       pg_size_pretty(pg_table_size(t.oid)) AS table_size,
       pg_size_pretty(pg_indexes_size(t.oid)) AS index_size,
       (SELECT count(*) FROM pg_index i WHERE i.indrelid = t.oid) AS indexes,
       t.reltuples::bigint AS rows
  FROM pg_class t JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'itoju' AND t.relkind = 'r'
 ORDER BY pg_total_relation_size(t.oid) DESC
 LIMIT 15;

SELECT t.relname AS table_name, i.relname AS index_name, am.amname AS method,
       pg_size_pretty(pg_relation_size(i.oid)) AS size, pg_relation_size(i.oid) AS bytes
  FROM pg_index x
  JOIN pg_class i ON i.oid = x.indexrelid
  JOIN pg_class t ON t.oid = x.indrelid
  JOIN pg_am am ON am.oid = i.relam
  JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'itoju'
   AND t.relname IN ('encounter', 'patient_phone', 'stock_movement', 'lab_order', 'appointment')
 ORDER BY t.relname, i.relname;

SELECT pg_size_pretty(sum(pg_table_size(t.oid))) AS all_tables,
       pg_size_pretty(sum(pg_indexes_size(t.oid))) AS all_indexes,
       sum(pg_indexes_size(t.oid)) AS index_bytes
  FROM pg_class t JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'itoju' AND t.relkind IN ('r', 'm');
