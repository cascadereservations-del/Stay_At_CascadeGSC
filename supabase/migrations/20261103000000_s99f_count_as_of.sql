-- 20261103000000_s99f_count_as_of.sql
-- Session 99f (lane SQL): release s99f_count_as_of_20261103. Owner decision D-351.
-- A count taken at time T (a printout "Printed 16 Oct 2026, 08:21" filled in by hand) says what was on hand at T. Everything logged for the item after T
-- (cleaner usage, purchases, other counts) still happened, so the new quantity is  counted + (qty_now - qty_at(T)),  never below 0.
--
-- WHAT qty_at(T) CAN BE BUILT FROM (every writer of inventory_items.qty_on_hand in supabase/migrations, latest live body of each):
--   record_inventory_usage v3 (20261007112000)       NOT in inventory_audit_log. Writes inventory_usage (used_qty, created_at); stock movement only for a controlled item.
--   apply_inventory_purchase (20261020000000, OCR)   inventory_purchases + audit ocr_restock (after.qty_added, after.purchase_id). Before 20261020 the purchase row held PACKS,
--                                                    the audit row always holds base units, so OCR restocks are read from the audit row.
--   record_inventory_receipt_v1 (20261020000000)     inventory_purchases (qty = base units) only. NOT in the audit log.
--   undo of a staff receipt (s84/s85/s86)            deletes the purchase row and decrements qty; so a purchase row is the live truth, and an ocr_restock audit row whose
--                                                    purchase is gone is ignored.
--   telegram_apply_inventory_count_v1 (20260918)     audit telegram_count (before/after qty_on_hand).
--   s86 test-purchase reset, one row                 audit test_purchase_removed_s86 (before/after).
--   record_inventory_movement / s_inventory_staff_movement_v1 / s_inventory_purchase_movement_v1 / inventory_apply_event_v1 (controlled items only; 0 in production)
--                                                    inventory_stock_movements (quantity_before / quantity_after).
-- So the audit log alone is NOT enough: usage and admin receipts on a normal (not movement-controlled) item are logged only in inventory_usage / inventory_purchases.
-- qty_at(T), for an item that is not movement-controlled:
--   qty_now + usage logged after T - purchases logged after T - (after - before) of every audit row after T that carries both figures (ocr_restock handled as above).
-- For a movement-controlled item: quantity_before of the first movement after T, else qty_now (exact).
-- KNOWN LIMITS (disclosed in the release): record_inventory_usage clamps at zero, so a usage that drove the shelf to 0 removed less than used_qty and qty_at(T) can
--   read high by the difference; a direct SQL edit of qty_on_hand leaves no trace; T must be within 60 days (older rows are not trusted).
--
-- v2 = v1 (same auth, two passes, duplicate/bad_row/bad_count/item_not_found/movement_controlled/not_authorized/stock_changed guards, same result keys) plus p_as_of.
-- v1 becomes a wrapper calling v2 with null (delta 0 = the old behaviour; its result gains the extra keys counted, since_delta, clamped, as_of, which no caller reads).
-- Guard (55000, nothing changes): the live v1 body must be the 20260918 body, md5(prosrc, CR stripped) fd6a1b06d326f87b73e6522b5d8f154a.
-- Grants restated (ML-21): revoke all from public, anon, authenticated; execute to service_role only, for qty_at, v2 and v1. The core s_apply_inventory_count_core_v1 has no grants at all (revoked from service_role too).
-- Fix round 1: the apply logic moved into that core so the owner data step (the owner has no Telegram id) can call it with actor 'owner:<user_id>:s99f-data-step'.
-- Rollback: supabase/rollbacks/20261103_s99f_count_as_of.sql. The data step is supabase/sql/2026-10-27-s99f-count-16oct.sql (Lloyd's block, AFTER this migration).

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.telegram_apply_inventory_count_v1(bigint,jsonb,text)');
  if v_got is distinct from 'fd6a1b06d326f87b73e6522b5d8f154a' then
    raise exception 's99f: public.telegram_apply_inventory_count_v1 is not the 20260918 body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

create or replace function public.inventory_qty_at_v1(p_item_id uuid, p_at timestamptz)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare
  it public.inventory_items%rowtype;
  v_first numeric;
begin
  select * into it from public.inventory_items where id = p_item_id;
  if not found then return null; end if;
  if p_at is null then return it.qty_on_hand; end if;

  if it.movement_controlled_at is not null then
    select m.quantity_before into v_first from public.inventory_stock_movements m
     where m.item_id = it.id and m.created_at > p_at order by m.sequence_no limit 1;
    return coalesce(v_first, it.qty_on_hand);
  end if;

  return it.qty_on_hand
    + coalesce((select sum(u.used_qty) from public.inventory_usage u where u.item_id = it.id and u.created_at > p_at), 0)
    - coalesce((select sum(p.qty) from public.inventory_purchases p
                 where p.item_id = it.id and p.created_at > p_at and coalesce(p.notes, '') not like 'Auto-restock from receipt OCR%'), 0)
    - coalesce((select sum((a.after ->> 'qty_added')::numeric) from public.inventory_audit_log a
                 where a.entity_type = 'inventory_items' and a.entity_id = it.id and a.action = 'ocr_restock' and a.created_at > p_at
                   and exists (select 1 from public.inventory_purchases p where p.id::text = a.after ->> 'purchase_id')), 0)
    - coalesce((select sum((a.after ->> 'qty_on_hand')::numeric - (a.before ->> 'qty_on_hand')::numeric) from public.inventory_audit_log a
                 where a.entity_type = 'inventory_items' and a.entity_id = it.id and a.action <> 'ocr_restock' and a.created_at > p_at
                   and jsonb_typeof(a.before -> 'qty_on_hand') = 'number' and jsonb_typeof(a.after -> 'qty_on_hand') = 'number'), 0);
end $$;

comment on function public.inventory_qty_at_v1(uuid, timestamptz) is
  'S99f (D-351): what was on hand for an item at a past time. Not controlled: qty_now + usage after T - purchases after T - counts and other audited changes after T. Controlled: quantity_before of the first movement after T. Null time = now.';

revoke all on function public.inventory_qty_at_v1(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.inventory_qty_at_v1(uuid, timestamptz) to service_role;

-- The apply logic lives in an internal core with NO grants to anyone (not even service_role): only definer functions in this schema reach it.
-- v2 does the Telegram auth and passes the audit actor; the owner data step calls the core directly with its own actor, because the owner has no Telegram id.
create or replace function public.s_apply_inventory_count_core_v1(
  p_actor text, p_rows jsonb, p_note text, p_as_of timestamptz, p_access_user uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  it public.inventory_items%rowtype;
  r jsonb;
  v_counted numeric;
  v_at numeric;
  v_delta numeric;
  v_new numeric;
  v_clamped boolean;
  v_n int := 0;
  v_out jsonb := '[]'::jsonb;
begin
  if coalesce(p_actor, '') = '' then return jsonb_build_object('ok', false, 'reason', 'bad_actor'); end if;

  -- a count "as of" must be a time in the past, within 60 days (qty_at is only trusted over the recent ledger)
  if p_as_of is not null and (p_as_of >= now() or p_as_of < now() - interval '60 days') then
    return jsonb_build_object('ok', false, 'reason', 'bad_as_of');
  end if;

  if jsonb_typeof(p_rows) is distinct from 'array' then return jsonb_build_object('ok', false, 'reason', 'bad_rows'); end if;
  if jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'bad_row_count');
  end if;
  -- One line per item, or a later line would silently overwrite an earlier one.
  if (select count(distinct e->>'item_id') from jsonb_array_elements(p_rows) e) <> jsonb_array_length(p_rows) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;

  -- PASS 1 validates and locks every row. A return inside pass 2 would keep the updates already made in this transaction,
  -- so nothing is written until the whole count is known to be good. The FOR UPDATE locks are held to the end of the transaction.
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
    -- ponytail: writes qty_on_hand directly like apply_inventory_purchase; a movement-controlled item must route through the movement ledger, so refuse it.
    if it.movement_controlled_at is not null then
      return jsonb_build_object('ok', false, 'reason', 'movement_controlled', 'item', it.name);
    end if;
    -- property access is decided by the caller: p_access_user is the staff user whose property list must contain the item, null = no check (owner, or the owner's data step)
    if p_access_user is not null and not exists (
      select 1 from public.staff_property_access s
       where s.user_id = p_access_user and s.property_id = it.property_id) then
      return jsonb_build_object('ok', false, 'reason', 'not_authorized');
    end if;
    -- Someone logged a purchase or a cleaning since the list was shown: the whole count is stale.
    if it.qty_on_hand <> (r->>'expected_before')::numeric then
      return jsonb_build_object('ok', false, 'reason', 'stock_changed', 'item', it.name);
    end if;
  end loop;

  -- PASS 2 applies. new = counted + what happened since the count time; with no time, since_delta is 0 and new = counted (v1).
  for r in select * from jsonb_array_elements(p_rows) loop
    v_counted := (r->>'counted')::numeric;
    select * into it from public.inventory_items where id = (r->>'item_id')::uuid;
    v_at := case when p_as_of is null then it.qty_on_hand else public.inventory_qty_at_v1(it.id, p_as_of) end;
    v_delta := it.qty_on_hand - v_at;
    v_new := round(v_counted + v_delta, 2);
    v_clamped := v_new < 0;
    if v_clamped then v_new := 0; end if;
    update public.inventory_items set qty_on_hand = v_new where id = it.id;
    insert into public.inventory_audit_log (entity_type, entity_id, action, before, after, actor)
    values ('inventory_items', it.id, 'telegram_count',
            jsonb_build_object('qty_on_hand', it.qty_on_hand),
            jsonb_build_object('qty_on_hand', v_new, 'note', p_note, 'as_of', p_as_of, 'counted', v_counted, 'since_delta', v_delta, 'clamped', v_clamped),
            p_actor);
    v_out := v_out || jsonb_build_object('name', it.name, 'before', it.qty_on_hand, 'after', v_new,
                                         'counted', v_counted, 'since_delta', v_delta, 'clamped', v_clamped);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'updated', v_n, 'as_of', p_as_of, 'rows', v_out);
end $$;

comment on function public.s_apply_inventory_count_core_v1(text, jsonb, text, timestamptz, uuid) is
  'S99f (D-351): internal two-pass stock count (guards, as-of rule, clamp at 0, audit telegram_count with actor p_actor). No grants; called by telegram_apply_inventory_count_v2 and the owner data step only.';

revoke all on function public.s_apply_inventory_count_core_v1(text, jsonb, text, timestamptz, uuid) from public, anon, authenticated, service_role;

create or replace function public.telegram_apply_inventory_count_v2(
  p_telegram_user_id bigint, p_rows jsonb, p_note text default null, p_as_of timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p public.staff_access_profiles%rowtype;
  v jsonb;
begin
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  if not public.staff_access_allowed(p.role, 'manage_inventory', p.disabled_at, null) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;

  v := public.s_apply_inventory_count_core_v1('telegram:' || p_telegram_user_id::text || ':' || p.role, p_rows, p_note, p_as_of,
                                              case when p.role = 'owner' then null else p.user_id end);
  if coalesce((v ->> 'ok')::boolean, false) then v := v || jsonb_build_object('by_role', p.role); end if;
  return v;
end $$;

comment on function public.telegram_apply_inventory_count_v2(bigint, jsonb, text, timestamptz) is
  'S99f (D-351): v1 plus p_as_of. Telegram auth, then s_apply_inventory_count_core_v1. A count taken at a past time T (within 60 days) applies counted + (qty_now - qty_at(T)), clamped at 0, and audits counted, since_delta, as_of, clamped. Null as_of is exactly v1.';

revoke all on function public.telegram_apply_inventory_count_v2(bigint, jsonb, text, timestamptz) from public, anon, authenticated;
grant execute on function public.telegram_apply_inventory_count_v2(bigint, jsonb, text, timestamptz) to service_role;

-- v1 stays for the deployed bot and for older callers: same arguments, now just v2 with no count time.
create or replace function public.telegram_apply_inventory_count_v1(
  p_telegram_user_id bigint, p_rows jsonb, p_note text default null)
returns jsonb language sql security definer set search_path = '' as $$
  select public.telegram_apply_inventory_count_v2(p_telegram_user_id, p_rows, p_note, null);
$$;

comment on function public.telegram_apply_inventory_count_v1(bigint, jsonb, text) is
  'Wrapper since S99f: telegram_apply_inventory_count_v2 with no count time (the SPEC-03 behaviour, session 33).';

revoke all on function public.telegram_apply_inventory_count_v1(bigint, jsonb, text) from public, anon, authenticated;
grant execute on function public.telegram_apply_inventory_count_v1(bigint, jsonb, text) to service_role;

commit;
