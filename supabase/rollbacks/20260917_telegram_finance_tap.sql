-- Compensating rollback for 20260917000000_telegram_finance_tap.sql: drops the two functions and the
-- Telegram mapping column. Reviews already recorded through the tap stay (they are real decisions).
begin;
drop function if exists public.telegram_finance_decide_booking_v1(bigint, uuid, text, text);
drop function if exists public.unreviewed_booking_receipts_v1(numeric, numeric);
drop index if exists public.staff_access_profiles_telegram_user_id_key;
alter table public.staff_access_profiles drop column if exists telegram_user_id;
commit;
