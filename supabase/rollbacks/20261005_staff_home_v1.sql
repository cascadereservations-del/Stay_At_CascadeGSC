-- Compensating rollback for release staff_home_v1_20261005 (session 70, lane L3, SPEC-36, D-299.7/.9).
-- Drops the storage policy first (it calls a helper), then the RPC and every helper. Nothing else changed in that release,
-- so there is nothing to restore. The Cascade Staff app shows an error banner on its home until it is rolled back too.
begin;
drop policy if exists "guest id photos staff current read" on storage.objects;
drop function if exists public.staff_home_v1(uuid);
drop function if exists public.staff_can_view_guest_id_object_v1(text);
drop function if exists public.staff_guest_card_v1(uuid, uuid, date);
drop function if exists public.staff_primary_id_path_v1(uuid);
drop function if exists public.staff_current_next_stays_v1(uuid);
drop function if exists public.staff_stay_guest_id_v1(uuid, text, uuid, date, date);
drop function if exists public.staff_may_see_guest_id_v1(uuid);
drop function if exists public.staff_redact_v1(text);
drop function if exists public.staff_hide_money_v1(text);
commit;
