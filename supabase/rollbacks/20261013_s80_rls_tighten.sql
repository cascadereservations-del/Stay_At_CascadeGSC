-- Rollback for release s80_rls_tighten_20261013. Restores the exact policies and grants read from the live catalog on 2026-10-13.
-- This REOPENS the exposures (anon read/write of chat history, purchases, audit log; read_operations roles reading guest contacts and money).
-- Use only if a client turns out to depend on the old access, and re-close it the same day. Apply with run-sql-on-host.sh.

begin;

-- D
drop policy if exists booking_inquiries_finance_read on public.booking_inquiries;
drop policy if exists booking_inquiries_staff_read on public.booking_inquiries;
create policy booking_inquiries_staff_read on public.booking_inquiries for select to authenticated
  using (current_staff_authorized('read_operations'::text, property_id));

drop policy if exists airbnb_reservations_finance_read on public.airbnb_reservations;
drop policy if exists airbnb_reservations_staff_read on public.airbnb_reservations;
create policy airbnb_reservations_staff_read on public.airbnb_reservations for select to authenticated
  using (current_staff_authorized('read_operations'::text, property_id));

-- B
drop policy if exists inventory_purchases_staff_all on public.inventory_purchases;
drop policy if exists "anon all" on public.inventory_purchases;
drop policy if exists "authenticated all" on public.inventory_purchases;
create policy "anon all" on public.inventory_purchases as permissive for all to anon using (true) with check (true);
create policy "authenticated all" on public.inventory_purchases as permissive for all to authenticated using (true) with check (true);
grant delete, insert, references, select, trigger, truncate, update on table public.inventory_purchases to anon, authenticated;

-- C
drop policy if exists inventory_audit_log_service_only on public.inventory_audit_log;
drop policy if exists "anon select" on public.inventory_audit_log;
drop policy if exists "anon insert" on public.inventory_audit_log;
create policy "anon select" on public.inventory_audit_log as permissive for select to anon using (true);
create policy "anon insert" on public.inventory_audit_log as permissive for insert to anon with check (true);
grant delete, insert, references, select, trigger, truncate, update on table public.inventory_audit_log to anon, authenticated;

-- A
drop policy if exists telegram_chat_history_service_only on public.telegram_chat_history;
drop policy if exists "service_role_all" on public.telegram_chat_history;
create policy "service_role_all" on public.telegram_chat_history as permissive for all to public using (true) with check (true);
grant delete, insert, references, select, trigger, truncate, update on table public.telegram_chat_history to anon, authenticated;

commit;
