-- 20261009010000_drop_w01_dispatch.sql
-- Session 78 (lane F, TASKS #19): nothing consumes n8n W01 any more. The AFTER INSERT trigger on automation_outbox posted every
-- booking.requested row to https://cascade-n8n.rocloyd.com/webhook/cascade-w01-booking-requested, which answers 404 each time.
-- The function swallowed the failure (raise warning), so no booking was ever blocked, but each insert still spent a vault read
-- and an HTTP call. Dropping the trigger and its function ends that. The outbox row itself is unchanged: it is still written,
-- pending, by the same code paths.
-- Not touched: the vault secrets cascade_n8n_w01_webhook_secret, cascade_cf_w01_client_id, cascade_cf_w01_client_secret
-- (Lloyd removes them later). Rollback: supabase/rollbacks/20261009_drop_w01_dispatch.sql recreates both from the live
-- definitions read 2026-10-08.

begin;

drop trigger if exists automation_outbox_dispatch_w01 on public.automation_outbox;
drop function if exists public.dispatch_w01_booking_requested();

commit;
