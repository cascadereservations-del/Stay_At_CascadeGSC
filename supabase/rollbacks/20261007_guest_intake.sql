-- Compensating rollback for release guest_intake_20261007 (session 74).
-- Drops the five intake functions. Companions, photos, history rows and the guest-id-photos bucket stay exactly as the guest form left
-- them (staff still see them in the dashboard). Roll the stay-site (stay.html) and the guest-intake function back too.
begin;
drop function if exists public.intake_save_guest_companion_v1(text, text, text, text, text);
drop function if exists public.intake_save_guest_details_v1(text, jsonb);
drop function if exists public.intake_guest_context_v1(text);
drop function if exists public.intake_uploads_today_v1(uuid, text);
drop function if exists public.intake_resolve_v1(text);
commit;
