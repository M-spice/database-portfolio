\pset footer off
SELECT version();

SELECT d.datname AS database,
       pg_encoding_to_char(d.encoding) AS encoding,
       d.datcollate AS collate,
       d.datctype AS ctype
FROM pg_database d
WHERE d.datname = current_database();

SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('data_checksums', 'TimeZone', 'log_timezone', 'shared_buffers', 'work_mem',
               'maintenance_work_mem', 'effective_cache_size', 'max_connections',
               'default_transaction_isolation', 'wal_level', 'max_wal_senders',
               'listen_addresses', 'password_encryption')
ORDER BY name;

SELECT name, default_version
FROM pg_available_extensions
WHERE name IN ('btree_gist', 'pgcrypto', 'pg_stat_statements')
ORDER BY name;
