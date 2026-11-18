-- Compensating rollback for release s120_linen_stains_20261120 (session 120, migration 20261120000002_s120_linen_stains.sql).
-- Drops record_linen_stains_v1 and linen_stain_reports. DATA LOSS (by design): every linen audit row. The stock the reports already took off, the linen_replace
-- follow-up tasks they opened and the inventory_audit_log rows (action linen_stain) they wrote all stay as they are (ordinary inventory, task and audit rows). Roll the checklist back first (it calls the function).
-- Apply with run-sql-on-host.sh.

begin;

drop function if exists public.record_linen_stains_v1(uuid, date, text, text, jsonb);
drop table if exists public.linen_stain_reports;

commit;
