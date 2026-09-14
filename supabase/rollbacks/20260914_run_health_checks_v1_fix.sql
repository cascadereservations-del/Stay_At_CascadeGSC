-- Compensating rollback for 20260914210000_run_health_checks_v1_fix.sql.
-- The previous body was unusable (record r not assigned), so the only sane
-- rollback is the full admin_crud_audit_v1 rollback, which drops the function
-- together with everything else that release added.
-- Run: supabase/rollbacks/20260914_admin_crud_audit_v1.sql
select 'run supabase/rollbacks/20260914_admin_crud_audit_v1.sql instead' as note;
