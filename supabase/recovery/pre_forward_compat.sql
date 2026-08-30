-- Recovery-only bridge for policy state already present in the captured public schema.
-- Dropping these policies lets their original, unmodified post-snapshot migration replay.
drop policy if exists "owner_admin_read_receipts" on storage.objects;
drop policy if exists "airbnb_reservations_owner_admin_all" on public.airbnb_reservations;
drop policy if exists "calendar_events_owner_admin_all" on public.calendar_events;
drop policy if exists "calendar_sync_log_owner_admin_all" on public.calendar_sync_log;
drop policy if exists "booking_inquiries_owner_admin_select" on public.booking_inquiries;
