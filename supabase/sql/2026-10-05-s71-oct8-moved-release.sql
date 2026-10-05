-- s71 one-off (Lloyd 2026-10-05, D-299): the Thu 8 Oct Leon Llido maintenance MOVED. Free Oct 7-8 on our booking site and take the
-- Oct 8 notice off the operations board, exactly as power-watch's Unblock tap does (brownout.ts releaseNotice 'unblock').
-- Run AFTER power-watch 4fb64e0 is deployed: its guard keeps a released outage released when the same poster is read again.
-- Idempotent: a second run changes nothing. Airbnb is untouched (it stayed open).
begin;

update public.calendar_events
   set status = 'cancelled', updated_at = now()
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and source = 'manual'
   and uid in ('brownout:2026-10-07', 'brownout:2026-10-08') and status <> 'cancelled';

update public.ops_notices
   set is_active = false, updated_at = now()
 where id = 'e513774b-0531-4a8f-9af3-1a13878c76a9' and is_active;

update public.app_settings
   set value = value || jsonb_build_object(
         'status', 'released', 'blocked', '[]'::jsonb, 'card', null,
         'releasedAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
         'releasedBy', 'Lloyd: moved (D-299)'),
       updated_at = now()
 where key = 'power_watch_notice:2026-10-08' and value->>'status' = 'active';

select
  (select count(*) from public.calendar_events where uid in ('brownout:2026-10-07', 'brownout:2026-10-08') and status = 'blocked') = 0 as nights_free,
  (select not is_active from public.ops_notices where id = 'e513774b-0531-4a8f-9af3-1a13878c76a9') as notice_off_board,
  (select value->>'status' = 'released' and value->>'url' like '%SPI-PMS-10082026-LEON-LLIDO-SS.jpg' from public.app_settings where key = 'power_watch_notice:2026-10-08') as state_released_with_poster;

commit;
