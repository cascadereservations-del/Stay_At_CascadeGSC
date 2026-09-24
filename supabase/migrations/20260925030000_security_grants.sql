-- 20260925030000_security_grants.sql
-- Session 49 (Opus 5): release security_grants_20260925 - SPEC-26 (D-228).
--
-- Read 2026-09-24 15:1xZ before writing (pg_proc.proacl, has_function_privilege, pg_class.relacl):
--   * seven SECURITY DEFINER functions are executable by anon although every caller is signed in or service_role;
--   * FIVE of the functions also hold a PUBLIC grant (=X/postgres): apply_inventory_purchase, get_usage_medians,
--     get_welcome_info, match_inventory_item, try_uuid. Revoking from anon alone would leave them reachable through
--     PUBLIC, so those revokes name public too. authenticated and service_role keep their own direct grants;
--   * the four RLS-locked tables grant anon and authenticated ALL privileges (arwdDxtm), not only SELECT. RLS with
--     no policy returns and accepts nothing for them today; the grants are dead and go.
-- Deliberately untouched (D-228): get_checklist_staff_names, verify_booking, verify_admin_pin (anon by design).
-- Later (D-228): pg_trgm out of public. Lloyd: the leaked-password switch in Auth settings.

begin;

-- The release states the END state instead of assuming the start: every function is revoked from PUBLIC and anon
-- (and authenticated where it must go), then granted explicitly to the roles that must keep it. On production those
-- grants already exist (read 2026-09-24); a --no-acl restore starts from default privileges, where service_role and
-- authenticated had EXECUTE only through PUBLIC - the first rehearsal showed a bare revoke would strip them there.

-- 1. The seven definer functions anon must not execute.
revoke execute on function public.get_cleanable_bookings(date, uuid, integer, integer) from public, anon;
revoke execute on function public.get_meter_photo_followups(uuid, integer) from public, anon;
revoke execute on function public.can_skip_meter_photos(uuid) from public, anon;
grant execute on function public.get_cleanable_bookings(date, uuid, integer, integer) to authenticated, service_role;
grant execute on function public.get_meter_photo_followups(uuid, integer) to authenticated, service_role;
grant execute on function public.can_skip_meter_photos(uuid) to authenticated, service_role;

revoke execute on function public.get_meter_photo_objects(text, timestamptz, integer) from public, anon, authenticated;
revoke execute on function public.get_meter_sessions_pending_vision(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.get_meter_photo_objects(text, timestamptz, integer) to service_role;
grant execute on function public.get_meter_sessions_pending_vision(uuid, integer, integer) to service_role;

revoke execute on function public.get_welcome_info(date, uuid) from public, anon;
revoke execute on function public.get_usage_medians() from public, anon;
grant execute on function public.get_welcome_info(date, uuid) to authenticated, service_role;
grant execute on function public.get_usage_medians() to authenticated, service_role;

-- 2. The three invoker functions telegram-expense calls: pin search_path, off PUBLIC and anon.
alter function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) set search_path = public;
alter function public.match_inventory_item(text, integer, real, boolean) set search_path = public;
alter function public.try_uuid(text) set search_path = '';
revoke execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) from public, anon;
revoke execute on function public.match_inventory_item(text, integer, real, boolean) from public, anon;
revoke execute on function public.try_uuid(text) from public, anon;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) to authenticated, service_role;
grant execute on function public.match_inventory_item(text, integer, real, boolean) to authenticated, service_role;
grant execute on function public.try_uuid(text) to authenticated, service_role;

-- 3. Dead grants on the four RLS-locked tables; service_role keeps its access explicitly.
revoke all on table public.app_secrets, public.admin_auth_attempts, public.telegram_pending,
  public.telegram_processed_updates from public, anon, authenticated;
grant all on table public.app_secrets, public.admin_auth_attempts, public.telegram_pending,
  public.telegram_processed_updates to service_role;

commit;
