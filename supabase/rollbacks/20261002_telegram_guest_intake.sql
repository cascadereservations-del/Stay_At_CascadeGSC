-- Compensating rollback for release telegram_guest_intake_20261002 (session 67b). The release only adds four functions and
-- changes no table, column, policy or grant on an existing object, so the rollback drops them. Rows the functions already wrote
-- (guest_profile_details, guest_companions and their history, Storage objects in guest-id-photos) are ordinary audited rows and
-- stay; they are visible and editable in the admin dashboard exactly like hand-entered ones. Deploy order on rollback: redeploy
-- the previous telegram-expense first (it stops calling these), then run this file.
begin;

drop function if exists public.telegram_save_guest_companion_v1(uuid, text, text, text, text, text, bigint, text);
drop function if exists public.telegram_save_guest_details_v1(uuid, jsonb, bigint, text);
drop function if exists public.telegram_guest_candidates_v1(bigint, uuid, date, date, text);
drop function if exists public.telegram_staff_actor_v1(bigint, uuid);

commit;
