-- Rollback of s131_meter_cycle_20261130: puts the s127 bodies back (utility_billing_default_v1, utility_billing_cfg_v1, bill_schedule_cfg_v1, utility_bill_estimate_v1, today_bills_v1, bill_pay_settle_v1, bill_entry_v1, bill_daily_v1; md5s of the originals:
--   utility_billing_default_v1 93765639cafb84ce5860de301a5ba0af
--   utility_billing_cfg_v1 29c5cc443923797670a7b66f51c86781
--   utility_bill_estimate_v1 f821ade80aafe63d00dc51f8c5700bf4
--   today_bills_v1 70302291441c8493c622ae66befe6b79
--   bill_pay_settle_v1 df687957b354441f0874fac73a53ee9d
--   bill_schedule_cfg_v1 c8a259b8e8be8e2dd0b129e62bb8a68a
--   bill_entry_v1 9fe4d8c1b506de6eb80a93d11301bdca
--   bill_daily_v1 11146bc4e4577ed2e104ac119fb0b4a0
-- CR stripped), drops the four helpers this release adds, the reading_date / reading_value columns with their constraints and unique index, the open_from keys of utility_billing and the remind_day 25 this release stored.
-- Refuses (55000, nothing changes) once any bill carries a reading date or value: those are real bill data and would be lost; clear them by hand first (and move the paid meter bills' cycles back with the Staff app rolled back first).
-- Also refuses when a replaced function is neither this release's body nor the s127 body. Roll the Staff app back first: it sends reading_date. Grants restated as before this release.
-- remind_day: keys equal to 25 are removed (the s127 default, the pay day 27, applies again). A remind_day an owner set to some other number stays.
begin;

do $g$
declare v text; r record;
begin
  for r in select * from (values
    ('public.utility_billing_default_v1()', '93765639cafb84ce5860de301a5ba0af', 'a392b40c92122706aac8074ee8f490d3'),
    ('public.utility_billing_cfg_v1()', '29c5cc443923797670a7b66f51c86781', '20acb9bbe5965c08fa9b317aa9073636'),
    ('public.utility_bill_estimate_v1(uuid,date)', 'f821ade80aafe63d00dc51f8c5700bf4', '563e61f417555730a9294df15c7eca7f'),
    ('public.today_bills_v1(uuid)', '70302291441c8493c622ae66befe6b79', '7fca3fd12b7e372010f8f20b12c491a4'),
    ('public.bill_pay_settle_v1(uuid,jsonb)', 'df687957b354441f0874fac73a53ee9d', 'ede3c0432079186f73b7db56900e6671'),
    ('public.bill_schedule_cfg_v1()', 'c8a259b8e8be8e2dd0b129e62bb8a68a', '14293a6c2efbc387a8d97240321ca839'),
    ('public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)', '9fe4d8c1b506de6eb80a93d11301bdca', '64e749cf8ed30afc9c4475bcd398685a'),
    ('public.bill_daily_v1(date,uuid)', '11146bc4e4577ed2e104ac119fb0b4a0', '91a6d8a62fafd25894310e522de23494')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 'rollback s131: ' || r.sig || ' is neither this release nor the s127 body (md5 ' || coalesce(v, 'null') || ')';
    end if;
  end loop;
  if exists (select 1 from public.utility_bills where reading_date is not null or reading_value is not null) then
    raise exception using errcode = '55000', message = 'rollback s131: a bill carries a reading date or value; clear or archive those by hand first';
  end if;
end $g$;

-- the s127 bodies
create or replace function public.utility_billing_default_v1()
returns jsonb language sql immutable set search_path = '' as $$
  select '{"electric":{"cycle_day":21,"fixed_php":5.60},"water":{"cycle_day":21,"min_php":212,"min_m3":10,"tiers":[{"upto":20,"php":23.05},{"upto":30,"php":26.65},{"upto":40,"php":30.50},{"upto":null,"php":34.50}],"source_url":"https://gensanwater.gov.ph/water-rates/"}}'::jsonb;
$$;

create or replace function public.utility_billing_cfg_v1()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'electric', jsonb_build_object(
      'cycle_day', case when jsonb_typeof(s.v #> '{electric,cycle_day}') = 'number' then to_jsonb(least(31, greatest(1, trunc((s.v #> '{electric,cycle_day}')::numeric)))) else d.v #> '{electric,cycle_day}' end,
      'fixed_php', public.utility_cfg_num_v1(s.v #> '{electric,fixed_php}', d.v #> '{electric,fixed_php}')),
    'water', jsonb_build_object(
      'cycle_day', case when jsonb_typeof(s.v #> '{water,cycle_day}') = 'number' then to_jsonb(least(31, greatest(1, trunc((s.v #> '{water,cycle_day}')::numeric)))) else d.v #> '{water,cycle_day}' end,
      'min_php', public.utility_cfg_num_v1(s.v #> '{water,min_php}', d.v #> '{water,min_php}'),
      'min_m3', public.utility_cfg_num_v1(s.v #> '{water,min_m3}', d.v #> '{water,min_m3}'),
      'tiers', case when case when jsonb_typeof(s.v #> '{water,tiers}') = 'array'
                              then jsonb_array_length(s.v #> '{water,tiers}') > 0
                                   and not exists (select 1 from jsonb_array_elements(s.v #> '{water,tiers}') e
                                                    where case when jsonb_typeof(e) <> 'object' then true
                                                               when jsonb_typeof(e -> 'php') is distinct from 'number' then true
                                                               when (e -> 'php')::numeric < 0 then true
                                                               when coalesce(jsonb_typeof(e -> 'upto'), 'null') not in ('number', 'null') then true
                                                               else false end)
                              else false end
                    then s.v #> '{water,tiers}' else d.v #> '{water,tiers}' end,
      'source_url', case when jsonb_typeof(s.v #> '{water,source_url}') = 'string' then s.v #> '{water,source_url}' else d.v #> '{water,source_url}' end))
    from (select public.utility_billing_default_v1() v) d,
         (select coalesce((select a.value from public.app_settings a where a.key = 'utility_billing' and jsonb_typeof(a.value) = 'object'), '{}'::jsonb) v) s;
$$;

create or replace function public.bill_schedule_cfg_v1()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reading_day', public.bill_cfg_day_v1(s.v -> 'reading_day', 21), 'pay_day', to_jsonb(s.pd),
    'bills', jsonb_build_object(
      'electric', public.bill_cfg_one_v1(s.v #> '{bills,electric}', 'Electricity (SOCOTECO II)', null, s.pd),
      'water',    public.bill_cfg_one_v1(s.v #> '{bills,water}', 'Water (Gensan Water District)', null, s.pd),
      'internet', public.bill_cfg_one_v1(s.v #> '{bills,internet}', 'Internet', public.utility_cfg_num_v1(s.v #> '{bills,internet,amount}', to_jsonb(1500)), s.pd),
      'netflix',  public.bill_cfg_one_v1(s.v #> '{bills,netflix}', 'Netflix', public.utility_cfg_num_v1(s.v #> '{bills,netflix,amount}', to_jsonb(449)), s.pd)))
    from (select a.v, (public.bill_cfg_day_v1(a.v -> 'pay_day', 27) #>> '{}')::integer pd
            from (select coalesce((select x.value from public.app_settings x where x.key = 'bill_schedule' and jsonb_typeof(x.value) = 'object'), '{}'::jsonb) v) a) s;
$$;

create or replace function public.utility_bill_estimate_v1(p_property_id uuid, p_on date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.utility_billing_cfg_v1();
  v_ec date[] := public.utility_cycle_v1(p_on, (v_cfg -> 'electric' ->> 'cycle_day')::integer);
  v_wc date[] := public.utility_cycle_v1(p_on, (v_cfg -> 'water' ->> 'cycle_day')::integer);
  v_fixed numeric := (v_cfg -> 'electric' ->> 'fixed_php')::numeric;
  v_kwh numeric; v_elast date; v_eat timestamptz; v_ed integer; v_edc integer := v_ec[2] - v_ec[1]; v_rate numeric;
  v_fk numeric; v_pdk numeric;
  v_m3 numeric; v_wlast date; v_wd integer; v_wdc integer := v_wc[2] - v_wc[1]; v_fm numeric; v_pdm numeric; v_next jsonb;
begin
  select coalesce(sum(u.kwh), 0), max(u.d) into v_kwh, v_elast from public.utility_daily_use_v1(p_property_id, v_ec[1] + 1, v_ec[2]) u;
  select m.recorded_at into v_eat
    from public.meter_chain_v1(p_property_id) m where m.chain_ok and m.cd > v_ec[1] and m.cd <= v_ec[2]
   order by m.cd desc, m.recorded_at desc, m.id desc limit 1;
  v_ed := coalesce(v_elast - v_ec[1], 0);
  -- the billed month is the month the cycle ends in; no rate for it yet = the latest earlier rate, null only while no rate exists at all (rates dated after today are never read)
  select r.php_per_kwh into v_rate from public.utility_rate_by_month_v1() r where r.rate_month <= date_trunc('month', v_ec[2])::date order by r.rate_month desc limit 1;
  if v_ed > 0 then v_pdk := v_kwh / v_ed; v_fk := v_pdk * v_edc; end if;

  select coalesce(sum(u.m3), 0), max(u.d) into v_m3, v_wlast from public.utility_daily_use_v1(p_property_id, v_wc[1] + 1, v_wc[2]) u;
  v_wd := coalesce(v_wlast - v_wc[1], 0);
  if v_wd > 0 then v_pdm := v_m3 / v_wd; v_fm := v_pdm * v_wdc; end if;
  v_next := public.utility_water_next_v1(v_m3, v_cfg);

  return jsonb_build_object(
    'electric', jsonb_build_object(
      'cycle_from', v_ec[1], 'cycle_to', v_ec[2], 'days', v_ed, 'days_in_cycle', v_edc, 'kwh', round(v_kwh, 2), 'rate', v_rate, 'fixed_php', v_fixed,
      'so_far_php', case when v_rate is not null then round(v_kwh * v_rate + v_fixed, 2) end,
      'forecast_kwh', case when v_ed > 0 then round(v_fk, 2) end,
      'forecast_php', case when v_ed > 0 and v_rate is not null then round(v_fk * v_rate + v_fixed, 2) end,
      'per_day_kwh', case when v_ed > 0 then round(v_pdk, 2) end,
      'per_day_php', case when v_ed > 0 and v_rate is not null then round(v_pdk * v_rate, 2) end,
      'last_reading_at', v_eat),
    'water', jsonb_build_object(
      'cycle_from', v_wc[1], 'cycle_to', v_wc[2], 'days', v_wd, 'm3', round(v_m3, 2),
      'so_far_php', public.utility_water_php_v1(v_m3, v_cfg),
      'forecast_m3', case when v_wd > 0 then round(v_fm, 2) end,
      'forecast_php', case when v_wd > 0 then public.utility_water_php_v1(v_fm, v_cfg) end,
      'per_day_m3', case when v_wd > 0 then round(v_pdm, 2) end,
      'min_php', (v_cfg -> 'water' ->> 'min_php')::numeric, 'min_m3', (v_cfg -> 'water' ->> 'min_m3')::numeric,
      'next_php', v_next -> 'php', 'next_upto', v_next -> 'upto'));
end;
$$;

create or replace function public.today_bills_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_cfg jsonb; v_ok boolean; v_uid uuid := auth.uid();
begin
  if v_uid is null or p_property_id is null or not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not authorized';
  end if;
  v := public.utility_bill_estimate_v1(p_property_id, public.manila_today());
  v_cfg := public.bill_schedule_cfg_v1();
  v_ok := public.current_staff_authorized('approve_payment', p_property_id);
  return jsonb_build_object(
    'since', (v -> 'electric' ->> 'cycle_from')::date,
    'last_reading_at', v -> 'electric' -> 'last_reading_at',
    'electric', jsonb_build_object('php', v -> 'electric' -> 'so_far_php', 'kwh', v -> 'electric' -> 'kwh'),
    'water', jsonb_build_object('php', v -> 'water' -> 'so_far_php', 'm3', v -> 'water' -> 'm3'),
    'due', coalesce((select jsonb_agg(public.bill_entry_v1(b, v_cfg, v_ok, v_uid)
                                      order by (b.status = 'paid'), b.period, array_position(array['electric', 'water', 'internet', 'netflix'], b.kind))
                       from public.utility_bills b where b.property_id = p_property_id
                        and (b.status in ('due', 'paying') or (b.status = 'paid' and b.period = to_char(public.manila_today(), 'YYYY-MM')))), '[]'::jsonb));
end;
$$;

create or replace function public.bill_pay_settle_v1(p_bill_id uuid, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_cfg jsonb; v_res jsonb;
  v_path text; v_client_sha text; v_sha text; v_prefix text;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found or v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_cfg := public.bill_schedule_cfg_v1();
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_payer', 'name', v_b.paying_by_name); end if;

  if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;
  v_path := btrim(coalesce(p_proof ->> 'path', ''));
  v_client_sha := lower(coalesce(p_proof ->> 'sha256', ''));
  v_prefix := v_b.property_id::text || '/' || v_uid::text || '/';
  if (v_client_sha <> '' and v_client_sha !~ '^[0-9a-f]{64}$') or char_length(v_path) not between 40 and 300
     or left(v_path, length(v_prefix)) <> v_prefix or position('..' in v_path) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_proof');
  end if;
  -- stored proof: the object exists in the private bucket and upload-photo recorded the hash of the bytes it stored
  select h.sha256 into v_sha from public.staff_upload_hashes h where h.path = v_path;
  if v_sha is null or not exists (select 1 from storage.objects o where o.bucket_id = 'cleaning-photos' and o.name = v_path) then
    return jsonb_build_object('ok', false, 'reason', 'no_stored_proof');
  end if;
  if v_client_sha <> '' and v_client_sha <> v_sha then return jsonb_build_object('ok', false, 'reason', 'sha_mismatch'); end if;

  v_res := public.bill_step_v1(v_b.id, 'paid', v_uid, public.bill_actor_name_v1(v_uid),
    jsonb_build_object('file_unique_id', 'web:' || v_path, 'file_id', v_path, 'path', v_path, 'sha256', v_sha, 'amount', p_proof -> 'amount', 'verdict', 'read',
                       'confirmed', coalesce(p_proof -> 'confirmed' = 'true'::jsonb, false), 'read', jsonb_build_object('source', 'staff_app', 'typed_by', v_uid)));
  if v_res ->> 'reason' = 'confirm_amount' then v_res := v_res || jsonb_build_object('estimate_php', v_b.estimate_php); end if;
  return public.bill_reply_v1(v_res, v_b.id);
end $$;

create or replace function public.bill_entry_v1(b public.utility_bills, p_cfg jsonb, p_approve boolean, p_uid uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', b.id, 'kind', b.kind, 'label', p_cfg -> 'bills' -> b.kind ->> 'label', 'period', b.period, 'status', b.status,
    'estimate_php', b.estimate_php, 'paid_php', b.paid_php, 'is_estimate', b.kind in ('electric', 'water'),
    'due_day', (p_cfg -> 'bills' -> b.kind ->> 'remind_day')::integer,
    'paying_by_name', case when b.status = 'paying' then b.paying_by_name end,
    'paid_by_name', case when b.status = 'paid' then b.paid_by_name end, 'paid_at', b.paid_at,
    'can_pay', coalesce(p_approve, false) and (b.status = 'due' or (b.status = 'paying' and b.paying_by is not distinct from p_uid)));
$$;

create or replace function public.bill_daily_v1(p_on date default null, p_property_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_floor constant text := '2026-11'; -- the release month: October 2026 and earlier stay closed
  v_today date := coalesce(p_on, public.manila_today());
  v_cfg jsonb := public.bill_schedule_cfg_v1();
  v_read integer := (v_cfg ->> 'reading_day')::integer;
  v_prop uuid; v_res jsonb; v_bill jsonb; v_nid uuid; v_title text; v_opened integer := 0; v_notices integer := 0; v_po integer; v_pn integer;
begin
  for v_prop in select p.id from public.properties p where p.is_active and (p_property_id is null or p.id = p_property_id) order by p.id loop
    begin
      v_po := 0; v_pn := 0;
      if extract(day from v_today)::integer = v_read then
        v_title := 'Meter reading due today (' || to_char(make_date(2001, 1, v_read), 'FMDDth') || ')';
        if not exists (select 1 from public.ops_notices n where n.property_id = v_prop and n.notice_type = 'reminder' and n.source = 'system' and n.effective_date = v_today and n.title = v_title) then
          insert into public.ops_notices(property_id, notice_type, title, description, effective_date, source, audience)
          values (v_prop, 'reminder', v_title, 'Read the electricity and water meters.', v_today, 'system', 'staff');
          v_pn := v_pn + 1;
        end if;
      end if;

      v_res := public.bill_due_open_v1(v_prop, v_today, c_floor);
      for v_bill in select e from jsonb_array_elements(v_res -> 'new') e loop
        v_po := v_po + 1;
        v_title := case when (v_bill ->> 'period') < to_char(v_today, 'YYYY-MM') then (v_bill ->> 'label') || ' is overdue.'
                        else (v_bill ->> 'label') || ' is due by the ' || to_char(make_date(2001, 1, (v_bill ->> 'remind_day')::integer), 'FMDDth') || '.' end;
        insert into public.ops_notices(property_id, notice_type, title, description, effective_date, source, audience)
        values (v_prop, 'reminder', v_title, 'See To pay on Today.', v_today, 'system', 'staff') returning id into v_nid;
        update public.utility_bills set notice_id = v_nid where id = (v_bill ->> 'id')::uuid;
        v_pn := v_pn + 1;
      end loop;

      -- an unpaid bill stays on Today: its one notice is dated today (notices_v1 ends a notice at the end of its date)
      update public.ops_notices n set effective_date = v_today
       where n.is_active and n.effective_date < v_today
         and n.id in (select b.notice_id from public.utility_bills b where b.property_id = v_prop and b.status in ('due', 'paying') and b.notice_id is not null);
      v_opened := v_opened + v_po; v_notices := v_notices + v_pn;
    exception when others then
      raise warning 'bill_daily_v1: property % skipped (sqlstate %)', v_prop, sqlstate;
    end;
  end loop;
  return jsonb_build_object('on', v_today, 'bills_opened', v_opened, 'notices_written', v_notices);
end $$;

revoke all on function public.bill_entry_v1(public.utility_bills, jsonb, boolean, uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_daily_v1(date, uuid) from public, anon, authenticated, service_role;
revoke all on function public.utility_billing_default_v1() from public, anon, authenticated, service_role;
revoke all on function public.utility_billing_cfg_v1() from public, anon, authenticated, service_role;
revoke all on function public.bill_schedule_cfg_v1() from public, anon, authenticated, service_role;
revoke all on function public.utility_bill_estimate_v1(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.today_bills_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.today_bills_v1(uuid) to authenticated;
revoke all on function public.bill_pay_settle_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.bill_pay_settle_v1(uuid, jsonb) to authenticated;

comment on function public.utility_bill_estimate_v1(uuid, date) is 's127: internal. The cycle (from, to] that contains p_on: so far, forecast and per day for electricity (rate of the month the cycle ends in plus the fixed charge) and water (tiered tariff, never below the minimum). Counted readings = meter_chain_v1.';
comment on function public.today_bills_v1(uuid) is 's127: the electricity and water bill so far for the Today tab plus the bills to pay (due): every unpaid bill and this month''s paid ones, each as {id, kind, label, period, status, estimate_php, paid_php, is_estimate, due_day, paying_by_name, paid_by_name, paid_at, can_pay}. Every active staff role of the property (read_operations); anyone else 42501. Money by design (Lloyd 2026-11-20); no account number.';
comment on function public.bill_pay_settle_v1(uuid, jsonb) is 's127 bills: approve_payment. p_proof {path, sha256, amount, confirmed}; one expense row. Refusals: not_authorized, not_found, already_paid, not_payer, bad_proof, no_stored_proof, sha_mismatch, duplicate_proof, bad_amount, confirm_amount.';

-- the new helpers (nothing else uses them once the bodies above are back)
drop function if exists public.utility_reading_warn_v1(uuid, text, date, numeric);
drop function if exists public.utility_meter_from_v1(uuid, text, date, jsonb);
drop function if exists public.utility_cfg_date_v1(jsonb, jsonb);
drop function if exists public.utility_safe_date_v1(text);

-- columns, constraints, index
drop index if exists public.utility_bills_reading_date_uq;
alter table public.utility_bills drop constraint if exists utility_bills_reading_meter_only;
alter table public.utility_bills drop constraint if exists utility_bills_reading_value_check;
alter table public.utility_bills drop column if exists reading_date, drop column if exists reading_value;

-- settings
update public.app_settings set value = value #- '{electric,open_from}' #- '{water,open_from}', updated_at = now() where key = 'utility_billing' and jsonb_typeof(value) = 'object';
do $s$
declare k text;
begin
  foreach k in array array['electric', 'water', 'internet', 'netflix'] loop
    update public.app_settings a set value = a.value #- array['bills', k, 'remind_day'], updated_at = now()
     where a.key = 'bill_schedule' and jsonb_typeof(a.value) = 'object' and jsonb_typeof(a.value #> array['bills', k]) = 'object' and a.value #> array['bills', k, 'remind_day'] = '25'::jsonb;
  end loop;
end $s$;

-- check
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'utility_bills' and column_name in ('reading_date', 'reading_value')) then raise exception 'rollback s131: reading columns still there'; end if;
  if md5(replace((select prosrc from pg_proc where oid = 'public.today_bills_v1(uuid)'::regprocedure), chr(13), '')) <> '70302291441c8493c622ae66befe6b79' then raise exception 'rollback s131: today_bills_v1 is not the s127 body'; end if;
  if md5(replace((select prosrc from pg_proc where oid = 'public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)'::regprocedure), chr(13), '')) <> '9fe4d8c1b506de6eb80a93d11301bdca'
     or md5(replace((select prosrc from pg_proc where oid = 'public.bill_daily_v1(date,uuid)'::regprocedure), chr(13), '')) <> '11146bc4e4577ed2e104ac119fb0b4a0' then raise exception 'rollback s131: bill_entry_v1 or bill_daily_v1 is not the s127 body'; end if;
end $$;

commit;
