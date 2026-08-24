
-- 2026-08-24: close the live exposure found during the direct-booking
-- conversion audit. Frontend has already been repointed at the new
-- availability Edge Function (v20, calendar_events-based) so the browser no
-- longer needs anon SELECT on calendar_events; submit-booking v11.8 already
-- mints its own signed URLs for the Telegram/email relay so it no longer
-- needs the receipts bucket to be public. See KB
-- direct-booking/2026-08-24-conversion-plan-audit.md for the full write-up.

-- ── Storage: booking-receipts bucket ──────────────────────────────────────
update storage.buckets set public = false where id = 'booking-receipts';

drop policy if exists "public_read_receipts" on storage.objects;

-- Owner/admin can read receipts directly via an authenticated session
-- (e.g. once the admin dashboard signs in with Supabase Auth and calls
-- .createSignedUrl()/.download() instead of getPublicUrl()). Service role
-- (used by submit-booking/approve-booking) bypasses RLS entirely already.
create policy "owner_admin_read_receipts" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'booking-receipts'
    and (auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin'])
  );

-- anon_upload_receipts (anon INSERT) is left in place — the browser still
-- uploads the file directly; only the read side was ever the problem.

-- ── airbnb_reservations: was fully anon-readable (names + all financials) ──
drop policy if exists "anon read" on public.airbnb_reservations;
drop policy if exists "authenticated full access" on public.airbnb_reservations;

create policy "airbnb_reservations_owner_admin_all" on public.airbnb_reservations
  for all to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']))
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']));
-- service_role policy ("service role full access") is untouched.

-- ── calendar_events: anon row access no longer needed (availability Edge Function replaces it) ──
drop policy if exists "anon_read_calendar_events" on public.calendar_events;
drop policy if exists "auth_full_calendar_events" on public.calendar_events;
drop policy if exists "authenticated_read_all" on public.calendar_events;

create policy "calendar_events_owner_admin_all" on public.calendar_events
  for all to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']))
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']));

-- ── calendar_sync_log: internal ops log, no anon consumer observed ──
drop policy if exists "anon_read_sync_log" on public.calendar_sync_log;
drop policy if exists "auth_full_sync_log" on public.calendar_sync_log;

create policy "calendar_sync_log_owner_admin_all" on public.calendar_sync_log
  for all to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']))
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']));

-- ── booking_inquiries: submission goes through submit-booking (service role); ──
-- ── anon direct insert was never used by this frontend. Blanket authenticated ──
-- ── read is replaced with owner/admin-only, matching the guests table pattern. ──
drop policy if exists "anon insert" on public.booking_inquiries;
drop policy if exists "auth read" on public.booking_inquiries;

create policy "booking_inquiries_owner_admin_select" on public.booking_inquiries
  for select to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']));
;
