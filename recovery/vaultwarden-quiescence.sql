-- A stopped client may leave its submitted PostgreSQL backend running.
-- All app-role sessions and session-independent prepared transactions count.
SELECT NOT EXISTS (
  SELECT 1 FROM pg_stat_activity WHERE datname = :'app_db' AND usename = :'app_role'
) AND NOT EXISTS (
  SELECT 1 FROM pg_prepared_xacts WHERE database = :'app_db'
);
