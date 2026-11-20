-- Rollback of s127_bill_reminders_20261128: unschedules the daily job, puts the lane A today_bills_v1 body back (md5 f7cfd2f8ddd001229df63601b636c5b7, CR stripped) and the S81 staff_pay_admin_settle_v1 body (md5 f1909b8b1a166188797a7d28688664fb), drops the bill functions, the table and the setting,
-- removes the Today notices the job wrote, removes the two restrictive app_settings policies and takes 'bill' out of transactions_source_check again.
-- Refuses (55000, nothing changes) once a bill has been PAID or a transactions row with source 'bill' exists: the screenshots and the ledger rows would be orphaned. Delete those rows, or give them another source, by hand first (a void row would still hold the bill reference).
-- Roll the Staff app back first: it calls these functions. Grants restated as before this release.
begin;

do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.today_bills_v1(uuid)');
  if v is distinct from '70302291441c8493c622ae66befe6b79' and v is distinct from 'f7cfd2f8ddd001229df63601b636c5b7' then
    raise exception using errcode = '55000', message = 'rollback s127 bills: public.today_bills_v1(uuid) is neither this release nor the lane A body (md5 ' || coalesce(v, 'null') || ')';
  end if;
  if to_regclass('public.utility_bills') is not null and exists (select 1 from public.utility_bills where status = 'paid') then
    raise exception using errcode = '55000', message = 'rollback s127 bills: a bill is already paid; delete or re-source its transaction row and archive the bill by hand first';
  end if;
  if exists (select 1 from public.transactions where source = 'bill') then
    raise exception using errcode = '55000', message = 'rollback s127 bills: transactions rows with source bill exist; delete them or give them another source first';
  end if;
end $g$;

do $cron$
begin
  if to_regclass('cron.job') is not null and exists (select 1 from cron.job where jobname = 'bill-daily-0800-manila') then
    perform cron.unschedule('bill-daily-0800-manila');
  end if;
end $cron$;

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

-- staff_pay_admin_settle_v1 goes back to the S81 body (without the bill duplicate check); grants as S81 left them
create or replace function public.staff_pay_admin_settle_v1(p_request_id uuid, p_proof jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_r public.staff_pay_requests%rowtype;
  v_path text; v_client_sha text; v_sha text; v_ref text; v_amt numeric; v_verdict text; v_other text; v_name text; v_res jsonb; v_prefix text;
begin
  if v_uid is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select * into v_r from public.staff_pay_requests where id = p_request_id and property_id = c_prop for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_r.status not in ('paying', 'paid') then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;

  if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;
  v_path := btrim(coalesce(p_proof ->> 'path', ''));
  v_client_sha := lower(coalesce(p_proof ->> 'sha256', ''));
  v_ref := nullif(regexp_replace(upper(coalesce(p_proof ->> 'reference', '')), '[^A-Z0-9]', '', 'g'), '');
  v_prefix := c_prop::text || '/' || v_uid::text || '/';
  if (v_client_sha <> '' and v_client_sha !~ '^[0-9a-f]{64}$') or v_ref is null or char_length(v_ref) not between 4 and 64
     or coalesce(jsonb_typeof(p_proof -> 'amount'), '') <> 'number' or char_length(v_path) not between 40 and 300
     or left(v_path, length(v_prefix)) <> v_prefix or position('..' in v_path) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_proof');
  end if;
  v_amt := round((p_proof ->> 'amount')::numeric, 2);
  if v_amt <= 0 or v_amt > 10000000 then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;

  -- stored proof: the object exists in the private bucket and upload-photo recorded the hash of the bytes it stored
  select h.sha256 into v_sha from public.staff_upload_hashes h where h.path = v_path;
  if v_sha is null or not exists (select 1 from storage.objects o where o.bucket_id = 'cleaning-photos' and o.name = v_path) then
    return jsonb_build_object('ok', false, 'reason', 'no_stored_proof', 'ref', v_r.ref);
  end if;
  if v_client_sha <> '' and v_client_sha <> v_sha then return jsonb_build_object('ok', false, 'reason', 'sha_mismatch', 'ref', v_r.ref); end if;

  if v_r.status = 'paid' then -- a retry after a lost answer: the same screenshot bytes means it already worked
    if v_r.proof_sha256 = v_sha then return jsonb_build_object('ok', true, 'replay', true, 'status', 'paid', 'ref', v_r.ref, 'total', v_r.total_amount); end if;
    return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', 'paid', 'ref', v_r.ref);
  end if;
  if v_r.paying_by_user_id is distinct from v_uid then
    return jsonb_build_object('ok', false, 'reason', 'not_your_payment', 'paying_by_name', v_r.paying_by_name, 'ref', v_r.ref);
  end if;

  select o.ref into v_other from public.staff_pay_requests o
   where o.id <> v_r.id and (o.proof_sha256 = v_sha or o.proof_file_unique_id = 'web:' || v_path or o.proof_reference = v_ref) limit 1;
  if found then return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'other_ref', v_other, 'ref', v_r.ref); end if;

  if abs(v_amt - v_r.total_amount) < 0.5 then v_verdict := 'match';
  elsif coalesce(p_proof ->> 'override', '') = 'true' then v_verdict := 'override';
  else return jsonb_build_object('ok', false, 'reason', 'amount_mismatch', 'typed', v_amt, 'total', v_r.total_amount, 'ref', v_r.ref);
  end if;

  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Finance')
    into v_name from auth.users u where u.id = v_uid;
  v_name := left(coalesce(v_name, 'Finance'), 30) || ' via Staff app';

  begin
    v_res := public.staff_pay_settle_v1(v_r.id, null, v_name, v_verdict,
      jsonb_build_object('file_unique_id', 'web:' || v_path, 'file_id', v_path, 'sha256', v_sha, 'amount', v_amt, 'reference', v_ref,
                         'read', jsonb_build_object('source', 'staff_app', 'typed_by', v_uid)));
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'ref', v_r.ref);
  end;
  if coalesce((v_res ->> 'ok')::boolean, false) then
    update public.staff_pay_requests
       set proof_path = v_path, paid_by_user_id = v_uid, sent_said_at = coalesce(sent_said_at, now())
     where id = v_r.id;
  end if;
  return v_res;
end $$;
revoke all on function public.staff_pay_admin_settle_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.staff_pay_admin_settle_v1(uuid, jsonb) to authenticated;

-- the Today notices the daily job wrote (system reminders about bills and the meter reading)
delete from public.ops_notices n
 where n.source = 'system' and n.notice_type = 'reminder'
   and (n.id in (select b.notice_id from public.utility_bills b where b.notice_id is not null)
        or n.title like 'Meter reading due today (%' or n.description = 'See To pay on Today.');

drop function if exists public.bill_schedule_set_v1(uuid, text, jsonb);
drop function if exists public.bill_schedule_get_v1(uuid, text);
drop function if exists public.bill_proof_v1(uuid);
drop function if exists public.bill_pay_skip_v1(uuid);
drop function if exists public.bill_pay_cancel_v1(uuid);
drop function if exists public.bill_pay_settle_v1(uuid, jsonb);
drop function if exists public.bill_pay_open_v1(uuid);
drop function if exists public.bill_daily_v1(date, uuid);
drop function if exists public.bill_step_v1(uuid, text, uuid, text, jsonb);
drop function if exists public.bill_due_open_v1(uuid, date, text);
drop function if exists public.bill_reply_v1(jsonb, uuid);
drop function if exists public.bill_entry_v1(public.utility_bills, jsonb, boolean, uuid);
drop function if exists public.bill_json_v1(public.utility_bills);
drop function if exists public.bill_pay_info_v1(jsonb, text, text);
drop function if exists public.bill_can_v1(uuid);
drop function if exists public.bill_actor_name_v1(uuid);
drop function if exists public.bill_schedule_cfg_v1();
drop function if exists public.bill_cfg_one_v1(jsonb, text, jsonb, integer);
drop function if exists public.bill_cfg_day_v1(jsonb, integer);
drop function if exists public.bill_cfg_text_v1(jsonb, text);
drop table if exists public.utility_bills;
drop policy if exists app_settings_bill_schedule_closed_anon on public.app_settings;
drop policy if exists app_settings_bill_schedule_closed_staff on public.app_settings;
delete from public.app_settings where key = 'bill_schedule';

alter table public.transactions drop constraint if exists transactions_source_check;
alter table public.transactions add constraint transactions_source_check
  check (source = any (array['telegram', 'ocr', 'booking', 'manual', 'import', 'airbnb', 'airbnb_email', 'airbnb_payout_email', 'direct_booking', 'cleaner_fee', 'refund']));

commit;
