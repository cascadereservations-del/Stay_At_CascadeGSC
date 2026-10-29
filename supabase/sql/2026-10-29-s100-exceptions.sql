-- s100 (D-352) data step, run AFTER migration 20261104000000_s100_meter_no_photo.sql. Not part of the migration. Idempotent: a second run changes nothing.
-- Honey's phone lost the meter photos of the 19 Oct (Shaneen) and 21 Oct (Ysabel) stays.
--   1. admin exceptions for the check-out dates 2026-10-19 and 2026-10-21 (the pair lifts the never-two-in-a-row rule between exactly these two stays);
--   2. Shaneen's session is declared "no meter photo" and her reading becomes estimate_pending; her mismatch is answered, which lifts the block on Lyka's report
--      (this also covers docs/s100/2026-10-29-s100-unblock-shaneen.sql, which may already have run: it stamped the answer and the skip, this keeps both and adds the flag);
--   3. the admin follow-up task (idempotent per session).
-- Ysabel has no report and no photo: only her exception row is written. The settle job (cron meter-settle-estimates) does the rest once the next stay is verified.
-- Surprises raise and roll everything back. Apply with run-sql-on-host.sh.
begin;
do $$
declare
  c_prop  constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  c_note  constant text := 'Honey phone malfunction, meter photos lost (D-352)';
  v_sess  uuid;
  n_exc   int;
  n_rows  int;
begin
  if to_regclass('public.meter_skip_exceptions') is null or to_regprocedure('public.meter_no_photo_notice_v1(uuid)') is null then
    raise exception 's100 data step: apply migration 20261104000000_s100_meter_no_photo.sql first';
  end if;

  -- both stays must exist on the calendar, or the exception means nothing
  if (select count(distinct ce.checkout_date) from public.calendar_events ce
       where ce.property_id = c_prop and ce.status = 'confirmed' and ce.checkout_date in ('2026-10-19', '2026-10-21')) <> 2 then
    raise exception 's100 data step: expected a confirmed stay checking out on 2026-10-19 and on 2026-10-21';
  end if;

  insert into public.meter_skip_exceptions (property_id, checkout_date, note)
  values (c_prop, '2026-10-19', c_note), (c_prop, '2026-10-21', c_note)
  on conflict (property_id, checkout_date) do nothing;
  select count(*) into n_exc from public.meter_skip_exceptions where property_id = c_prop and checkout_date in ('2026-10-19', '2026-10-21');
  if n_exc <> 2 then raise exception 's100 data step: expected 2 exception rows, got %', n_exc; end if;

  -- Shaneen's turnover report of the 19 Oct stay: exactly one
  select cs.id into v_sess from public.cleaning_sessions cs
   where cs.property_id = c_prop and cs.checkout_date = '2026-10-19' and cs.cleaning_type in ('turnover', 'deep_clean') and cs.last_guest_name ilike 'Shaneen%';
  if v_sess is null or (select count(*) from public.cleaning_sessions cs
       where cs.property_id = c_prop and cs.checkout_date = '2026-10-19' and cs.cleaning_type in ('turnover', 'deep_clean') and cs.last_guest_name ilike 'Shaneen%') <> 1 then
    raise exception 's100 data step: expected exactly one Shaneen turnover session for 2026-10-19';
  end if;
  select count(*) into n_rows from public.meter_readings where session_id = v_sess;
  if n_rows <> 1 then raise exception 's100 data step: expected 1 meter row for Shaneen, got %', n_rows; end if;
  -- an unflagged row must be the mismatch we know about; any other state is a surprise (already settled or answered rows are fine)
  if exists (select 1 from public.meter_readings where session_id = v_sess and meter_flag is null and vision_verdict is distinct from 'mismatch') then
    raise exception 's100 data step: Shaneen''s meter row is unflagged but its vision verdict is not mismatch';
  end if;

  update public.cleaning_sessions
     set meter_photos_skipped = true,
         meter_photo_skip_note = coalesce(meter_photo_skip_note, 'Phone malfunction, meter photo lost (exception D-352)')
   where id = v_sess and not meter_photos_skipped;

  update public.meter_readings
     set meter_flag = coalesce(meter_flag, 'estimate_pending'),
         vision_resolved_at = coalesce(vision_resolved_at, now()),
         vision_resolved_note = coalesce(vision_resolved_note, 'Exception D-352 (Lloyd 2026-10-29): no meter photo was taken, phone malfunction. Typed reading kept until the next verified reading.')
   where session_id = v_sess;

  perform public.meter_no_photo_notice_v1(v_sess);

  if not exists (select 1 from public.meter_readings where session_id = v_sess and meter_flag is not null and vision_resolved_at is not null)
     or not exists (select 1 from public.cleaning_sessions where id = v_sess and meter_photos_skipped) then
    raise exception 's100 data step: Shaneen''s session was not left skipped, flagged and answered';
  end if;
  raise notice 's100 data step done: 2 exceptions, Shaneen skipped + flagged + answered, task opened';
end $$;
commit;
