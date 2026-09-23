-- 2026-09-23 (session 45, Lloyd's yes): mark the three historical meter readings that
-- meter_readings_reviewed reports every day, each with the reason read from its neighbours.
-- All three predate the checklist's backwards-reading warning (2026-09-12) and the photo check (2026-09-13).
--
--   c5247fc5  2026-02-25  the first reading ever; nothing before it to compare with      -> first_reading
--   0c601f88  2026-03-09  water 39.782 -> 39.675: a mistyped digit on 8 or 9 March        -> misread
--   0eb545f0  2026-07-01  2931 kWh / 56.598 m3 re-typed from 2026-06-21 as the new
--                         reading; 2026-07-02 jumped +232 kWh to catch up                 -> re_entry
--
-- Flags are from review_meter_reading_v1's vocabulary (first_reading, re_entry, misread, duplicate,
-- under_review), so the dashboard's Review control shows and can change them. The numbers are never edited.
--
-- Guarded: exactly these three ids, only while still unflagged. Any other count rolls back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.

begin;

do $$
declare n integer := 0; k integer;
begin
  update public.meter_readings set meter_flag = 'first_reading',
         meter_override_note = 'Reviewed 2026-09-23: the first reading on record, no previous reading to compare.'
   where id = 'c5247fc5-ff65-48a3-b233-511a16b8ca05' and meter_flag is null;
  get diagnostics k = row_count; n := n + k;

  update public.meter_readings set meter_flag = 'misread',
         meter_override_note = 'Reviewed 2026-09-23: water 39.782 then 39.675, a mistyped digit on 8 or 9 March; electric is consistent.'
   where id = '0c601f88-1073-44ef-b444-405d0291ddc7' and meter_flag is null;
  get diagnostics k = row_count; n := n + k;

  update public.meter_readings set meter_flag = 're_entry',
         meter_override_note = 'Reviewed 2026-09-23: the 2026-06-21 reading (2931 kWh, 56.598 m3) was re-typed as the new one; 2026-07-02 caught up.'
   where id = '0eb545f0-4df1-4d34-8c76-143ee897db25' and meter_flag is null;
  get diagnostics k = row_count; n := n + k;

  if n <> 3 then
    raise exception 'expected to flag 3 meter readings, matched %; nothing changed', n;
  end if;
  raise notice 'flagged % historical meter readings', n;
end $$;

commit;
