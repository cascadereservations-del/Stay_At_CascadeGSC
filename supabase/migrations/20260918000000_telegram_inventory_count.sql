-- Telegram inventory count (session 33, SPEC-03). /count in the Finance group lists a group of items,
-- takes a typed reply of only the lines that changed, shows a before/after card, and applies it when a
-- mapped owner or admin taps Apply. Authorisation happens at the tap, in the database, exactly like the
-- booking Confirm (telegram_finance_decide_booking_v1): a bot has no auth.uid(), so the tapper's Telegram
-- id is mapped to a staff profile here.
--
-- Why not reconcile_inventory_baseline_v1: it goes through admin_require('manage_inventory'), which needs
-- auth.uid(). Verified 2026-09-17. This writes qty_on_hand directly, the way apply_inventory_purchase
-- already does, and refuses any item that has become movement-controlled.
begin;

-- The pending-card kinds are a CHECK, so a new kind is a migration (B53). The twelve existing values are
-- copied from production (pg_constraint, 2026-09-18), not from an older migration.
alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count'
]));

create or replace function public.telegram_apply_inventory_count_v1(
  p_telegram_user_id bigint, p_rows jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p public.staff_access_profiles%rowtype;
  it public.inventory_items%rowtype;
  r jsonb;
  v_counted numeric;
  v_n int := 0;
  v_out jsonb := '[]'::jsonb;
begin
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  if not public.staff_access_allowed(p.role, 'manage_inventory', p.disabled_at, null) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;

  if jsonb_typeof(p_rows) is distinct from 'array' then return jsonb_build_object('ok', false, 'reason', 'bad_rows'); end if;
  if jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'bad_row_count');
  end if;
  -- One line per item, or a later line would silently overwrite an earlier one.
  if (select count(distinct e->>'item_id') from jsonb_array_elements(p_rows) e) <> jsonb_array_length(p_rows) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;

  -- PASS 1 validates and locks every row. A `return` inside pass 2 would keep the updates already made in
  -- this transaction, so nothing is written until the whole count is known to be good. The FOR UPDATE
  -- locks taken here are held to the end of the transaction, so pass 2 sees exactly these values.
  for r in select * from jsonb_array_elements(p_rows) loop
    if r->>'item_id' is null or r->>'counted' is null or r->>'expected_before' is null then
      return jsonb_build_object('ok', false, 'reason', 'bad_row');
    end if;
    v_counted := (r->>'counted')::numeric;
    if v_counted < 0 or v_counted <> round(v_counted, 2) then
      return jsonb_build_object('ok', false, 'reason', 'bad_count');
    end if;
    select * into it from public.inventory_items where id = (r->>'item_id')::uuid for update;
    if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found'); end if;
    -- ponytail: writes qty_on_hand directly like apply_inventory_purchase; when an item becomes
    -- movement-controlled it must route through the movement ledger instead, so refuse it here.
    if it.movement_controlled_at is not null then
      return jsonb_build_object('ok', false, 'reason', 'movement_controlled', 'item', it.name);
    end if;
    if not (p.role = 'owner' or exists (
      select 1 from public.staff_property_access s
       where s.user_id = p.user_id and s.property_id = it.property_id)) then
      return jsonb_build_object('ok', false, 'reason', 'not_authorized');
    end if;
    -- Someone logged a purchase or a cleaning since the list was shown: the whole count is stale.
    if it.qty_on_hand <> (r->>'expected_before')::numeric then
      return jsonb_build_object('ok', false, 'reason', 'stock_changed', 'item', it.name);
    end if;
  end loop;

  -- PASS 2 applies.
  for r in select * from jsonb_array_elements(p_rows) loop
    v_counted := (r->>'counted')::numeric;
    select * into it from public.inventory_items where id = (r->>'item_id')::uuid;
    update public.inventory_items set qty_on_hand = v_counted where id = it.id;
    insert into public.inventory_audit_log (entity_type, entity_id, action, before, after, actor)
    values ('inventory_items', it.id, 'telegram_count',
            jsonb_build_object('qty_on_hand', it.qty_on_hand),
            jsonb_build_object('qty_on_hand', v_counted, 'note', p_note),
            'telegram:' || p_telegram_user_id::text || ':' || p.role);
    v_out := v_out || jsonb_build_object('name', it.name, 'before', it.qty_on_hand, 'after', v_counted);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'updated', v_n, 'by_role', p.role, 'rows', v_out);
end $$;

comment on function public.telegram_apply_inventory_count_v1(bigint, jsonb, text) is
  'Apply a Telegram stock count (session 33, SPEC-03): maps the tapper''s Telegram id to a staff profile, requires manage_inventory plus property access, refuses a stale or movement-controlled item, writes qty_on_hand and audits each row as telegram_count.';

-- Restated in full: a rehearsal restores --no-acl, where the original revoke is missing.
revoke all on function public.telegram_apply_inventory_count_v1(bigint, jsonb, text) from public, anon, authenticated;
grant execute on function public.telegram_apply_inventory_count_v1(bigint, jsonb, text) to service_role;

commit;
