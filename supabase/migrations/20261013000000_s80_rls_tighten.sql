-- 20261013000000_s80_rls_tighten.sql
-- Session 80 (security lane): release s80_rls_tighten_20261013. Closes four exposures found in the live catalog read of 2026-10-13.
-- The site's publishable (anon) key is public by design, so an anon policy is the whole internet.
--   A. telegram_chat_history: policy service_role_all was FOR ALL TO public USING (true) and anon held every grant:
--      anyone could read and alter Telegram chat history. Now service_role only (the two edge functions that touch it use the service key).
--   B. inventory_purchases: "anon all" + "authenticated all" (true) with full anon grants: supplier costs readable and writable by anyone.
--      Now owner/admin only (current_staff_authorized manage_inventory on the item's property). Cleaners never read purchases; the cleaner
--      checklist writes inventory_usage and reads inventory_items, both untouched. TRUNCATE/REFERENCES/TRIGGER also leave authenticated
--      (TRUNCATE ignores RLS).
--   C. inventory_audit_log: "anon select" + "anon insert". Nothing in any client reads it; writers are service_role and definer functions.
--      Now service_role only.
--   D. booking_inquiries / airbnb_reservations: the *_staff_read policies admitted every role holding read_operations (cleaner, inspector,
--      maintenance), exposing guest e-mail, phone, totals, deposits, receipt paths and Airbnb payouts through the API (D-306, D-319).
--      Replaced by read_finance (owner, admin, finance). Owner/admin keep their own jwt-role policies; service_role is unchanged. Field-role
--      screens read names and dates from staff_home_v1 / calendar RPCs / calendar_events, never from these tables (D-324).
-- Policy and grant changes only: no table, column or data change. Idempotent. Rollback: supabase/rollbacks/20261013_s80_rls_tighten.sql

begin;

-- A ---------------------------------------------------------------------------------------------------------------------------------
drop policy if exists "service_role_all" on public.telegram_chat_history;
drop policy if exists telegram_chat_history_service_only on public.telegram_chat_history;
create policy telegram_chat_history_service_only on public.telegram_chat_history for all to service_role using (true) with check (true);
revoke all on table public.telegram_chat_history from public, anon, authenticated;

-- C ---------------------------------------------------------------------------------------------------------------------------------
drop policy if exists "anon select" on public.inventory_audit_log;
drop policy if exists "anon insert" on public.inventory_audit_log;
drop policy if exists inventory_audit_log_service_only on public.inventory_audit_log;
create policy inventory_audit_log_service_only on public.inventory_audit_log for all to service_role using (true) with check (true);
revoke all on table public.inventory_audit_log from public, anon, authenticated;

-- B ---------------------------------------------------------------------------------------------------------------------------------
drop policy if exists "anon all" on public.inventory_purchases;
drop policy if exists "authenticated all" on public.inventory_purchases;
drop policy if exists inventory_purchases_staff_all on public.inventory_purchases;
create policy inventory_purchases_staff_all on public.inventory_purchases for all to authenticated
  using (exists (select 1 from public.inventory_items i
                 where i.id = inventory_purchases.item_id and public.current_staff_authorized('manage_inventory', i.property_id)))
  with check (exists (select 1 from public.inventory_items i
                      where i.id = inventory_purchases.item_id and public.current_staff_authorized('manage_inventory', i.property_id)));
revoke all on table public.inventory_purchases from public, anon;
revoke truncate, references, trigger on table public.inventory_purchases from authenticated;

-- D ---------------------------------------------------------------------------------------------------------------------------------
drop policy if exists booking_inquiries_staff_read on public.booking_inquiries;
drop policy if exists booking_inquiries_finance_read on public.booking_inquiries;
create policy booking_inquiries_finance_read on public.booking_inquiries for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));

drop policy if exists airbnb_reservations_staff_read on public.airbnb_reservations;
drop policy if exists airbnb_reservations_finance_read on public.airbnb_reservations;
create policy airbnb_reservations_finance_read on public.airbnb_reservations for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));

commit;
