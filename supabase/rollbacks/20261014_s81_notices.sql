-- Rollback for release s81_notices_20261014. Compensating, not a restore.
--   * drops notices_v1 and ops_notice_add_v1 (the Staff v5 app hides the Notices screen when notices_v1 is absent: PGRST202);
--   * puts the two ops_notices checks back to their pre-release value lists. Rows that use a value the old check does not allow cannot
--     stay: notices of type water / maintenance / deep_clean / note are DELETED (they exist only if someone saved one after the release;
--     the three older types are untouched), and a source of gscwd / manual / system is set to null on the rows that remain;
--   * removes app_settings house_times only while it still equals the seeded value (a value someone changed on purpose stays).
-- Safe until: any time. The deleted notices are manual reminders, not a ledger; take a backup first if any matter.

begin;

drop function if exists public.notices_v1(uuid);
drop function if exists public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid);

delete from public.ops_notices where notice_type in ('water', 'maintenance', 'deep_clean', 'note');
update public.ops_notices set source = null where source in ('gscwd', 'manual', 'system');

alter table public.ops_notices drop constraint if exists ops_notices_notice_type_check;
alter table public.ops_notices add constraint ops_notices_notice_type_check
  check (notice_type in ('brownout', 'holiday', 'event', 'reminder'));
alter table public.ops_notices drop constraint if exists ops_notices_source_check;
alter table public.ops_notices add constraint ops_notices_source_check
  check (source in ('socoteco', 'ngcp', 'staff'));

delete from public.app_settings where key = 'house_times' and value = '{"check_out":"12:00","check_in":"14:00"}'::jsonb;

delete from public.app_settings where key = 'notice_sources' and value = '{"water_page":"https://www.facebook.com/gscwaterdistrict/","power_page":"https://www.facebook.com/socoteco2.EC/"}'::jsonb;

commit;
