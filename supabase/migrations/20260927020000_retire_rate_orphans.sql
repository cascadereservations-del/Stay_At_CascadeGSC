-- 20260927020000_retire_rate_orphans.sql
-- Session 56 (Opus 5): release retire_rate_orphans_20260927 - CONTRACT phase (D-263 item 6).
-- SPEC-34 moved every price to the rate card (booking_rate_policy_versions + get_rate_card_v1). The two app_settings rows
-- it replaced stayed as inert rows because an expand release deletes nothing. Nothing reads them since submit-booking v17:
-- grep of waves, stay-site (site + functions; stay-site/supabase/functions/submit-booking is a stale copy, every function
-- deploys from waves), admin-dashboard/app/src, guest-guide, manual; pg_proc, pg_views and cron.job read 2026-09-27;
-- n8n and the relay's Apps Script source read in the browser before apply (release contract). Rollback re-inserts both.
begin;
delete from public.app_settings where key in ('nightly_rate_php', 'deposit_percent');
commit;
