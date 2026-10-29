-- Compensating rollback for release s100_meter_no_photo_20261104 (migration 20261104000000_s100_meter_no_photo.sql).
-- Unschedules the cron job meter-settle-estimates and restores the original review_meter_reading_v1 body and drops the six functions. The table meter_skip_exceptions is dropped only when it is empty of anything
-- but the two rows the data step wrote (2026-10-19 and 2026-10-21); otherwise it is left in place (admin exceptions are decisions, not scaffolding).
-- NOT undone: meter rows already flagged estimate_pending / typed_accepted / estimated (and any numbers the settle job replaced: the follow-up task
-- meter_estimate_settled keeps the typed and final values), sessions already declared "no meter photo", follow-up tasks already opened.
-- Old behaviour needs nothing restored: can_skip_meter_photos (v1) and every other function were never touched. Roll the Staff app and submit-cleaning back FIRST
-- if a build that calls the v2 functions is live (the old app falls back to v1 on a missing function).
-- Apply with run-sql-on-host.sh.

begin;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'meter-settle-estimates';
  end if;
end $$;

-- put back the 20260914200000 body of review_meter_reading_v1 (md5 1b23dc6085db7eeee408fe63bc0f50be); refuses if it is not the s100 body
do $g$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.review_meter_reading_v1(uuid,text,text)');
  if v_got is distinct from 'daaff99a3e67b8a156669973f5f8733a' and v_got is distinct from '1b23dc6085db7eeee408fe63bc0f50be' then
    raise exception 's100 rollback: review_meter_reading_v1 is neither the s100 nor the original body (md5 %)', v_got using errcode = '55000';
  end if;
end $g$;
create or replace function public.review_meter_reading_v1(p_reading_id uuid, p_flag text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $
declare v_prop uuid; v_flag text := nullif(btrim(coalesce(p_flag, '')), '');
begin
  select property_id into v_prop from public.meter_readings where id = p_reading_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'meter reading not found'; end if;
  perform public.admin_require('inspect_cleaning', v_prop);
  if v_flag is not null and v_flag not in ('first_reading','re_entry','misread','duplicate','under_review') then raise exception using errcode = '22023', message = 'unknown meter flag'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception using errcode = '22023', message = 'a reason is required'; end if;
  perform public.admin_audit_context_v1(btrim(p_reason), null, null);
  update public.meter_readings set meter_flag = v_flag, meter_override_note = btrim(p_reason) where id = p_reading_id;
  return jsonb_build_object('ok', true, 'id', p_reading_id, 'flag', v_flag, 'auditId', (select id from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = p_reading_id order by created_at desc limit 1));
end;
$;
revoke all on function public.review_meter_reading_v1(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.review_meter_reading_v1(uuid, text, text) to authenticated;

drop function if exists public.meter_settle_estimates_v1(uuid);
drop function if exists public.report_no_meter_photo_v1(uuid, text);
drop function if exists public.meter_no_photo_notice_v1(uuid);
drop function if exists public.can_skip_meter_photos_v2(uuid, date);
drop function if exists public.s_meter_skip_check_v1(uuid, date, uuid);
drop function if exists public.s_meter_nights_v1(uuid);

do $$
begin
  if to_regclass('public.meter_skip_exceptions') is not null then
    if (select count(*) from public.meter_skip_exceptions
         where not (checkout_date in ('2026-10-19', '2026-10-21') and property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')) = 0 then
      drop table public.meter_skip_exceptions;
    else
      raise notice 's100 rollback: meter_skip_exceptions holds other exceptions and was left in place';
    end if;
  end if;
end $$;

commit;
