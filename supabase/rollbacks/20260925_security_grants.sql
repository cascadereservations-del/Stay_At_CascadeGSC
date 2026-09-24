-- Rollback for release security_grants_20260925: restores the grants and search_path read on 2026-09-24 before the
-- release (pg_proc.proacl / pg_class.relacl). Nothing else changes.
begin;
grant execute on function public.get_cleanable_bookings(date, uuid, integer, integer) to anon;
grant execute on function public.get_meter_photo_followups(uuid, integer) to anon;
grant execute on function public.can_skip_meter_photos(uuid) to anon;
grant execute on function public.get_meter_photo_objects(text, timestamptz, integer) to anon, authenticated;
grant execute on function public.get_meter_sessions_pending_vision(uuid, integer, integer) to anon, authenticated;
grant execute on function public.get_welcome_info(date, uuid) to public, anon;
grant execute on function public.get_usage_medians() to public, anon;
alter function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) reset search_path;
alter function public.match_inventory_item(text, integer, real, boolean) reset search_path;
alter function public.try_uuid(text) reset search_path;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) to public, anon;
grant execute on function public.match_inventory_item(text, integer, real, boolean) to public, anon;
grant execute on function public.try_uuid(text) to public, anon;
grant all on table public.app_secrets, public.admin_auth_attempts, public.telegram_pending,
  public.telegram_processed_updates to anon, authenticated;
commit;
