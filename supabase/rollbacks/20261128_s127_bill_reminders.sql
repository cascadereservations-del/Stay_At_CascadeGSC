-- Rollback of s127_bill_reminders_20261128: puts the lane A today_bills_v1 body back (md5 f7cfd2f8ddd001229df63601b636c5b7, CR stripped), drops the bill functions, the table and the setting, removes the two restrictive
-- app_settings policies and takes 'bill' out of transactions_source_check again.
-- Refuses (55000, nothing changes) once a bill has been PAID or a transactions row with source 'bill' exists: the screenshots and the ledger rows would be orphaned. Void those rows by hand first.
-- Roll the Telegram lane (waves) back first: it calls these functions. Grants restated as before this release.
begin;

do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.today_bills_v1(uuid)');
  if v is distinct from '1f581c3b6ce841395c5e7d2cf6207936' and v is distinct from 'f7cfd2f8ddd001229df63601b636c5b7' then
    raise exception using errcode = '55000', message = 'rollback s127 bills: public.today_bills_v1(uuid) is neither this release nor the lane A body (md5 ' || coalesce(v, 'null') || ')';
  end if;
  if to_regclass('public.utility_bills') is not null and exists (select 1 from public.utility_bills where status = 'paid') then
    raise exception using errcode = '55000', message = 'rollback s127 bills: a bill is already paid; void its transaction and archive the row by hand first';
  end if;
  if exists (select 1 from public.transactions where source = 'bill') then
    raise exception using errcode = '55000', message = 'rollback s127 bills: transactions rows with source bill exist; void them first';
  end if;
end $g$;

create or replace function public.today_bills_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null or p_property_id is null or not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not authorized';
  end if;
  v := public.utility_bill_estimate_v1(p_property_id, public.manila_today());
  return jsonb_build_object(
    'since', (v -> 'electric' ->> 'cycle_from')::date,
    'last_reading_at', v -> 'electric' -> 'last_reading_at',
    'electric', jsonb_build_object('php', v -> 'electric' -> 'so_far_php', 'kwh', v -> 'electric' -> 'kwh'),
    'water', jsonb_build_object('php', v -> 'water' -> 'so_far_php', 'm3', v -> 'water' -> 'm3'));
end;
$$;
revoke all on function public.today_bills_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.today_bills_v1(uuid) to authenticated;

drop function if exists public.bill_step_v1(uuid, text, bigint, text, jsonb);
drop function if exists public.bill_due_open_v1(uuid, date);
drop function if exists public.bill_json_v1(public.utility_bills);
drop function if exists public.bill_schedule_cfg_v1();
drop function if exists public.bill_cfg_text_v1(jsonb, text);
drop table if exists public.utility_bills;
drop policy if exists app_settings_bill_schedule_closed_anon on public.app_settings;
drop policy if exists app_settings_bill_schedule_closed_staff on public.app_settings;
delete from public.app_settings where key = 'bill_schedule';

alter table public.transactions drop constraint if exists transactions_source_check;
alter table public.transactions add constraint transactions_source_check
  check (source = any (array['telegram', 'ocr', 'booking', 'manual', 'import', 'airbnb', 'airbnb_email', 'airbnb_payout_email', 'direct_booking', 'cleaner_fee', 'refund']));

commit;
