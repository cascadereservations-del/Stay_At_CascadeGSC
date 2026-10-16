-- Compensating rollback for release s89_backlog_20261024 (session 89).
-- Part 1 (payout QR): puts save_staff_details_v1 back to the s85 body it replaced (md5 of prosrc, CR stripped, 1f528a60b24632ecf6cead5b47b38903),
--   then drops qrph_crc16_v1 and staff_payout_change_notices. DATA LOSS (by design): queued payout-change notices not yet sent.
-- Part 2 (inventory price precision): puts inventory_purchases.unit_cost and inventory_items.unit_cost back to numeric(10,2). Prices with more than two
--   decimals ROUND to two (PHP 8.3333 becomes 8.33). total_cost is re-added with the same generated expression, price_history_by_item is recreated with
--   its grants, and record_inventory_receipt_v1 gets back its s86 body (md5 c05c174f9d8861813c0a14ad78735195).
-- Roll the Staff and admin apps back first only if they send QR text with a bad CRC (the readable 22023 would otherwise be missing, nothing more).
-- Apply with run-sql-on-host.sh.

begin;

-- part 1
create or replace function public.save_staff_details_v1(p_user_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_row public.staff_details%rowtype; v_label text;
begin
  if not public.current_staff_authorized('manage_staff') then
    raise exception using errcode = '42501', message = 'manage_staff denied';
  end if;
  if not exists (select 1 from public.staff_access_profiles where user_id = p_user_id) then
    raise exception using errcode = 'P0002', message = 'staff member not found';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  -- s85: payout fields. Same gate as every other field (manage_staff = owner and admin only; finance and cleaner are refused above).
  if p_patch ? 'payout_bank_label' then
    if jsonb_typeof(p_patch->'payout_bank_label') not in ('string', 'null') then raise exception using errcode = '22023', message = 'bank label must be text'; end if;
    v_label := nullif(btrim(p_patch->>'payout_bank_label'), '');
    if v_label is not null and char_length(v_label) not between 2 and 40 then raise exception using errcode = '22023', message = 'bank label must be 2 to 40 characters'; end if;
  end if;
  if p_patch ? 'payout_qrph' and jsonb_typeof(p_patch->'payout_qrph') <> 'null' then
    if jsonb_typeof(p_patch->'payout_qrph') <> 'string' or btrim(p_patch->>'payout_qrph') not like '000201%' or char_length(btrim(p_patch->>'payout_qrph')) > 512 then
      raise exception using errcode = '22023', message = 'QR code text must be a QR Ph payload (starts 000201, at most 512 characters)';
    end if;
  end if;
  insert into public.staff_details(user_id) values (p_user_id) on conflict (user_id) do nothing;
  select * into v_row from public.staff_details where user_id = p_user_id for update;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'stale version: staff details changed since they were loaded';
  end if;
  v_before := (to_jsonb(v_row) - 'payout_qrph') || jsonb_build_object('payout_qrph', case when v_row.payout_qrph is null then null else '[set ' || right(v_row.payout_qrph, 4) || ']' end);
  update public.staff_details set
    contact_number = case when p_patch ? 'contact_number' then nullif(btrim(p_patch->>'contact_number'), '') else contact_number end,
    alternate_contact = case when p_patch ? 'alternate_contact' then nullif(btrim(p_patch->>'alternate_contact'), '') else alternate_contact end,
    address = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else address end,
    id_type = case when p_patch ? 'id_type' then nullif(p_patch->>'id_type', '') else id_type end,
    id_number = case when p_patch ? 'id_number' then nullif(btrim(p_patch->>'id_number'), '') else id_number end,
    id_drive_url = case when p_patch ? 'id_drive_url' then nullif(btrim(p_patch->>'id_drive_url'), '') else id_drive_url end,
    emergency_contact_name = case when p_patch ? 'emergency_contact_name' then nullif(btrim(p_patch->>'emergency_contact_name'), '') else emergency_contact_name end,
    emergency_contact_number = case when p_patch ? 'emergency_contact_number' then nullif(btrim(p_patch->>'emergency_contact_number'), '') else emergency_contact_number end,
    start_date = case when p_patch ? 'start_date' then nullif(p_patch->>'start_date', '')::date else start_date end,
    fee_turnover = case when p_patch ? 'fee_turnover' then nullif(p_patch->>'fee_turnover', '')::numeric else fee_turnover end,
    fee_transport = case when p_patch ? 'fee_transport' then nullif(p_patch->>'fee_transport', '')::numeric else fee_transport end,
    fee_deep_clean = case when p_patch ? 'fee_deep_clean' then nullif(p_patch->>'fee_deep_clean', '')::numeric else fee_deep_clean end,
    payout_qrph = case when p_patch ? 'payout_qrph' then nullif(btrim(p_patch->>'payout_qrph'), '') else payout_qrph end,
    payout_bank_label = case when p_patch ? 'payout_bank_label' then v_label else payout_bank_label end,
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where user_id = p_user_id returning * into v_row;
  insert into public.staff_details_history(user_id, changed_by, before_state, after_state, reason)
  values (p_user_id, auth.uid(), v_before,
          (to_jsonb(v_row) - 'payout_qrph') || jsonb_build_object('payout_qrph', case when v_row.payout_qrph is null then null else '[set ' || right(v_row.payout_qrph, 4) || ']' end),
          p_reason);
  return jsonb_build_object('ok', true, 'userId', p_user_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_staff_details_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_staff_details_v1(uuid, jsonb, integer, text) to authenticated;
drop function if exists public.qrph_crc16_v1(text);
drop table if exists public.staff_payout_change_notices;

-- part 2 (prices round to 2 dp; the view and the generated column go back as they were)
drop view public.price_history_by_item;
alter table public.inventory_purchases drop column total_cost;
alter table public.inventory_purchases alter column unit_cost type numeric(10,2);
alter table public.inventory_purchases add column total_cost numeric(10,2) generated always as (qty * unit_cost) stored;
alter table public.inventory_items alter column unit_cost type numeric(10,2);

create view public.price_history_by_item
with (security_invoker = true)
as
select
  p.item_id,
  i.name as item_name,
  p.supplier,
  p.unit_cost,
  p.purchased_at,
  row_number() over (
    partition by p.item_id
    order by p.purchased_at desc, p.created_at desc, p.id desc
  ) as recency_rank
from public.inventory_purchases p
join public.inventory_items i on i.id = p.item_id
where p.unit_cost is not null;

comment on view public.price_history_by_item is
  'Inventory purchase price history ranked newest-first per item.';
revoke all on public.price_history_by_item from public, anon, authenticated, service_role;
grant select on public.price_history_by_item to authenticated;
grant all on public.price_history_by_item to service_role;

-- record_inventory_receipt_v1 back to the s86 body
create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  values (p_item_id, coalesce(p_purchased_at, current_date), v_units, case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(i.units_per_purchase, 0), 1), 4) end, coalesce(v_sname, p_supplier), v_sid, 'Admin receipt [key:' || p_idempotency_key || ']', p_receipt_path, i.purchase_unit, coalesce(i.units_per_purchase, 1)::integer)
  returning id into v_pid;
  if i.movement_controlled_at is not null then
    v_mid := public.inventory_apply_event_v1(p_item_id, 'receipt', v_units, 'Receipt of ' || p_packs::text || ' ' || coalesce(i.purchase_unit, 'pack') || coalesce(' from ' || coalesce(v_sname, p_supplier), ''), 'inventory_purchases', v_pid::text);
  else
    update public.inventory_items set qty_on_hand = coalesce(qty_on_hand, 0) + v_units, unit_cost = coalesce(case when p_unit_cost is not null then round(p_unit_cost / coalesce(nullif(units_per_purchase, 0), 1), 2) end, unit_cost) where id = p_item_id;
  end if;
  if p_shopping_list_id is not null then
    update public.inventory_shopping_list set status = 'received', received_by = auth.uid(), received_at = now(), received_quantity = v_units, unit_cost = p_unit_cost, supplier = coalesce(v_sname, p_supplier), supplier_id = v_sid, movement_id = v_mid, purchase_id = v_pid, version = version + 1, updated_at = now()
    where id = p_shopping_list_id and property_id = i.property_id and status = 'approved';
  end if;
  return jsonb_build_object('ok', true, 'purchaseId', v_pid, 'movementId', v_mid, 'unitsAdded', v_units, 'controlled', i.movement_controlled_at is not null);
end;
$$;
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid) to authenticated;

commit;
