-- 20261026000000_s91_kpi_fixes.sql
-- Session 91, lane kpi-sql: release s91_kpi_20261026, part 1 (the numbers the admin and Telegram show). docs/s91/KPI-AUDIT.md F1, F2, F3, F6, F7, F10.
--   F1  admin_stays_v1      the Airbnb branch skips the mirror rows (source 'direct', confirmation_code 'DIRECT:' || inquiry id) that canonical_booking_decision and
--                           inquiry_one_tap write for every confirmed direct stay; the direct branch already counts the stay, so it was counted twice.
--   F2  admin_stays_v1      a stay with split payout rows in airbnb_transactions (one per payout) took max() of gross_earnings and cleaning_fee; it now takes sum().
--   F7  admin_stays_v1      booking_created falls back to the reservation's created_at (Manila date) when the transaction export has no booking_date.
--   F3  get_finance_summary Airbnb mirror rows (source airbnb, airbnb_email) are not income that was received: they are out of income, categories and the pending count,
--                           the same rule hospitality metrics and the ledger position already use. net = income - expenses - drawings. New key: drawings.
--   F6  get_missed_cleanings "today" is the Manila date (it was current_date, which is UTC and one day short from 00:00 to 08:00 Manila).
--   F10 inventory_purchases.units_per_purchase integer -> numeric(10,4) (inventory_items already holds numeric(10,4), so a pack of 0.5 or 2.5 was truncated);
--       record_inventory_receipt_v1 drops its ::integer cast. Existing rows keep their values (all whole numbers).
-- Each replaced body is a copy of the LIVE body (read 2026-10-16, CR stripped) with exactly the edits above. Guards (55000, nothing changes) name the live md5.
-- Rollback: supabase/rollbacks/20261026_s91_kpi.sql.

begin;

do $$
declare
  v_expect constant text[][] := array[
    ['public.admin_stays_v1(uuid)',                                                            '939ea3b0d2c97399866378906132374c'],
    ['public.get_finance_summary(date,uuid)',                                                  '6a73bb978d02457c2d7457427686b16c'],
    ['public.get_missed_cleanings(uuid,integer)',                                              'e68e3365b31a48dc85f9eb46926ebf81'],
    ['public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)', '1dc0fe9cbe738b4b91b57e7a9201a239']];
  v_got text; i integer;
begin
  for i in 1 .. array_length(v_expect, 1) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(v_expect[i][1]);
    if v_got is distinct from v_expect[i][2] then
      raise exception 's91 kpi fixes: % is not the body this release was cut from (md5 %)', v_expect[i][1], v_got using errcode = '55000';
    end if;
  end loop;
  if (select format_type(a.atttypid, a.atttypmod) from pg_attribute a where a.attrelid = 'public.inventory_purchases'::regclass and a.attname = 'units_per_purchase' and not a.attisdropped) is distinct from 'integer' then
    raise exception 's91 kpi fixes: inventory_purchases.units_per_purchase is not integer' using errcode = '55000';
  end if;
end $$;

-- F10
alter table public.inventory_purchases alter column units_per_purchase type numeric(10,4);

-- F1, F2, F7
create or replace function public.admin_stays_v1(p_property_id uuid)
returns table(stay_kind text, stay_id uuid, code text, guest_id uuid, guest_name text, checkin date, checkout date, nights integer, status text, accommodation_total numeric, allocation_method text, booking_created date, payout_date date, host_payout numeric)
language sql stable security definer set search_path = '' as $body$
  select s.* from (
  select 'airbnb', r.id, r.confirmation_code, r.guest_id, r.guest_name, r.checkin_date, r.checkout_date,
         (r.checkout_date - r.checkin_date), r.status,
         case
           when t.gross_earnings is not null then round(t.gross_earnings - coalesce(t.cleaning_fee, 0), 2)
           when r.host_payout is not null then round(r.host_payout + coalesce(r.host_service_fee, 0), 2)
           else null end,
         case
           when t.gross_earnings is not null then 'airbnb_transactions_gross_less_cleaning'
           when r.host_payout is not null then 'host_payout_plus_host_fee'
           else 'missing' end,
         coalesce(t.booking_date, (r.created_at at time zone 'Asia/Manila')::date), r.payout_date, r.host_payout
  from public.airbnb_reservations r
  left join lateral (
    select sum(x.gross_earnings) gross_earnings, sum(x.cleaning_fee) cleaning_fee, min(x.booking_date) booking_date
    from public.airbnb_transactions x
    where x.property_id = r.property_id and x.confirmation_code = r.confirmation_code and x.row_type = 'reservation'
  ) t on true
  where r.property_id = p_property_id and r.checkin_date is not null and r.checkout_date is not null
    and r.source is distinct from 'direct'
  union all
  select 'direct', i.id, 'DIR-' || upper(left(i.id::text, 8)), i.guest_id, i.guest_name, i.checkin_date, i.checkout_date,
         (i.checkout_date - i.checkin_date),
         case when i.status in ('confirmed','completed') then i.status when i.status in ('cancelled','declined') then 'cancelled' else 'inquiry' end,
         i.total_amount, case when i.total_amount is not null then 'direct_quoted_total' else 'missing' end,
         i.submitted_at::date, null, null
  from public.booking_inquiries i
  where i.property_id = p_property_id
  ) s
  where public.admin_stays_gate_v1(p_property_id);
$body$;

-- F3
create or replace function public.get_finance_summary(p_month date default ((now() at time zone 'Asia/Manila'::text))::date, p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language sql stable set search_path = '' as $body$
  with bounds as (
    select date_trunc('month', p_month)::date as m_start,
           (date_trunc('month', p_month) + interval '1 month')::date as m_next
  ),
  scoped as (
    select t.txn_type, t.category, t.gross_amount
    from public.transactions t, bounds b
    where t.property_id = p_property_id
      and t.status = 'confirmed'
      and t.source not in ('airbnb', 'airbnb_email')
      and t.transaction_date >= b.m_start
      and t.transaction_date <  b.m_next
  ),
  totals as (
    select
      coalesce(sum(gross_amount) filter (where txn_type = 'income'),  0) as income,
      coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) as expenses,
      coalesce(sum(gross_amount) filter (where txn_type = 'drawing'), 0) as drawings
    from scoped
  ),
  by_cat as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'category', x.category,
             'label',    coalesce(ec.label, initcap(replace(x.category,'_',' '))),
             'txn_type', x.txn_type,
             'total',    x.total,
             'count',    x.cnt
           ) order by x.total desc), '[]'::jsonb) as rows
    from (
      select txn_type, category, sum(gross_amount) as total, count(*) as cnt
      from scoped group by txn_type, category
    ) x
    left join public.expense_categories ec
      on ec.slug = x.category and ec.property_id = p_property_id
  ),
  pending as (
    select count(*) as cnt
    from public.transactions t, bounds b
    where t.property_id = p_property_id
      and t.status = 'pending_review'
      and t.source not in ('airbnb', 'airbnb_email')
      and t.transaction_date >= b.m_start
      and t.transaction_date <  b.m_next
  )
  select jsonb_build_object(
    'month',          to_char((select m_start from bounds), 'YYYY-MM'),
    'property_id',    p_property_id,
    'currency',       'PHP',
    'income',         (select income   from totals),
    'expenses',       (select expenses from totals),
    'drawings',       (select drawings from totals),
    'net',            (select income - expenses - drawings from totals),
    'by_category',    (select rows from by_cat),
    'pending_review', (select cnt from pending)
  );
$body$;

-- F6
create or replace function public.get_missed_cleanings(p_property_id uuid default null::uuid, p_lookback integer default 14)
returns table(guest_name text, checkin_date date, checkout_date date, source text, days_overdue integer)
language plpgsql stable set search_path = '' as $body$
declare
  v_prop_id uuid;
  v_today   date;
begin
  -- s91 F6: "today" is the Manila date. current_date is UTC, one day short from 00:00 to 08:00 Manila when this is called interactively.
  v_today   := public.manila_today();
  v_prop_id := coalesce(p_property_id, (select id from public.properties limit 1));

  return query
  select
    nullif(trim(coalesce(ce.guest_name, '')), '') as guest_name,
    ce.checkin_date,
    ce.checkout_date,
    ce.source,
    (v_today - ce.checkout_date)::integer as days_overdue
  from public.calendar_events ce
  where ce.property_id = v_prop_id
    and ce.status <> 'cancelled'
    and ce.checkout_date <  v_today
    and ce.checkout_date >= v_today - p_lookback
    and not exists (
      select 1
      from public.cleaning_sessions cs
      where cs.property_id = v_prop_id
        and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
        and (
          cs.checkout_date = ce.checkout_date
          -- filed a day late but clearly for this stay
          or cs.cleaned_at::date between ce.checkout_date and ce.checkout_date + 1
        )
    )
    -- D-290: the same guest checks in again on this checkout date, so nobody cleans
    and not exists (
      select 1
      from public.calendar_events nx
      where ce.status = 'confirmed'
        and nx.property_id = ce.property_id
        and nx.status = 'confirmed'
        and nx.checkin_date = ce.checkout_date
        and nx.id <> ce.id
        and public.stay_same_guest_v1(ce.id, nx.id)
    )
  order by ce.checkout_date desc;
end;
$body$;

-- F10: the one change is the dropped ::integer on units_per_purchase in the purchase insert (live s89 body otherwise)
create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $body$
declare i public.inventory_items%rowtype; v_units numeric; v_pid uuid; v_mid uuid; v_existing public.inventory_purchases%rowtype; v_sh_status text; v_sid uuid; v_sname text;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', i.property_id);
  if p_packs is null or p_packs <= 0 then raise exception using errcode = '22023', message = 'packs must be positive'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  select * into v_existing from public.inventory_purchases p where p.notes like '%[key:' || p_idempotency_key || ']%' limit 1;
  if found then return jsonb_build_object('ok', true, 'replayed', true, 'purchaseId', v_existing.id); end if;
  -- S84: a shopping row that is no longer approved (already received, cancelled, ...) adds no stock; checked after the replay above and before anything is written
  if p_shopping_list_id is not null then
    select s.status into v_sh_status from public.inventory_shopping_list s where s.id = p_shopping_list_id and s.property_id = i.property_id for update;
    if not found or v_sh_status <> 'approved' then
      return jsonb_build_object('ok', false, 'reason', case v_sh_status when 'received' then 'already_received' else 'not_open' end);
    end if;
  end if;
  -- S86: the supplier is the picked id (same property), else an exact name or alias match of the printed name; the text column keeps the name
  if p_supplier_id is not null then
    select s.id, s.name into v_sid, v_sname from public.inventory_suppliers s where s.id = p_supplier_id and s.property_id = i.property_id;
  end if;
  if v_sid is null then
    v_sid := public.s_inventory_supplier_resolve_v1(i.property_id, p_supplier);
    if v_sid is not null then select s.name into v_sname from public.inventory_suppliers s where s.id = v_sid; end if;
  end if;
  -- Purchase packs convert to base units once, here (INV06).
  v_units := round(p_packs * coalesce(i.units_per_purchase, 1), 2);
  insert into public.inventory_purchases(item_id, purchased_at, qty, unit_cost, supplier, supplier_id, notes, receipt_path, purchase_unit, units_per_purchase)
  values (p_item_id, coalesce(p_purchased_at, current_date), v_units, case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(i.units_per_purchase, 0), 1), 4) end, coalesce(v_sname, p_supplier), v_sid, 'Admin receipt [key:' || p_idempotency_key || ']', p_receipt_path, i.purchase_unit, coalesce(i.units_per_purchase, 1))
  returning id into v_pid;
  if i.movement_controlled_at is not null then
    v_mid := public.inventory_apply_event_v1(p_item_id, 'receipt', v_units, 'Receipt of ' || p_packs::text || ' ' || coalesce(i.purchase_unit, 'pack') || coalesce(' from ' || coalesce(v_sname, p_supplier), ''), 'inventory_purchases', v_pid::text);
  else
    update public.inventory_items set qty_on_hand = coalesce(qty_on_hand, 0) + v_units, unit_cost = coalesce(case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(units_per_purchase, 0), 1), 4) end, unit_cost) where id = p_item_id;
  end if;
  if p_shopping_list_id is not null then
    update public.inventory_shopping_list set status = 'received', received_by = auth.uid(), received_at = now(), received_quantity = v_units, unit_cost = p_unit_cost, supplier = coalesce(v_sname, p_supplier), supplier_id = v_sid, movement_id = v_mid, purchase_id = v_pid, version = version + 1, updated_at = now()
    where id = p_shopping_list_id and property_id = i.property_id and status = 'approved';
  end if;
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);
end;
$body$;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) to authenticated;

commit;
