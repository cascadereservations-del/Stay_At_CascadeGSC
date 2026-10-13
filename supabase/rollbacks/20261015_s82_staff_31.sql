-- Rollback for release s82_staff_31_20261015. Compensating: puts the four redefined functions back to the bodies this release was cut from
-- (notices_v1 and staff_pay_admin_list_v1 as s81 shipped them, staff_home_v1 as 20261009040000, staff_pay_settle_v1 as 20261005110000) and drops
-- everything the release added.
-- DATA LOSS (by design): ops_notices.source_url (the links), staff_pay_requests.created_by_user_id (who made a request on a staff member's behalf; the
-- audit log still names the actor), the cleaning_progress rows (today's checklist position), and the pay-weekly-sweep heartbeat row.
-- Pay requests made through staff_pay_admin_create_v1 stay: they are normal requested rows and the existing Pay flow keeps working on them.
-- Apply with run-sql-on-host.sh. Then redeploy power-watch, telegram-cassy and telegram-expense from the previous commit (they stop writing source_url).

begin;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 's82-pay-weekly-sweep';
  end if;
end $$;
delete from public.job_heartbeats where job_name = 'pay-weekly-sweep';

drop function if exists public.get_shopping_list_v1(uuid);
drop function if exists public.s_weekly_sweep_v1();
drop function if exists public.s_paid_unnotified_v1();
drop function if exists public.staff_pay_admin_create_v1(uuid, jsonb, uuid[], text);
drop function if exists public.cleaning_progress_v1();
drop function if exists public.cleaning_progress_set_v1(integer, integer, text);

-- 0. inventory: the shopping list is readable again with all its columns; both functions go back to the bodies this release was cut from
grant select on public.inventory_shopping_list to authenticated;
create or replace function public.save_shopping_item_v1(p_property_id uuid, p_item jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.inventory_shopping_list%rowtype; v_id uuid; v_status text;
begin
  perform public.admin_require('read_operations', p_property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  v_id := nullif(p_item->>'id', '')::uuid;
  if v_id is null then
    select * into v_row from public.inventory_shopping_list where idempotency_key = p_idempotency_key;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', true); end if;
    insert into public.inventory_shopping_list(property_id, item_id, item_name, quantity, purchase_unit, estimated_cost, reason, proposed_by, idempotency_key)
    values (p_property_id, nullif(p_item->>'item_id', '')::uuid, p_item->>'item_name', (p_item->>'quantity')::numeric, p_item->>'purchase_unit', nullif(p_item->>'estimated_cost', '')::numeric, p_item->>'reason', auth.uid(), p_idempotency_key)
    returning * into v_row;
  else
    v_status := p_item->>'status';
    if v_status in ('approved','rejected') then perform public.admin_require('manage_inventory', p_property_id); end if;
    select * into v_row from public.inventory_shopping_list where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'shopping item not found'; end if;
    if v_status = 'received' then raise exception using errcode = '22023', message = 'use record_inventory_receipt_v1 to receive goods'; end if;
    update public.inventory_shopping_list set
      status = coalesce(v_status, status), quantity = coalesce(nullif(p_item->>'quantity', '')::numeric, quantity), reason = coalesce(p_item->>'reason', reason),
      approved_by = case when v_status in ('approved','rejected') then auth.uid() else approved_by end,
      approved_at = case when v_status in ('approved','rejected') then now() else approved_at end,
      approval_note = coalesce(p_item->>'approval_note', approval_note), version = version + 1, updated_at = now()
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'version', v_row.version);
end;
$$;
revoke all on function public.save_shopping_item_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.save_shopping_item_v1(uuid, jsonb, text) to authenticated;

create or replace function public.apply_inventory_purchase(p_item_id uuid, p_qty numeric, p_unit_cost numeric default null::numeric, p_supplier text default null::text, p_purchased_at date default current_date, p_txn_id uuid default null::uuid)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_upp numeric; v_before numeric; v_after numeric; v_pid uuid; v_name text;
begin
  select coalesce(units_per_purchase, 1), qty_on_hand, name
    into v_upp, v_before, v_name
  from inventory_items where id = p_item_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'item_not_found');
  end if;

  insert into inventory_purchases(item_id, qty, unit_cost, supplier, purchased_at, units_per_purchase, notes)
  values (p_item_id, p_qty, p_unit_cost, p_supplier, coalesce(p_purchased_at, current_date), v_upp,
          'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end)
  returning id into v_pid;

  v_after := coalesce(v_before, 0) + (p_qty * v_upp);
  update inventory_items set qty_on_hand = v_after where id = p_item_id;

  insert into inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', p_item_id, 'ocr_restock',
          jsonb_build_object('qty_on_hand', v_before),
          jsonb_build_object('qty_on_hand', v_after, 'purchase_id', v_pid, 'qty_added', p_qty * v_upp),
          'telegram-ocr');

  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,
                            'qty_before', v_before, 'qty_after', v_after, 'added', p_qty * v_upp);
end; $$;
revoke execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) from public, anon;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) to authenticated, service_role;
drop function if exists public.s_inventory_purchase_movement_v1(uuid, numeric, text, text);

-- 1. staff_pay_settle_v1 back to the 20261005110000 body
create or replace function public.staff_pay_settle_v1(p_id uuid, p_actor_tg bigint, p_actor text, p_verdict text, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_r public.staff_pay_requests%rowtype;
  v_l jsonb; v_s public.cleaning_sessions%rowtype; v_c public.cleaning_expense_claims%rowtype;
  v_txn uuid; v_uid uuid; v_label text;
begin
  select * into v_r from public.staff_pay_requests where id = p_id;
  for v_l in select value from jsonb_array_elements(v_r.lines) loop
    if v_l->>'kind' = 'clean' then
      select * into v_s from public.cleaning_sessions where id = (v_l->>'session_id')::uuid for update;
      if not found or v_s.fee_paid_at is not null or v_s.pay_request_id is distinct from v_r.id
         or exists (select 1 from public.transactions t where t.external_ref = 'cleanfee:' || v_s.id and t.status <> 'void') then
        return jsonb_build_object('ok', false, 'reason', 'already_paid', 'date', v_l->>'date', 'status', v_r.status);
      end if;
    else
      select * into v_c from public.cleaning_expense_claims where id = (v_l->>'claim_id')::uuid for update;
      if not found or v_c.pay_request_id is distinct from v_r.id or v_c.status not in ('pending_review', 'approved')
         or exists (select 1 from public.transactions t where t.external_ref = 'claim:' || v_c.id and t.status <> 'void') then
        return jsonb_build_object('ok', false, 'reason', 'already_paid', 'date', v_l->>'date', 'status', v_r.status);
      end if;
    end if;
  end loop;

  perform set_config('cascade.audit_reason', 'staff pay ' || v_r.ref || ' paid by ' || p_actor, true);
  select user_id into v_uid from public.staff_access_profiles
   where p_actor_tg is not null and telegram_user_id = p_actor_tg and public.staff_access_allowed(role, 'approve_payment', disabled_at, null) limit 1;

  for v_l in select value from jsonb_array_elements(v_r.lines) loop
    if v_l->>'kind' = 'clean' then
      select * into v_s from public.cleaning_sessions where id = (v_l->>'session_id')::uuid;
      v_label := case v_l->>'type' when 'deep_clean' then 'Deep Clean' when 'mid_stay' then 'Mid-stay' else 'Turnover' end
                 || case when coalesce((v_l->>'transport')::numeric, 0) > 0 then ' + transport' else '' end;
      insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
      values (v_r.property_id, 'expense', 'cleaning', 'confirmed', 'cleaner_fee', (v_l->>'amount')::numeric, v_s.cleaner_name, (v_l->>'date')::date,
              'cleanfee:' || v_s.id,
              'Cleaning fee - ' || v_s.cleaner_name || ', ' || (v_l->>'date') || ', ' || v_label || '. Pay request ' || v_r.ref || '.',
              'Telegram: ' || p_actor)
      returning id into v_txn;
      update public.cleaning_sessions set fee_amount = (v_l->>'amount')::numeric, fee_paid_at = now(), fee_txn_id = v_txn where id = v_s.id;
    else
      select * into v_c from public.cleaning_expense_claims where id = (v_l->>'claim_id')::uuid;
      insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
      values (v_r.property_id, 'expense', 'supplies', 'confirmed', 'cleaner_fee', (v_l->>'amount')::numeric, v_r.payee_name, v_c.expense_date,
              'claim:' || v_c.id,
              'Staff expense - ' || v_c.description || '. Pay request ' || v_r.ref || '.',
              'Telegram: ' || p_actor);
      update public.cleaning_expense_claims
         set status = 'paid', reviewed_at = now(), reviewed_by_user_id = v_uid,
             review_note = 'Paid in request ' || v_r.ref || ', confirmed by ' || p_actor || ' in Telegram'
       where id = v_c.id;
    end if;
  end loop;

  update public.staff_pay_requests set
    status = 'paid', paid_at = now(), paid_by_tg = p_actor_tg, paid_by_name = p_actor, paid_by_user_id = v_uid, proof_verdict = p_verdict,
    proof_file_unique_id = case when p_proof is null then proof_file_unique_id else p_proof->>'file_unique_id' end,
    proof_file_id        = case when p_proof is null then proof_file_id        else nullif(p_proof->>'file_id', '') end,
    proof_sha256         = case when p_proof is null then proof_sha256         else p_proof->>'sha256' end,
    proof_amount         = case when p_proof is null then proof_amount         when jsonb_typeof(p_proof->'amount') = 'number' then (p_proof->>'amount')::numeric end,
    proof_reference      = case when p_proof is null then proof_reference      else nullif(p_proof->>'reference', '') end,
    proof_read           = case when p_proof is null then proof_read           else jsonb_build_object('read', p_proof->'read', 'verdict', p_verdict) end
  where id = v_r.id;
  return jsonb_build_object('ok', true, 'status', 'paid', 'ref', v_r.ref, 'total', v_r.total_amount, 'verdict', p_verdict);
end $$;
revoke all on function public.staff_pay_settle_v1(uuid, bigint, text, text, jsonb) from public, anon, authenticated, service_role;

-- 2. staff_pay_admin_list_v1 back to the s81 body (no unrequested)
create or replace function public.staff_pay_admin_list_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_rows jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'ref', q.ref, 'status', q.status, 'payee_name', q.payee_name, 'total', q.total_amount, 'created_at', q.created_at,
      'paying_by_name', q.paying_by_name, 'paying_by_user_id', case when q.status = 'paying' then q.paying_by_user_id end, 'paying_at', q.paying_at, 'sent_said_at', q.sent_said_at, 'paid_at', q.paid_at,
      'has_proof', q.proof_file_unique_id is not null, 'bank_reference', q.proof_reference,
      'has_qr', exists (select 1 from public.staff_details d where d.user_id = q.payee_user_id and d.payout_qrph is not null),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('kind', l ->> 'kind', 'date', l ->> 'date', 'type', l ->> 'type',
                                                              'description', l ->> 'description', 'amount', l -> 'amount') order by l ->> 'date'), '[]'::jsonb)
                  from jsonb_array_elements(q.lines) l)
    ) order by (q.status in ('requested', 'paying')) desc, q.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.staff_pay_requests r
           where r.property_id = c_prop
             and (r.status in ('requested', 'paying') or (r.status = 'paid' and r.paid_at > now() - interval '14 days'))
           order by (r.status in ('requested', 'paying')) desc, r.created_at desc limit 30) q;
  return jsonb_build_object('ok', true, 'requests', v_rows);
end $$;
revoke all on function public.staff_pay_admin_list_v1() from public, anon, service_role;
grant execute on function public.staff_pay_admin_list_v1() to authenticated;

-- 3. staff_home_v1 back to the 20261009040000 body (md5 d04e3c492bbeba8722554ac5c951c928); the helper goes
create or replace function public.staff_home_v1(p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
returns jsonb
language plpgsql stable security definer
set search_path to ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_role  text;
  v_ops_checks text[] := array['V6'];
  v_cal jsonb; v_flags jsonb; v_cur jsonb; v_next jsonb; v_warn jsonb; v_weather jsonb;
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select p.role into v_role from public.staff_access_profiles p where p.user_id = auth.uid();

  -- calendar: names and dates only; contact columns, the raw feed text and the reconciliation fields are never selected.
  select coalesce(jsonb_agg(jsonb_build_object(
           'uid', e.uid, 'guest_name', case when e.status = 'blocked' then null else public.staff_redact_v1(e.guest_name) end,
           'checkin_date', e.checkin_date, 'checkout_date', e.checkout_date, 'nights', e.nights,
           'status', e.status, 'source', e.source,
           'checkin_time', e.checkin_time, 'checkout_time', e.checkout_time,
           -- S77 calendar contract: why a block exists, as a short label. Only the 8-character booking ref is read out of block_note.
           'block_reason', case when e.status = 'blocked' then
                             case e.block_reason when 'owner_use' then 'owner' when 'unblock' then 'other' else e.block_reason end end,
           'block_label', case when e.status = 'blocked' then
                             case e.block_reason
                               when 'direct' then 'Direct booking'
                                    || coalesce(' ' || upper(substring(e.block_note from '(?i)\mDIR\s+([0-9a-f]{8})\M')), '')
                               when 'brownout' then 'Brownout'
                               when 'maintenance' then 'Maintenance'
                               when 'owner_use' then 'Owner use'
                               else 'Blocked' end end) order by e.checkin_date, e.uid), '[]'::jsonb)
    into v_cal
  from public.calendar_events e
  where e.property_id = p_property_id and e.status in ('confirmed','blocked')
    and e.checkout_date >= v_today - 7 and e.checkin_date <= v_today + 60;

  -- day flags: manual flags plus brownout and maintenance derived from the calendar and the brownout notices, one per (date, kind);
  -- manual wins over a notice, a notice over a calendar block. ponytail: a brownout that runs past midnight flags its start date only.
  with n as (
    select d::date as day, 'brownout' as kind, 'Brownout' as label, 'auto' as source, null::uuid as id, 2 as pri
      from public.calendar_events e
     cross join lateral generate_series(greatest(e.checkin_date, v_today - 30)::timestamp,
                                        least(greatest(e.checkout_date - 1, e.checkin_date), v_today + 120)::timestamp, interval '1 day') d
     where e.property_id = p_property_id and e.status = 'blocked' and e.block_reason = 'brownout'
       and e.checkout_date >= v_today - 30 and e.checkin_date <= v_today + 120
    union all
    select d::date, 'maintenance', 'Maintenance', 'auto', null::uuid, 2
      from public.calendar_events e
     cross join lateral generate_series(greatest(e.checkin_date, v_today - 30)::timestamp,
                                        least(greatest(e.checkout_date - 1, e.checkin_date), v_today + 120)::timestamp, interval '1 day') d
     where e.property_id = p_property_id and e.status = 'blocked' and e.block_reason = 'maintenance'
       and e.checkout_date >= v_today - 30 and e.checkin_date <= v_today + 120
    union all
    select o.effective_date, 'brownout',
           case o.source when 'socoteco' then 'Brownout (SOCOTECO)' when 'ngcp' then 'Brownout (NGCP)' else 'Brownout' end, 'auto', null::uuid, 1
      from public.ops_notices o
     where o.property_id = p_property_id and o.is_active and o.notice_type = 'brownout'
       and coalesce(o.audience,'staff') in ('staff','all')
       and (o.expires_at is null or o.expires_at > now()) and o.effective_date >= v_today - 1
    union all
    select f.date, f.kind, public.staff_redact_v1(f.label), 'manual', f.id, 0
      from public.calendar_day_flags f
     where f.property_id = p_property_id and f.cleared_at is null
  ), u as (
    select distinct on (day, kind) day, kind, label, source, id
      from n where day between v_today - 30 and v_today + 120
     order by day, kind, pri
  )
  select coalesce(jsonb_agg(jsonb_build_object('date', day, 'kind', kind, 'label', label, 'source', source, 'id', id)
                            order by day, kind), '[]'::jsonb)
    into v_flags from u;

  -- current and next guest: the calendar fields plus the guest card (D-299.7, D-299.9).
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
         || public.staff_guest_contact_v1(s.guest_id)
         || public.staff_guest_companions_v1(s.guest_id)
    into v_cur from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'current';
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
         || public.staff_guest_contact_v1(s.guest_id)
         || public.staff_guest_companions_v1(s.guest_id)
    into v_next from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'next';

  with w as (
    select 'brownout' kind, 'alert' severity, public.staff_redact_v1(n.title) title,
           jsonb_build_object('date', n.effective_date, 'time', n.effective_time, 'hours', n.duration_hours,
                              'grid_line', public.staff_redact_v1(n.feeder), 'posted_by', public.staff_redact_v1(n.posted_by_name)) detail,
           n.effective_date::timestamptz at_ts, null::text as key, false as acked, null::jsonb as facts
      from public.ops_notices n
     where n.property_id = p_property_id and n.is_active and n.notice_type = 'brownout'
       and coalesce(n.audience,'staff') in ('staff','all')
       and (n.expires_at is null or n.expires_at > now()) and n.effective_date >= v_today - 1
    union all
    select 'verifier', case f.severity when 'red' then 'alert' else 'warn' end, public.staff_redact_v1(f.title) title,
           jsonb_build_object('check_id', f.check_id, 'status', f.status), f.last_seen, f.key, f.status = 'acknowledged', public.staff_verifier_facts_v1(f.check_id, f.detail)
      from public.verifier_findings f
     where f.status = 'open'
       and (v_role in ('owner','admin','finance') or f.check_id = any(v_ops_checks))
    union all
    select 'inventory', 'warn', public.staff_redact_v1('Low stock: ' || i.name) title,
           jsonb_build_object('qty', i.qty_on_hand, 'unit', i.unit, 'reorder_below', i.reorder_below), i.updated_at, null::text, false, null::jsonb
      from public.inventory_items i
     where i.property_id = p_property_id and i.is_active and i.qty_on_hand < i.reorder_below
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'severity', severity, 'title', title,
                                               'detail', detail, 'at', at_ts, 'key', key, 'acknowledged', acked, 'facts', facts)
                  order by case kind when 'brownout' then 0 when 'inventory' then 2 else 1 end, at_ts desc), '[]'::jsonb)
    into v_warn from w;

  -- weather: the 15-minute cache weather-proxy keeps; an allow-list of eight display fields, nothing else.
  select jsonb_build_object('source', s.value->>'source', 'fetched_at', s.value->>'fetched_at',
                            'current', jsonb_build_object(
                              'temp', s.value#>'{current,temp}', 'emoji', s.value#>'{current,emoji}',
                              'description', s.value#>'{current,description}', 'rain_prob', s.value#>'{current,rain_prob}',
                              'today_high', s.value#>'{current,today_high}', 'today_low', s.value#>'{current,today_low}',
                              'humidity', s.value#>'{current,humidity}', 'uv_label', s.value#>'{current,uv_label}'))
    into v_weather from public.app_settings s where s.key = 'weather_proxy_cache';

  return jsonb_build_object(
    'role', v_role, 'today', v_today, 'property_id', p_property_id,
    'calendar', v_cal, 'day_flags', v_flags, 'current_guest', v_cur, 'next_guest', v_next,
    'warnings', v_warn, 'weather', v_weather, 'generated_at', now());
end $$;
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

-- 4. notices_v1 back to the s81 body (md5 f3f0653167ffaa39fa155287a13b913a), no url
create or replace function public.notices_v1(p_property_id uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to ''
as $$
declare
  v_pid   uuid := coalesce(p_property_id,
                           (select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                           '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_role  text;
  v_priv  boolean;
  v_now_local timestamp := now() at time zone 'Asia/Manila';
  v_times jsonb; v_sources jsonb; v_wx jsonb; v_notices jsonb; v_house jsonb; v_inbox integer;
  c       jsonb; c_at timestamptz;
begin
  if not public.current_staff_authorized('read_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select p.role into v_role from public.staff_access_profiles p where p.user_id = auth.uid();
  v_priv := public.current_staff_authorized('manage_operations', v_pid);   -- owner and admin only

  -- house times: the shared setting, the contract fallback when it is missing or malformed.
  select jsonb_build_object('check_out', coalesce(s.value->>'check_out', '12:00'), 'check_in', coalesce(s.value->>'check_in', '14:00'))
    into v_times from public.app_settings s where s.key = 'house_times';
  v_times := coalesce(v_times, '{"check_out":"12:00","check_in":"14:00"}'::jsonb);

  -- each link is used only if it is a plain Facebook page URL; a missing, malformed or non-Facebook value falls back to the built-in page for that key.
  select jsonb_build_object(
           'water_page', case when s.value->>'water_page' ~ '^https://(www\.)?facebook\.com/[A-Za-z0-9.]+/?$' then s.value->>'water_page' else 'https://www.facebook.com/gscwaterdistrict/' end,
           'power_page', case when s.value->>'power_page' ~ '^https://(www\.)?facebook\.com/[A-Za-z0-9.]+/?$' then s.value->>'power_page' else 'https://www.facebook.com/socoteco2.EC/' end)
    into v_sources from (select 1) o left join public.app_settings s on s.key = 'notice_sources';

  -- weather: the weather-proxy cache, only while it is under 60 minutes old; an allow-list of display fields.
  select s.value, s.updated_at into c, c_at from public.app_settings s where s.key = 'weather_proxy_cache';
  if c is not null and c_at > now() - interval '60 minutes' then
    v_wx := jsonb_build_object(
      'source', case c->>'source' when 'pirate_weather' then 'pirate' when 'google_weather' then 'google' when 'open_meteo' then 'open-meteo' else null end,
      'fetched_at', to_char(c_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'temp_c', c#>'{current,temp}',
      'condition', c#>'{current,description}',
      'code', c->'code',
      'rain_chance_pct', c#>'{current,rain_prob}',
      'aqi', c->'aqi',
      'hourly', coalesce((
        select jsonb_agg(jsonb_build_object('time', h.e->'time', 'rain_chance_pct', h.e->'rain_chance_pct', 'mm', h.e->'mm', 'code', h.e->'code') order by h.n)
          from (select e, n from jsonb_array_elements(case when jsonb_typeof(c->'hourly') = 'array' then c->'hourly' else '[]'::jsonb end) with ordinality as t(e, n)
                 order by n limit 12) h), '[]'::jsonb),
      'rain_watch', case when jsonb_typeof(c->'rain_watch') = 'object'
                         then jsonb_build_object('from', c#>'{rain_watch,from}', 'to', c#>'{rain_watch,to}', 'peak_pct', c#>'{rain_watch,peak_pct}') end);
  end if;

  -- notices: active and upcoming, brownout is shown as power. Title and detail are redacted free text.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id,
           'type', case n.notice_type when 'brownout' then 'power' when 'water' then 'water' when 'deep_clean' then 'deep_clean' else 'note' end,
           'title', public.staff_redact_v1(n.title),
           'date', n.effective_date,
           'start_time', to_char(n.effective_time, 'HH24:MI'),
           'end_time', case when n.effective_time is not null and n.duration_hours is not null
                            then to_char(n.effective_time + n.duration_hours * interval '1 hour', 'HH24:MI') end,
           'duration_hours', n.duration_hours,
           'source', case when n.source = 'socoteco' then 'socoteco' when n.source = 'gscwd' then 'gscwd' when n.source = 'system' then 'system'
                          when n.source = 'ngcp' then 'system' when n.source in ('staff', 'manual') then 'manual'
                          when n.notice_type = 'brownout' then 'socoteco' else 'manual' end,
           'detail', public.staff_redact_v1(nullif(btrim(regexp_replace(n.description, '(^|\s*\|\s*)poster\s+\S+\s*$', '')), ''))
         ) order by n.effective_date, n.effective_time nulls first, n.created_at), '[]'::jsonb)
    into v_notices
    from public.ops_notices n
   where n.property_id = v_pid and n.is_active
     and coalesce(n.audience, 'staff') in ('staff', 'all')
     and (n.expires_at is null or n.expires_at > now())
     -- not ended yet: a timed notice ends at start + duration (Manila clock), any other at the end of its date. `date` stays the start date.
     and case when n.effective_time is not null and n.duration_hours is not null
              then n.effective_date::timestamp + n.effective_time + n.duration_hours * interval '1 hour'
              else n.effective_date::timestamp + interval '1 day' end >= v_now_local
     and n.effective_date <= v_today + 30;

  -- house items and the inbox count: owner and admin only. A cleaner gets [] and null.
  if v_priv then
    -- verifier_findings.detail is free-form jsonb (it can name guests or amounts), so a finding shows its redacted title only.
    select coalesce(jsonb_agg(u.item order by u.rank, u.sort_title), '[]'::jsonb) into v_house from (
      select x.* from (
        select 0 rank, f.title sort_title, jsonb_build_object('kind', 'finding', 'id', f.key,
                 'title', public.staff_redact_v1(f.title), 'detail', null) item
          from public.verifier_findings f where f.status in ('open', 'acknowledged')
        union all
        select 1, i.name, jsonb_build_object('kind', 'low_stock', 'id', i.id::text,
                 'title', public.staff_redact_v1('Low stock: ' || i.name),
                 'detail', 'Down to ' || trim(trailing '.' from trim(trailing '0' from i.qty_on_hand::numeric(12,2)::text))
                           || ', reorder below ' || trim(trailing '.' from trim(trailing '0' from i.reorder_below::numeric(12,2)::text)))
          from public.inventory_items i
         where i.property_id = v_pid and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below) x
      order by x.rank, x.sort_title limit 20) u;
    select count(*)::int into v_inbox from public.concierge_handoffs h where h.status = 'open';
  else
    v_house := '[]'::jsonb;
    v_inbox := null;
  end if;

  return jsonb_build_object(
    'generated_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'role', v_role,
    'house_times', v_times,
    'sources', v_sources,
    'weather', v_wx,
    'notices', v_notices,
    'house', v_house,
    'inbox_open', v_inbox);
end $$;
revoke all on function public.notices_v1(uuid) from public, anon;
grant execute on function public.notices_v1(uuid) to authenticated, service_role;

drop function if exists public.s_arrival_ready_v1(uuid, text);
drop function if exists public.s_pay_price_v1(text, date);
drop function if exists public.s_pay_day_v1(date, date, timestamptz);

drop table if exists public.cleaning_progress;
alter table public.staff_pay_requests drop column if exists created_by_user_id;
alter table public.ops_notices drop column if exists source_url;

commit;
