-- Session 110, lane B (SQL): release s110_kpi_supply_laundry_20261112. D-358 (KPI tab, laundry role, receipt auto-log), D-359 (rate feeder), D-306, D-330, D-334.
--   1. Role `laundry` and capability `report_supply`: the role check, staff_access_allowed (newest body: 20260913130000_admin_access_simplification.sql), manage_staff_access
--      (20260828000400, patched from the LIVE body: only the role list changes) and record_inventory_usage (20261007112000, patched from the LIVE body: only the gate changes,
--      submit_cleaning OR report_supply).
--   2. public.utility_rates + utility_rate_set_v1 (owner/admin) + utility_rate_record_auto_v1 (service_role, power-watch) + utility_rate_list_v1 (read_finance).
--   3. public.inventory_receipt_drafts + inventory_receipt_draft_v1 / _confirm_v1 / _undo_v1 / _cancel_v1 and the internal s_inventory_receipt_apply_v1 (purchase row + stock, one path).
--   4. kpi_tab_v1: the KPI tab read model (finance keys only with read_finance; the `admin` key is ABSENT otherwise).
-- Read models that branch on role: every one branches owner/admin (privileged) vs everyone else (the cleaner payload), or on read_operations, so laundry already behaves like cleaner there
-- with no edit: staff_home_v1 and calendar (20261025000000_s91_actions.sql, v_priv = owner/admin), notices_v1 (20261014000000_s81_notices.sql), tasks_list_v1 (20261006110000_d301_pay_rates_tasks.sql,
-- manage_operations vs read_operations), the signin team split (20261022000000_s89_signin_pin.sql: not owner/admin/finance = staff). Nothing was touched there. calendar_block_triage
-- (20261005140000: owner/admin/cleaner only) is a cleaning action and is left as it is on purpose.
-- Nothing existing is dropped; the staff_access_profiles role check is replaced by a wider one. The data deletes in the function bodies (undo of a staff receipt, 30-day trim of unconfirmed
-- drafts) are why the phase is `backfill`, as in s107/s108; applying the migration deletes no row.
begin;

-- 1a. the role check ----------------------------------------------------------------------------------------------------------------------------------------
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.staff_access_profiles'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%cleaner%' and pg_get_constraintdef(oid) like '%role%' loop
    execute format('alter table public.staff_access_profiles drop constraint %I', c.conname);
  end loop;
  alter table public.staff_access_profiles add constraint staff_access_profiles_role_check
    check (role in ('owner','admin','finance','inspector','cleaner','maintenance','laundry'));
end $$;

-- 1b. staff_access_allowed: newest body 20260913130000 with report_supply and laundry added ------------------------------------------------------------------
create or replace function public.staff_access_allowed(
  p_role text,p_action text,p_disabled_at timestamptz,p_aal text
) returns boolean language sql immutable set search_path='' as $$
  select case
    when p_disabled_at is not null then false
    when p_role in ('owner','admin') then p_action in (
      'manage_staff','approve_payment','read_finance','read_operations','manage_operations',
      'inspect_cleaning','submit_cleaning','manage_inventory','manage_maintenance',
      'manage_privacy','manage_booking','approve_refund','publish_rate_policy','manage_guest_inbox','report_supply'
    )
    when p_role='finance' then p_action in ('approve_payment','read_finance','read_operations','approve_refund')
    when p_role='inspector' then p_action in ('read_operations','inspect_cleaning','submit_cleaning','report_supply')
    when p_role='cleaner' then p_action in ('read_operations','submit_cleaning','report_supply')
    when p_role='laundry' then p_action in ('read_operations','report_supply')
    when p_role='maintenance' then p_action in ('read_operations','manage_maintenance')
    else false end;
$$;
comment on function public.staff_access_allowed(text,text,timestamptz,text) is
  'Role/action matrix for named staff. p_aal is ignored since D-094 (2026-09-13). s110: report_supply (owner, admin, inspector, cleaner, laundry); laundry = read_operations + report_supply only.';
revoke all on function public.staff_access_allowed(text,text,timestamptz,text) from public, anon, authenticated, service_role;
grant execute on function public.staff_access_allowed(text,text,timestamptz,text) to service_role;

-- 1c. patches of two LIVE bodies (pg_get_functiondef, one replace each, refuses when the anchor is not found exactly once) ---------------------------------------
do $$
declare v_def text; v_new text; v_old text; v_to text;
begin
  -- manage_staff_access: the role list of the upsert
  v_def := pg_get_functiondef(to_regprocedure('public.manage_staff_access(uuid,text,text,uuid[],text)'));
  v_old := $a$p_role not in ('owner','admin','finance','inspector','cleaner','maintenance')$a$;
  v_to  := $a$p_role not in ('owner','admin','finance','inspector','cleaner','maintenance','laundry')$a$;
  if v_def is null or (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 's110: manage_staff_access role list anchor not found exactly once; re-cut from the live body' using errcode = '55000';
  end if;
  execute replace(v_def, v_old, v_to);

  -- record_inventory_usage: submit_cleaning OR report_supply
  v_def := pg_get_functiondef(to_regprocedure('public.record_inventory_usage(uuid,date,text,text,jsonb)'));
  v_old := $a$if not public.current_staff_authorized('submit_cleaning', p_property_id) then$a$;
  v_to  := $a$if not (public.current_staff_authorized('submit_cleaning', p_property_id) or public.current_staff_authorized('report_supply', p_property_id)) then$a$;
  if v_def is null or (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 's110: record_inventory_usage gate anchor not found exactly once; re-cut from the live body' using errcode = '55000';
  end if;
  execute replace(v_def, v_old, v_to);
end $$;
-- manage_staff_access keeps the grants it has live (create or replace does not change them)
revoke all on function public.record_inventory_usage(uuid, date, text, text, jsonb) from public, anon;
grant execute on function public.record_inventory_usage(uuid, date, text, text, jsonb) to authenticated, service_role;

-- 2. utility rates --------------------------------------------------------------------------------------------------------------------------------------
create table public.utility_rates (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'socoteco2' check (provider in ('socoteco2')),
  php_per_kwh numeric(8,4) not null check (php_per_kwh > 0 and php_per_kwh < 100),
  effective_from date not null,
  source text not null check (source in ('auto','manual')),
  source_url text check (source_url is null or char_length(source_url) <= 500),
  noted text check (noted is null or char_length(noted) <= 200),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint utility_rates_unique unique (provider, effective_from, php_per_kwh)
);
alter table public.utility_rates enable row level security;
revoke all on table public.utility_rates from public, anon, authenticated, service_role;
comment on table public.utility_rates is 'S110: electricity rate per kWh by effective date. No client grants: read through kpi_tab_v1 / utility_rate_list_v1 (money), written by utility_rate_set_v1 (owner/admin) and utility_rate_record_auto_v1 (power-watch, service_role).';

create or replace function public.utility_rate_set_v1(p_php_per_kwh numeric, p_effective_from date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not exists (select 1 from public.properties x where public.current_staff_authorized('manage_operations', x.id)) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_php_per_kwh is null or p_php_per_kwh <= 0 or p_php_per_kwh >= 100 or p_php_per_kwh <> round(p_php_per_kwh, 4)
     or p_effective_from is null or p_effective_from > public.manila_today() + 31 or p_effective_from < date '2020-01-01'
     or (v_note is not null and char_length(v_note) > 200) then
    return jsonb_build_object('ok', false, 'error', 'invalid_rate');
  end if;
  insert into public.utility_rates(provider, php_per_kwh, effective_from, source, noted, created_by)
  values ('socoteco2', p_php_per_kwh, p_effective_from, 'manual', v_note, auth.uid())
  on conflict (provider, effective_from, php_per_kwh) do nothing
  returning id into v_id;
  if v_id is null then
    select r.id into v_id from public.utility_rates r where r.provider = 'socoteco2' and r.effective_from = p_effective_from and r.php_per_kwh = p_php_per_kwh;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.utility_rate_record_auto_v1(p_php_per_kwh numeric, p_effective_from date, p_source_url text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception using errcode = '42501', message = 'service role only'; end if;
  if p_php_per_kwh is null or p_php_per_kwh <= 0 or p_php_per_kwh >= 100 or p_effective_from is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_rate');
  end if;
  insert into public.utility_rates(provider, php_per_kwh, effective_from, source, source_url)
  values ('socoteco2', round(p_php_per_kwh, 4), p_effective_from, 'auto', left(nullif(btrim(coalesce(p_source_url, '')), ''), 500))
  on conflict (provider, effective_from, php_per_kwh) do nothing
  returning id into v_id;
  if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'inserted', true); end if;
  select r.id into v_id from public.utility_rates r where r.provider = 'socoteco2' and r.effective_from = p_effective_from and r.php_per_kwh = round(p_php_per_kwh, 4);
  return jsonb_build_object('ok', true, 'id', v_id, 'inserted', false);
end;
$$;

create or replace function public.utility_rate_list_v1(p_property_id uuid, p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.current_staff_authorized('read_finance', p_property_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  return jsonb_build_object('ok', true, 'rates', coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'php_per_kwh', r.php_per_kwh, 'effective_from', r.effective_from, 'source', r.source,
                                       'source_url', r.source_url, 'note', r.noted, 'created_at', r.created_at)
                     order by r.effective_from desc, r.created_at desc)
      from (select * from public.utility_rates x order by x.effective_from desc, x.created_at desc limit greatest(1, least(coalesce(p_limit, 20), 100))) r), '[]'::jsonb));
end;
$$;

-- the ocr-receipt matcher reads item option names (revoked from service_role since s106); title is the real column, no price
grant select (item_id, title) on public.inventory_item_options to service_role;

-- 3. receipt drafts -------------------------------------------------------------------------------------------------------------------------------------
create table public.inventory_receipt_drafts (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null,
  receipt_path text,
  vendor text check (vendor is null or char_length(vendor) <= 200),
  purchased_on date,
  total numeric(12,2) check (total is null or (total >= 0 and total < 100000000)),
  lines jsonb not null default '[]'::jsonb check (jsonb_typeof(lines) = 'array' and jsonb_array_length(lines) <= 100),
  status text not null default 'draft' check (status in ('draft','confirmed','cancelled')),
  confirmed_at timestamptz,
  purchase_ids uuid[],
  transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  confirm_key text check (confirm_key is null or char_length(confirm_key) between 16 and 160),
  confirm_result jsonb,
  unit_cost_before jsonb
);
create index inventory_receipt_drafts_prop_status_idx on public.inventory_receipt_drafts (property_id, status, created_at);
create index inventory_receipt_drafts_creator_idx on public.inventory_receipt_drafts (created_by);
alter table public.inventory_receipt_drafts enable row level security;
revoke all on table public.inventory_receipt_drafts from public, anon, authenticated, service_role;
-- the ocr-receipt edge function inserts the draft with the service client (and reads it back); nothing else, and nothing for anon / authenticated
grant select, insert on table public.inventory_receipt_drafts to service_role;
comment on table public.inventory_receipt_drafts is 'S110: a staff receipt photo read by ocr-receipt (service role) and waiting for the person to confirm. lines/total hold the prices server-side only: staff reads go through inventory_receipt_draft_v1, which hides them without read_finance.';

-- internal: one purchase row plus the stock, the same two writes record_inventory_receipt_v1 makes (20261026000000_s91_kpi_fixes.sql), without its manage_inventory gate.
-- p_units are base units, p_cost is PHP per base unit. A movement-controlled item gets the same 'receipt' movement s_inventory_purchase_movement_v1 writes.
create or replace function public.s_inventory_receipt_apply_v1(p_item_id uuid, p_units numeric, p_cost numeric, p_vendor text, p_supplier_id uuid, p_date date, p_path text, p_draft_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; m public.inventory_stock_movements%rowtype; v_pid uuid; v_after numeric;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  insert into public.inventory_purchases(item_id, purchased_at, qty, unit_cost, supplier, supplier_id, notes, receipt_path, purchase_unit, units_per_purchase)
  values (p_item_id, p_date, p_units, p_cost, p_vendor, p_supplier_id, 'Staff receipt [key:' || p_draft_id::text || ']', p_path, i.purchase_unit, coalesce(i.units_per_purchase, 1))
  returning id into v_pid;
  if i.movement_controlled_at is not null then
    select * into m from public.inventory_stock_movements where item_id = i.id order by sequence_no desc limit 1;
    if not found or m.quantity_after is distinct from i.qty_on_hand or m.property_id is distinct from i.property_id then
      raise exception using errcode = '22023', message = 'stock reconciliation required for ' || i.name;
    end if;
    v_after := i.qty_on_hand + p_units;
    insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
    values (i.id, i.property_id, 'receipt', i.qty_on_hand, v_after, 'Staff receipt ' || to_char(p_date, 'YYYY-MM-DD') || coalesce(' from ' || p_vendor, ''), auth.uid(),
            left('evt-' || encode(extensions.digest('inventory_purchases|' || v_pid::text || '|' || i.id::text || '|receipt', 'sha256'), 'hex'), 80));
    update public.inventory_items set qty_on_hand = v_after where id = i.id;
  else
    -- the cost before the FIRST line of this receipt for the item, so an undo can put it back
    update public.inventory_receipt_drafts set unit_cost_before = coalesce(unit_cost_before, '{}'::jsonb) || case when coalesce(unit_cost_before, '{}'::jsonb) ? i.id::text then '{}'::jsonb
      else jsonb_build_object(i.id::text, i.unit_cost) end where id = p_draft_id;
    update public.inventory_items set qty_on_hand = coalesce(qty_on_hand, 0) + p_units, unit_cost = coalesce(p_cost, unit_cost) where id = i.id;
  end if;
  return v_pid;
end;
$$;

create or replace function public.inventory_receipt_draft_v1(p_draft_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare d public.inventory_receipt_drafts%rowtype; v_fin boolean; v_lines jsonb;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select * into d from public.inventory_receipt_drafts where id = p_draft_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if not (public.current_staff_authorized('report_supply', d.property_id)
          and (d.created_by = auth.uid() or public.current_staff_authorized('manage_inventory', d.property_id))) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  v_fin := public.current_staff_authorized('read_finance', d.property_id);
  select coalesce(jsonb_agg(
           jsonb_build_object('line_no', (l.value ->> 'line_no')::integer, 'description', case when v_fin then l.value ->> 'description'
                                                else nullif(btrim(regexp_replace(regexp_replace(l.value ->> 'description', '(\u20b1|\m(PHP|P)\.?)\s*[0-9][0-9,]*(\.[0-9]+)?', '', 'gi'), '\s[0-9][0-9,]*\.[0-9]{1,2}\M', '', 'g')), '') end, 'qty', l.value -> 'qty',
                              'match', case when it.id is null then null
                                            else jsonb_build_object('item_id', it.id, 'name', it.name, 'unit', it.unit, 'photo_path', it.photo_path) end)
           || case when v_fin then jsonb_build_object('unit_cost', l.value -> 'unit_cost') else '{}'::jsonb end
           order by (l.value ->> 'line_no')::integer), '[]'::jsonb)
    into v_lines
    from jsonb_array_elements(d.lines) l
    left join public.inventory_items it on it.id = nullif(l.value ->> 'match_item_id', '')::uuid and it.property_id = d.property_id;
  return jsonb_build_object('ok', true, 'draft',
    jsonb_build_object('id', d.id, 'vendor', d.vendor, 'purchased_on', d.purchased_on, 'receipt_path', d.receipt_path, 'status', d.status, 'lines', v_lines)
    || case when v_fin then jsonb_build_object('total', d.total) else '{}'::jsonb end);
end;
$$;

-- internal core of inventory_receipt_confirm_v1 and inventory_receipt_manual_v1 (p_manual: no finance transaction, no prices)
create or replace function public.s_inventory_receipt_confirm_core_v1(p_draft_id uuid, p_lines jsonb, p_purchased_on date, p_idempotency_key text, p_manual boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d public.inventory_receipt_drafts%rowtype; v_uid uuid := auth.uid(); v_today date := public.manila_today();
  e jsonb; v_no integer; v_seen integer[] := '{}'; v_keep jsonb := '[]'::jsonb; v_ni jsonb; v_item uuid; v_qty numeric; v_dl jsonb; v_cost numeric;
  v_name text; v_cat text; v_unit text; v_cons boolean; v_sort integer; v_total numeric; v_date date; v_sid uuid; v_pid uuid; v_pids uuid[] := '{}';
  v_new jsonb := '[]'::jsonb; v_txn uuid; v_res jsonb; v_vendor text; v_bad boolean;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select * into d from public.inventory_receipt_drafts where id = p_draft_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if not (public.current_staff_authorized('report_supply', d.property_id)
          and (d.created_by = v_uid or public.current_staff_authorized('manage_inventory', d.property_id))) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if p_idempotency_key is not null and char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters';
  end if;
  -- the same confirm sent again (a retry after a lost answer) gets the first answer, never a second record
  if d.status = 'confirmed' and p_idempotency_key is not null and d.confirm_key = p_idempotency_key then
    return d.confirm_result || jsonb_build_object('replayed', true, 'draft_id', d.id);
  end if;
  if d.status <> 'draft' then return jsonb_build_object('ok', false, 'error', 'not_draft'); end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) not between 1 and 100 then
    return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', null);
  end if;
  v_date := coalesce(p_purchased_on, d.purchased_on, v_today);
  if v_date > v_today or v_date < v_today - 365 then
    if p_purchased_on is not null then raise exception using errcode = '22023', message = 'purchase date out of range'; end if;
    v_date := v_today;   -- a date the photo read badly falls back to today
  end if;

  -- 1. validate every line before anything is written
  for e in select value from jsonb_array_elements(p_lines) loop
    if jsonb_typeof(e) <> 'object' or coalesce(e ->> 'line_no', '') !~ '^[0-9]{1,6}$' then
      return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', null);
    end if;
    v_no := (e ->> 'line_no')::integer;
    if v_no = any (v_seen) or not exists (select 1 from jsonb_array_elements(d.lines) l where l.value ->> 'line_no' = v_no::text)
       or coalesce(e ->> 'skip', 'false') not in ('true', 'false') then
      return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', v_no);
    end if;
    v_seen := v_seen || v_no;
    if coalesce(e ->> 'skip', 'false') = 'true' then continue; end if;
    v_ni := e -> 'new_item';
    v_bad := case when coalesce(e ->> 'qty_units', '') ~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' then (e ->> 'qty_units')::numeric <= 0 else true end
             or (coalesce(e ->> 'item_id', '') <> '') = (v_ni is not null and jsonb_typeof(v_ni) = 'object');
    if v_bad then
      return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', v_no);
    end if;
    if coalesce(e ->> 'item_id', '') <> '' then
      v_bad := case when e ->> 'item_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                    then not exists (select 1 from public.inventory_items i where i.id = (e ->> 'item_id')::uuid and i.property_id = d.property_id and i.is_active)
                    else true end;
      if v_bad then
        return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', v_no);
      end if;
    else
      if char_length(btrim(coalesce(v_ni ->> 'name', ''))) not between 2 and 80 or char_length(btrim(coalesce(v_ni ->> 'category', ''))) not between 1 and 60
         or char_length(btrim(coalesce(nullif(v_ni ->> 'unit', ''), 'pc'))) not between 1 and 20
         or coalesce(v_ni ->> 'is_consumable', 'true') not in ('true', 'false') then
        return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', v_no);
      end if;
    end if;
    v_keep := v_keep || jsonb_build_array(e);
  end loop;
  if jsonb_array_length(v_keep) = 0 then return jsonb_build_object('ok', false, 'error', 'no_lines'); end if;

  -- 2. stock: one purchase row per kept line (items created first when the line names a new one)
  v_vendor := nullif(btrim(coalesce(d.vendor, '')), '');
  v_sid := public.s_inventory_supplier_resolve_v1(d.property_id, v_vendor);
  for e in select value from jsonb_array_elements(v_keep) order by (value ->> 'line_no')::integer loop
    v_no := (e ->> 'line_no')::integer;
    v_qty := (e ->> 'qty_units')::numeric;
    if coalesce(e ->> 'item_id', '') <> '' then
      v_item := (e ->> 'item_id')::uuid;
    else
      v_ni := e -> 'new_item';
      v_name := btrim(v_ni ->> 'name'); v_cat := btrim(v_ni ->> 'category'); v_unit := btrim(coalesce(nullif(v_ni ->> 'unit', ''), 'pc'));
      v_cons := coalesce((v_ni ->> 'is_consumable')::boolean, true);
      perform pg_advisory_xact_lock(hashtextextended('s84-item-create:' || d.property_id::text || ':' || lower(v_name), 0));
      select i.id into v_item from public.inventory_items i where i.property_id = d.property_id and i.is_active and lower(btrim(i.name)) = lower(v_name) limit 1;
      if v_item is null then
        select coalesce(max(i.sort_order), 0) + 1 into v_sort from public.inventory_items i where i.property_id = d.property_id;
        insert into public.inventory_items(property_id, name, category, unit, qty_on_hand, is_consumable, is_active, sort_order)
        values (d.property_id, v_name, v_cat, v_unit, 0, v_cons, true, v_sort) returning id into v_item;
        v_new := v_new || jsonb_build_array(jsonb_build_object('line_no', v_no, 'item_id', v_item));
      end if;
    end if;
    -- PHP per base unit = what the receipt line cost / the units the person confirmed (null when the receipt had no price for the line)
    select l.value into v_dl from jsonb_array_elements(d.lines) l where l.value ->> 'line_no' = v_no::text;
    v_cost := case when coalesce(v_dl ->> 'unit_cost', '') ~ '^[0-9]+(\.[0-9]+)?$'
                   then round(coalesce(nullif(v_dl ->> 'qty', '')::numeric, 1) * (v_dl ->> 'unit_cost')::numeric / v_qty, 4) end;
    v_pid := public.s_inventory_receipt_apply_v1(v_item, v_qty, v_cost, v_vendor, v_sid, v_date, d.receipt_path, d.id);
    v_pids := v_pids || v_pid;
  end loop;

  -- 3. ONE pending_review expense carrying the receipt path and the server-held total (never income)
  if not p_manual then
  v_total := coalesce(d.total, (select sum(coalesce(nullif(l.value ->> 'qty', '')::numeric, 1) * (l.value ->> 'unit_cost')::numeric)
                                  from jsonb_array_elements(d.lines) l where coalesce(l.value ->> 'unit_cost', '') ~ '^[0-9]+(\.[0-9]+)?$'), 0);
  insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, payee_name, receipt_image_path, logged_by, notes, ocr_raw)
  values (d.property_id, 'expense', 'supplies', 'pending_review', 'ocr', v_date, round(v_total, 2), v_vendor, d.receipt_path, 'staff app',
          'Supply receipt added by staff from the app', jsonb_build_object('draft_id', d.id, 'source', 'staff_supply_receipt'))
  returning id into v_txn;
  end if;

  -- 4. one plain notice for owner and admin (a Follow-ups task, D-218): what happened, who acts, no amount
  perform public.system_task_open_v1(d.property_id, 'receipt_review', d.id::text,
    case when p_manual then 'Staff supply added without a receipt' else 'Staff receipt to review' end || coalesce(': ' || left(public.staff_redact_v1(v_vendor), 80), ''),
    case when p_manual then 'Staff added ' || cardinality(v_pids) || ' supply item(s) by hand, with no receipt photo. Check the stock in Inventory.'
         else 'Staff added ' || cardinality(v_pids) || ' supply item(s) from a receipt. The expense waits in Finance as pending review; an owner or admin checks it.' end, 'normal');

  v_res := jsonb_build_object('ok', true, 'purchase_count', cardinality(v_pids), 'new_items', v_new, 'undo_token', d.id::text);
  if p_manual then v_res := v_res || jsonb_build_object('draft_id', d.id); end if;
  update public.inventory_receipt_drafts
     set status = 'confirmed', confirmed_at = now(), purchased_on = v_date, purchase_ids = v_pids, transaction_id = v_txn, confirm_key = p_idempotency_key, confirm_result = v_res
   where id = d.id;
  -- retention (ML-06): an unconfirmed or cancelled draft older than 30 days goes (its photo stays in storage)
  delete from public.inventory_receipt_drafts x where x.status in ('draft', 'cancelled') and x.created_at < now() - interval '30 days';
  return v_res;
end;
$$;

create or replace function public.inventory_receipt_confirm_v1(p_draft_id uuid, p_lines jsonb, p_purchased_on date default null, p_idempotency_key text default null)
returns jsonb language sql security definer set search_path = '' as $$
  select public.s_inventory_receipt_confirm_core_v1(p_draft_id, p_lines, p_purchased_on, p_idempotency_key, false);
$$;

-- Supply entered by hand, no receipt photo: a confirmed draft row with no receipt path and no prices, the same stock writes, NO finance transaction, the same owner/admin task.
-- The property is the caller's own (their property row first, else the Cascade property, else the lowest id) because the contract signature carries none.
create or replace function public.inventory_receipt_manual_v1(p_lines jsonb, p_purchased_on date default null, p_vendor text default null, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_prop uuid; v_id uuid; v_lines jsonb; v_conv jsonb; v_res jsonb; v_vendor text := nullif(btrim(coalesce(p_vendor, '')), ''); v_old public.inventory_receipt_drafts%rowtype;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select x.id into v_prop from public.properties x where public.current_staff_authorized('report_supply', x.id)
   order by exists (select 1 from public.staff_property_access a where a.user_id = v_uid and a.property_id = x.id) desc, (x.id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid) desc, x.id limit 1;
  if v_prop is null then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if p_idempotency_key is not null and char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters';
  end if;
  if v_vendor is not null and char_length(v_vendor) > 200 then raise exception using errcode = '22023', message = 'vendor is too long'; end if;
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('s110-manual:' || v_uid::text || ':' || p_idempotency_key, 0));
    select * into v_old from public.inventory_receipt_drafts d where d.created_by = v_uid and d.confirm_key = p_idempotency_key and d.status = 'confirmed' limit 1;
    if found then return v_old.confirm_result || jsonb_build_object('replayed', true, 'draft_id', v_old.id); end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) not between 1 and 100
     or exists (select 1 from jsonb_array_elements(p_lines) c where jsonb_typeof(c) <> 'object') then
    return jsonb_build_object('ok', false, 'error', 'bad_line', 'line_no', null);
  end if;
  select jsonb_agg(e.value || jsonb_build_object('line_no', e.ord) order by e.ord) into v_conv from jsonb_array_elements(p_lines) with ordinality e(value, ord);
  select jsonb_agg(jsonb_build_object('line_no', (c.value ->> 'line_no')::integer,
                   'description', left(coalesce(c.value -> 'new_item' ->> 'name', (select i.name from public.inventory_items i where i.id::text = c.value ->> 'item_id'), 'Supply'), 200),
                   'qty', c.value -> 'qty_units', 'unit_cost', null, 'match_item_id', null, 'match_score', 0) order by (c.value ->> 'line_no')::integer)
    into v_lines from jsonb_array_elements(v_conv) c;
  insert into public.inventory_receipt_drafts(property_id, created_by, receipt_path, vendor, purchased_on, total, lines, status)
  values (v_prop, v_uid, null, v_vendor, p_purchased_on, null, v_lines, 'draft') returning id into v_id;
  v_res := public.s_inventory_receipt_confirm_core_v1(v_id, v_conv, p_purchased_on, p_idempotency_key, true);
  if coalesce((v_res ->> 'ok')::boolean, false) is not true then
    update public.inventory_receipt_drafts set status = 'cancelled' where id = v_id;
  end if;
  return v_res;
end;
$$;

create or replace function public.inventory_receipt_undo_v1(p_draft_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d public.inventory_receipt_drafts%rowtype; v_uid uuid := auth.uid(); v_pid uuid; pu public.inventory_purchases%rowtype; i public.inventory_items%rowtype;
  m public.inventory_stock_movements%rowtype; v_status text; v_after numeric;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select * into d from public.inventory_receipt_drafts where id = p_draft_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if not (public.current_staff_authorized('manage_inventory', d.property_id)
          or (public.current_staff_authorized('report_supply', d.property_id) and d.created_by = v_uid and d.confirmed_at > now() - interval '24 hours')) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if d.status <> 'confirmed' then return jsonb_build_object('ok', false, 'error', 'not_confirmed'); end if;
  if d.transaction_id is not null then
    select t.status into v_status from public.transactions t where t.id = d.transaction_id for update;
    if v_status is not null and v_status not in ('pending_review', 'void') then return jsonb_build_object('ok', false, 'error', 'already_reviewed'); end if;
  end if;
  -- lock every item once, then check the SUMMED quantity per controlled item (a repeated item must not abort the undo) before any purchase is reversed
  perform 1 from public.inventory_items x where x.id in (select p.item_id from public.inventory_purchases p where p.id = any (coalesce(d.purchase_ids, '{}'::uuid[]))) order by x.id for update;
  if exists (select 1 from (select p.item_id, sum(p.qty) q from public.inventory_purchases p where p.id = any (coalesce(d.purchase_ids, '{}'::uuid[])) group by p.item_id) s
               join public.inventory_items it on it.id = s.item_id
              where it.movement_controlled_at is not null
                and (it.qty_on_hand < s.q or (select mm.quantity_after from public.inventory_stock_movements mm where mm.item_id = it.id order by mm.sequence_no desc limit 1) is distinct from it.qty_on_hand)) then
    return jsonb_build_object('ok', false, 'error', 'stock_moved');
  end if;
  foreach v_pid in array coalesce(d.purchase_ids, '{}'::uuid[]) loop
    select * into pu from public.inventory_purchases where id = v_pid;
    if not found then continue; end if;
    select * into i from public.inventory_items where id = pu.item_id for update;
    if i.movement_controlled_at is not null then
      v_after := i.qty_on_hand - pu.qty;
      insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
      values (i.id, i.property_id, 'adjustment', i.qty_on_hand, v_after, 'Undo of a staff receipt', v_uid, 'stk-undo-rcpt-' || replace(pu.id::text, '-', ''));
      update public.inventory_items set qty_on_hand = v_after where id = i.id;
    else
      update public.inventory_items set qty_on_hand = greatest(0, coalesce(qty_on_hand, 0) - pu.qty) where id = i.id;   -- legacy clamp, as record_inventory_usage
    end if;
    delete from public.inventory_purchases where id = pu.id;
  end loop;
  -- put back the unit cost the items had before this receipt (non-controlled items only: the receipt set it there)
  update public.inventory_items it set unit_cost = (d.unit_cost_before ->> it.id::text)::numeric
   where d.unit_cost_before is not null and d.unit_cost_before ? it.id::text and it.movement_controlled_at is null;
  if d.transaction_id is not null then
    update public.transactions set status = 'void' where id = d.transaction_id and status = 'pending_review';
  end if;
  update public.follow_up_tasks set status = 'done', completed_at = now(), completion_note = 'The staff receipt was undone.', updated_at = now(), version = version + 1
   where idempotency_key = 'system:receipt_review:' || d.id::text and status in ('open', 'in_progress');
  update public.inventory_receipt_drafts set status = 'cancelled', purchase_ids = null, transaction_id = null, unit_cost_before = null where id = d.id;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.inventory_receipt_cancel_v1(p_draft_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.inventory_receipt_drafts%rowtype;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select * into d from public.inventory_receipt_drafts where id = p_draft_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if not (public.current_staff_authorized('report_supply', d.property_id)
          and (d.created_by = auth.uid() or public.current_staff_authorized('manage_inventory', d.property_id))) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  if d.status = 'cancelled' then return jsonb_build_object('ok', true); end if;
  if d.status <> 'draft' then return jsonb_build_object('ok', false, 'error', 'not_draft'); end if;
  update public.inventory_receipt_drafts set status = 'cancelled' where id = d.id;
  delete from public.inventory_receipt_drafts x where x.status in ('draft', 'cancelled') and x.created_at < now() - interval '30 days';
  return jsonb_build_object('ok', true);
end;
$$;

-- 4. kpi_tab_v1 ------------------------------------------------------------------------------------------------------------------------------------------
-- Electricity: usable readings only (meter_flag not misread / re_entry / duplicate / estimate_pending, a non-negative electric_delta); kWh and nights are summed over the readings of the month
-- (recorded_at, Manila day) whose stay has nights > 0, so kwh_per_night = kwh_month / nights_month is exact. per_stay is the last 8 stays with a kwh_per_night, oldest first.
-- Inventory: turnovers are cleaning_sessions of type turnover / deep_clean cleaned in the month; usual = the same per-turnover figure over the last 90 days;
-- days_left = qty_on_hand / (units used in the last 30 days / 30). admin (read_finance only, absent otherwise): rate = newest utility_rates row effective today or earlier;
-- cleaning_pay_month = staff_pay_requests (requested, paying, paid) created in the month. Never booking income (D-306).
create or replace function public.kpi_tab_v1(p_property_id uuid, p_month date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := public.manila_today(); v_m0 date; v_m1 date; v_fin boolean;
  v_kwh numeric; v_nights numeric; v_last jsonb; v_per jsonb; v_bo jsonb; v_wc jsonb; v_inv jsonb; v_out jsonb;
  v_turn integer; v_turn90 integer; v_rate public.utility_rates%rowtype; v_lastd numeric; v_usage_cost numeric; v_ic jsonb;
  v_fs jsonb; v_hm jsonb; v_sold numeric; v_dn numeric; v_mcost numeric;
begin
  if auth.uid() is null or not public.current_staff_authorized('read_operations', p_property_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_m0 := date_trunc('month', coalesce(p_month, v_today))::date;
  v_m1 := (v_m0 + interval '1 month')::date;

  select coalesce(sum(mr.electric_delta), 0), coalesce(sum(cs.nights_stayed), 0) into v_kwh, v_nights
    from public.meter_readings mr join public.cleaning_sessions cs on cs.id = mr.session_id
   where mr.property_id = p_property_id and mr.electric_delta >= 0 and coalesce(cs.nights_stayed, 0) > 0
     and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
     and (mr.recorded_at at time zone 'Asia/Manila')::date >= v_m0 and (mr.recorded_at at time zone 'Asia/Manila')::date < v_m1;

  select jsonb_build_object('recorded_at', x.recorded_at, 'delta_kwh', x.electric_delta, 'nights', x.nights_stayed, 'kwh_per_night', x.kwh_per_night, 'flag', x.meter_flag)
    into v_last
    from (select mr.recorded_at, mr.electric_delta, cs.nights_stayed, mr.kwh_per_night, mr.meter_flag
            from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = p_property_id and mr.electric_delta is not null and mr.electric_delta >= 0
             and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
           order by mr.recorded_at desc, mr.id limit 1) x;
  v_lastd := (v_last ->> 'delta_kwh')::numeric;

  select coalesce(jsonb_agg(jsonb_build_object('checkout_date', y.checkout_date, 'kwh_per_night', y.kwh_per_night) order by y.sort_d, y.recorded_at), '[]'::jsonb) into v_per
    from (select cs.checkout_date, mr.kwh_per_night, mr.recorded_at, coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) sort_d
            from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
           where mr.property_id = p_property_id and mr.kwh_per_night is not null and mr.kwh_per_night >= 0
             and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
           order by coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) desc, mr.recorded_at desc limit 8) y;

  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_bo
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type = 'brownout' and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1;
  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_wc
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type = 'water' and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1;

  -- internet: the same rule as lib.js isInternetNotice (an internet word AND an outage word in the title or text of a note / maintenance notice)
  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_ic
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type in ('note', 'maintenance') and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1
     and lower(coalesce(n.title, '') || ' ' || coalesce(n.description, '')) ~ '\m(internet|wi-?fi|fiber|fibre|pldt|converge|globe at home|sky ?fiber|modem|router)\M'
     and lower(coalesce(n.title, '') || ' ' || coalesce(n.description, '')) ~ '\m(no|down|outage|interrupt\w*|offline|maintenance|repair\w*|cut|walang|wala|mawawala|disconnect\w*)\M';

  select count(*) into v_turn from public.cleaning_sessions cs
   where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')
     and (cs.cleaned_at at time zone 'Asia/Manila')::date >= v_m0 and (cs.cleaned_at at time zone 'Asia/Manila')::date < v_m1;
  select count(*) into v_turn90 from public.cleaning_sessions cs
   where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')
     and (cs.cleaned_at at time zone 'Asia/Manila')::date > v_today - 90;

  select jsonb_build_object(
    'low_now', (select count(*) from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below),
    'restocks_month', (select count(*) from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
                        where i.property_id = p_property_id and p.purchased_at >= v_m0 and p.purchased_at < v_m1),
    'turnovers_month', v_turn,
    'per_turnover', coalesce((
      select jsonb_agg(jsonb_build_object('item_id', t.id, 'name', t.name, 'used_per_turnover', case when v_turn > 0 then round(t.used / v_turn, 2) end,
                                          'usual', case when v_turn90 > 0 then round(t.used90 / v_turn90, 2) end) order by t.used desc, t.name)
        from (select * from (
                select i.id, i.name, sum(u.used_qty) filter (where u.session_date >= v_m0 and u.session_date < v_m1) used,
                       sum(u.used_qty) filter (where u.session_date > v_today - 90) used90
                  from public.inventory_items i join public.inventory_usage u on u.item_id = i.id
                 where i.property_id = p_property_id and i.is_active and i.is_consumable group by i.id, i.name) z
               where z.used > 0 order by z.used desc, z.name limit 6) t), '[]'::jsonb),
    'runs_out', coalesce((
      select jsonb_agg(jsonb_build_object('item_id', r.id, 'name', r.name, 'days_left', r.days_left) order by r.days_left, r.name)
        from (select i.id, i.name, floor(i.qty_on_hand / (sum(u.used_qty) / 30.0))::integer days_left
                from public.inventory_items i join public.inventory_usage u on u.item_id = i.id
               where i.property_id = p_property_id and i.is_active and i.is_consumable and i.qty_on_hand is not null and i.qty_on_hand >= 0
                 and u.session_date > v_today - 30
               group by i.id, i.name, i.qty_on_hand having sum(u.used_qty) > 0 order by days_left, i.name limit 3) r), '[]'::jsonb))
    into v_inv;

  v_out := jsonb_build_object('ok', true, 'month', v_m0,
    'utility', jsonb_build_object('kwh_month', round(v_kwh, 2), 'nights_month', v_nights, 'kwh_per_night', case when v_nights > 0 then round(v_kwh / v_nights, 2) end,
                                  'last_reading', v_last, 'per_stay', v_per, 'brownouts', v_bo, 'water_cuts', v_wc, 'internet_cuts', v_ic),
    'inventory', v_inv);

  if v_fin then
    select * into v_rate from public.utility_rates r where r.effective_from <= v_today
     order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1;
    -- each usable reading is costed at the rate in force on its own day (latest month first, a manual correction beats an auto read of the same month)
    select sum(mr.electric_delta * rt.php_per_kwh) into v_mcost
      from public.meter_readings mr join public.cleaning_sessions cs on cs.id = mr.session_id
      cross join lateral (select r.php_per_kwh from public.utility_rates r where r.effective_from <= (mr.recorded_at at time zone 'Asia/Manila')::date
                           order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1) rt
     where mr.property_id = p_property_id and mr.electric_delta >= 0 and coalesce(cs.nights_stayed, 0) > 0
       and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
       and (mr.recorded_at at time zone 'Asia/Manila')::date >= v_m0 and (mr.recorded_at at time zone 'Asia/Manila')::date < v_m1;
    select coalesce(sum(u.used_qty * coalesce(i.unit_cost, 0)), 0) into v_usage_cost
      from public.inventory_usage u join public.inventory_items i on i.id = u.item_id
     where i.property_id = p_property_id and u.session_date >= v_m0 and u.session_date < v_m1;
    v_fs := public.get_finance_summary(v_m0, p_property_id);
    v_hm := public.hospitality_metrics_core_v1(p_property_id, v_m0, v_m1, true) -> 'metrics';
    v_sold := (v_hm -> 'sold_nights' ->> 'value')::numeric;
    select coalesce(sum(greatest(0, least(i.checkout_date, v_m1) - greatest(i.checkin_date, v_m0))), 0) into v_dn
      from public.booking_inquiries i
     where i.property_id = p_property_id and i.status in ('confirmed', 'completed') and coalesce(i.guest_name, '') !~* '^synthetic';
    v_out := v_out || jsonb_build_object('admin', jsonb_build_object(
      'revenue_month', (v_fs ->> 'income')::numeric, 'costs_month', (v_fs ->> 'expenses')::numeric, 'net_month', (v_fs ->> 'net')::numeric,
      'occupancy', case when (v_hm -> 'occupancy' ->> 'value') is not null then round((v_hm -> 'occupancy' ->> 'value')::numeric / 100, 4) end,
      'adr', (v_hm -> 'adr' ->> 'value')::numeric, 'sold_nights', v_sold, 'sellable_nights', (v_hm -> 'capacity_nights' ->> 'value')::numeric,
      'direct_share', case when v_sold > 0 then least(1, round(v_dn / v_sold, 4)) end,
      'rate', case when v_rate.id is null then null else jsonb_build_object('php_per_kwh', v_rate.php_per_kwh, 'effective_from', v_rate.effective_from,
                                                                            'source', v_rate.source, 'source_url', v_rate.source_url) end,
      'last_reading_cost', case when v_rate.id is not null and v_lastd is not null then round(v_lastd * v_rate.php_per_kwh, 2) end,
      'month_kwh_cost', round(v_mcost, 2),
      'supplies_month', (select coalesce(sum(p.qty * p.unit_cost), 0) from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
                          where i.property_id = p_property_id and p.purchased_at >= v_m0 and p.purchased_at < v_m1),
      'supply_cost_per_turnover', case when v_turn > 0 then round(v_usage_cost / v_turn, 2) end,
      'cleaning_pay_month', (select coalesce(sum(q.total_amount), 0) from public.staff_pay_requests q
                              where q.property_id = p_property_id and q.status in ('requested', 'paying', 'paid')
                                and (q.created_at at time zone 'Asia/Manila')::date >= v_m0 and (q.created_at at time zone 'Asia/Manila')::date < v_m1)));
  end if;
  return v_out;
end;
$$;

-- 5. grants restated in full (ML-21) -----------------------------------------------------------------------------------------------------------------------
revoke all on function public.utility_rate_set_v1(numeric, date, text) from public, anon, authenticated, service_role;
revoke all on function public.utility_rate_record_auto_v1(numeric, date, text) from public, anon, authenticated, service_role;
revoke all on function public.utility_rate_list_v1(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.s_inventory_receipt_apply_v1(uuid, numeric, numeric, text, uuid, date, text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.inventory_receipt_draft_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.inventory_receipt_confirm_v1(uuid, jsonb, date, text) from public, anon, authenticated, service_role;
revoke all on function public.s_inventory_receipt_confirm_core_v1(uuid, jsonb, date, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.inventory_receipt_manual_v1(jsonb, date, text, text) from public, anon, authenticated, service_role;
revoke all on function public.inventory_receipt_undo_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.inventory_receipt_cancel_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kpi_tab_v1(uuid, date) from public, anon, authenticated, service_role;
grant execute on function public.utility_rate_set_v1(numeric, date, text) to authenticated;
grant execute on function public.utility_rate_record_auto_v1(numeric, date, text) to service_role;
grant execute on function public.utility_rate_list_v1(uuid, integer) to authenticated;
grant execute on function public.inventory_receipt_draft_v1(uuid) to authenticated;
grant execute on function public.inventory_receipt_confirm_v1(uuid, jsonb, date, text) to authenticated;
grant execute on function public.inventory_receipt_undo_v1(uuid) to authenticated;
grant execute on function public.inventory_receipt_manual_v1(jsonb, date, text, text) to authenticated;
grant execute on function public.inventory_receipt_cancel_v1(uuid) to authenticated;
grant execute on function public.kpi_tab_v1(uuid, date) to authenticated;

comment on function public.kpi_tab_v1(uuid, date) is 's110: the KPI tab. read_operations; the `admin` key (rate, costs, supplies, cleaning pay) exists only with read_finance. No booking income.';
comment on function public.inventory_receipt_confirm_v1(uuid, jsonb, date, text) is 's110: a staff member confirms a receipt draft: one purchase and stock write per kept line, one pending_review expense, one Follow-ups task for owner/admin. Idempotent on the draft id and key. report_supply; no price in the answer.';
comment on function public.inventory_receipt_undo_v1(uuid) is 's110: reverses the stock of a confirmed staff receipt and voids its pending expense. Owner/admin any time; the creator within 24 hours. Refuses when finance already reviewed the expense.';

commit;
