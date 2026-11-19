-- Session 122 (lane L1 SQL): release s122_item_moves_20261122. Move stock (or a mis-filed usage row) from one inventory item to another, keeping the usage learning right (D-383).
-- Contract: docs/s122/SPEC-stock-transfer.md, section "Revision 1" wins over sections 3-8 and 10.
--
--   inventory_item_moves                          closed table (RLS on, no grant to any API role): one row per stock move, usage move and undo, with the shelf before / after of both items.
--   inventory_usage_intervals.moved_between       signed units moved in minus out between the two counts of an interval (kind stock only), default 0.
--   inventory_usage.moved_from_item_id, moved_at  set when a usage row is re-pointed to another item (the first owner is kept on a second move).
--   move_inventory_stock_v1(from, to, qty, note, key)   admin: units from one item to another. A stock move is a FLOW between counts, like a purchase: it never creates or closes an interval.
--   move_inventory_usage_v1(usage_id, to, key)          admin: re-point one usage row to another item; the shelves follow (from +qty, to -qty). The learning never reads usage rows.
--   undo_inventory_move_v1(move_id, key)                admin: the reverse move, written as a new move row (undo_of); one undo per move, an undo cannot be undone.
--   get_inventory_item_moves_v1(item)                   read_operations: the item's moves, its usage rows of the last 30 days and its last 10 counts.
--   s_inventory_move_check_v1, s_inventory_move_json_v1 internal helpers, no grants to any role.
--
-- Usage learning (section 4.1): consumed = qty_prev + received_between + moved_between - qty_now, with
--   moved_between = sum(qty where to_item = item) - sum(qty where from_item = item) over inventory_item_moves, kind stock, created_at > prev_anchor_at and <= anchor_at.
--   A move and its undo net to 0 within one interval. Across a count, each side lands in the interval where it physically happened.
--   Worked numbers: KT 14 / BT 5 counted, 7 moved KT -> BT, 14 days and 4 stays later KT 6 / BT 9: KT consumed 14 - 7 - 6 = 1 (rate 0.1143), BT consumed 5 + 7 - 9 = 3 (rate 0.2143);
--   without the flow KT reads 8 (rate 0.6143, about 5.4x too high) and BT -4 (rejected as an unrecorded restock).
--
-- Patched in place, each by a DO block that reads the live body, strips CR, and accepts only the expected original md5 or the already patched one (55000 otherwise); the
-- result must have the pinned patched md5 (55000 if a replace did not apply). Live md5s read 2026-11-19 (each equals the md5 of the repo body, CR stripped):
--   record_inventory_anchor_v1  a8c9099d20a49fa57f266e0c2a73c3eb  (s120 usage learning)  adds v_moved to consumed and stores moved_between
--   record_missed_refill_v1     d0d9cf73fea6e67150d0766bdede7d02  (s120 count learning)  consumed and the 'minimum' line both include moved_between
--   record_inventory_usage      c1c7bff8e55b4aab5528b9fc60a49740  (20261007112000 + the s110 gate patch)  the [key:...] replay lookup also finds a re-pointed row
--   record_restock_v1           490f7db83c6cf1f1dfef72452a4f49e7  (s120 restock)  the same replay lookup. Reason (R1.5): a phone offline for more than 15 minutes retries a Restock on the
--                               `online` event; the key holds the original item id, so after an admin re-pointed the row the retry would write it again.
--   Every [key:...] lookup in the repo was grepped: purchases (inventory_purchases.notes) are not usage rows and are left alone; usage lookups exist only in these two functions.
--
-- Why a FLOW and not a count: a move is a physical statement about where units sit, never a count; counts stay the only anchors.
-- Refusals return {ok:false, reason, ...} and write nothing. Raises: 42501 for a caller without manage_inventory / read_operations (admin_require, called with PERFORM as a statement).
-- Audit rows: stock_moved_out / stock_moved_in carry numeric before / after qty_on_hand (inventory_qty_at_v1 subtracts them); usage_moved carries shelf_before / shelf_after only
-- (the re-pointed usage row already moves in qty_at's usage sum, so a qty_on_hand number there would count it twice).
-- Disclosed limits: a moved usage row cannot be deleted while its move row exists (on delete restrict); managers can still UPDATE inventory_usage.item_id directly (existing grants,
-- R1.12); s_apply_inventory_count_core_v1 locks items in row order, not id order, so a rare deadlock with a move aborts one side.
-- Rollback: supabase/rollbacks/20261122_s122_item_moves.sql (puts the four bodies back, drops the functions, the table and the three columns; recorded moves are lost by design).

begin;

-- 1. columns and the closed table --------------------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_usage_intervals add column if not exists moved_between numeric not null default 0;
alter table public.inventory_usage add column if not exists moved_from_item_id uuid references public.inventory_items(id);
alter table public.inventory_usage add column if not exists moved_at timestamptz;

create table if not exists public.inventory_item_moves (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  kind text not null check (kind in ('stock', 'usage')),
  from_item_id uuid not null references public.inventory_items(id),
  to_item_id uuid not null references public.inventory_items(id),
  qty numeric not null check (qty > 0 and qty < 100000000 and qty = round(qty, 2)),
  usage_id uuid references public.inventory_usage(id) on delete restrict,
  note text check (char_length(note) <= 200),
  actor_user_id uuid not null,
  idempotency_key text not null unique check (char_length(idempotency_key) between 8 and 160),
  undo_of uuid unique references public.inventory_item_moves(id),
  before_from numeric not null,
  after_from numeric not null,
  before_to numeric not null,
  after_to numeric not null,
  created_at timestamptz not null default now(),
  check (from_item_id <> to_item_id),
  check ((kind = 'usage') = (usage_id is not null))
);
create index if not exists inventory_item_moves_from_idx on public.inventory_item_moves (from_item_id, created_at);
create index if not exists inventory_item_moves_to_idx on public.inventory_item_moves (to_item_id, created_at);
create index if not exists inventory_item_moves_usage_idx on public.inventory_item_moves (usage_id) where usage_id is not null;
alter table public.inventory_item_moves enable row level security;
-- Supabase default privileges would grant a new table to the API roles: take every grant away (R1.1)
revoke all on table public.inventory_item_moves from public, anon, authenticated, service_role;
comment on table public.inventory_item_moves is
  'S122 (D-383): one row per stock move, usage move and undo between inventory items, with the shelf before / after of both. Closed table: read and written only through move_inventory_stock_v1, move_inventory_usage_v1, undo_inventory_move_v1 and get_inventory_item_moves_v1.';
comment on column public.inventory_usage_intervals.moved_between is
  'S122: units moved in minus units moved out between prev_anchor_at and anchor_at (inventory_item_moves kind stock). consumed = qty_prev + received_between + moved_between - qty_now.';
comment on column public.inventory_usage.moved_from_item_id is
  'S122: the item this usage row was first filed under, set when an admin re-points it (move_inventory_usage_v1). Null when never moved.';

-- 2. internal helpers (no grants to any role) ---------------------------------------------------------------------------------------------------------------------------------
-- Item rules shared by the three writers. Returns the refusal, or null when the two items can swap units. f = the side the units leave (or the usage row's item), t = the side they arrive.
create or replace function public.s_inventory_move_check_v1(f public.inventory_items, t public.inventory_items)
returns jsonb language plpgsql stable set search_path = '' as $$
begin
  if f.property_id is distinct from t.property_id then return jsonb_build_object('ok', false, 'reason', 'other_property'); end if;
  if not coalesce(f.is_active, false) then return jsonb_build_object('ok', false, 'reason', 'inactive', 'item', 'from'); end if;
  if not coalesce(t.is_active, false) then return jsonb_build_object('ok', false, 'reason', 'inactive', 'item', 'to'); end if;
  if not coalesce(f.is_consumable, false) then return jsonb_build_object('ok', false, 'reason', 'not_consumable', 'item', 'from'); end if;
  if not coalesce(t.is_consumable, false) then return jsonb_build_object('ok', false, 'reason', 'not_consumable', 'item', 'to'); end if;
  -- ledger items need movement rows on both sides: not built
  if f.movement_controlled_at is not null then return jsonb_build_object('ok', false, 'reason', 'movement_controlled', 'item', 'from'); end if;
  if t.movement_controlled_at is not null then return jsonb_build_object('ok', false, 'reason', 'movement_controlled', 'item', 'to'); end if;
  if lower(btrim(coalesce(f.unit, ''))) <> lower(btrim(coalesce(t.unit, ''))) then
    return jsonb_build_object('ok', false, 'reason', 'unit_mismatch', 'fromUnit', f.unit, 'toUnit', t.unit);
  end if;
  return null;
end $$;
revoke all on function public.s_inventory_move_check_v1(public.inventory_items, public.inventory_items) from public, anon, authenticated, service_role;

-- The result of a stored move (the first result again on a replay).
create or replace function public.s_inventory_move_json_v1(p_move uuid, p_replayed boolean)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('ok', true, 'moveId', m.id, 'kind', m.kind, 'qty', m.qty,
           'from', jsonb_build_object('id', m.from_item_id, 'name', fi.name, 'before', m.before_from, 'after', m.after_from),
           'to', jsonb_build_object('id', m.to_item_id, 'name', ti.name, 'before', m.before_to, 'after', m.after_to))
         || case when m.usage_id is not null then jsonb_build_object('usageId', m.usage_id) else '{}'::jsonb end
         || case when m.undo_of is not null then jsonb_build_object('undoOf', m.undo_of) else '{}'::jsonb end
         || case when p_replayed then jsonb_build_object('replayed', true) else '{}'::jsonb end
    from public.inventory_item_moves m
    join public.inventory_items fi on fi.id = m.from_item_id
    join public.inventory_items ti on ti.id = m.to_item_id
   where m.id = p_move
$$;
revoke all on function public.s_inventory_move_json_v1(uuid, boolean) from public, anon, authenticated, service_role;

-- 3. move_inventory_stock_v1 ---------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.move_inventory_stock_v1(p_from uuid, p_to uuid, p_qty numeric, p_note text, p_idempotency_key text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  f public.inventory_items%rowtype; t public.inventory_items%rowtype; m public.inventory_item_moves%rowtype;
  v_ref jsonb; v_id uuid; v_fb numeric; v_tb numeric; v_note text;
begin
  -- 1. key and quantity
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 160 then return jsonb_build_object('ok', false, 'reason', 'bad_key'); end if;
  -- NaN is greater than every number, so the upper bound refuses it too
  if p_qty is null or p_qty <= 0 or p_qty >= 100000000 or p_qty <> round(p_qty, 2) then return jsonb_build_object('ok', false, 'reason', 'bad_qty'); end if;
  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if char_length(v_note) > 200 then return jsonb_build_object('ok', false, 'reason', 'bad_note'); end if;
  if p_from is not null and p_from = p_to then return jsonb_build_object('ok', false, 'reason', 'same_item'); end if;
  -- 2. lock both items in id order
  perform 1 from public.inventory_items i where i.id in (p_from, p_to) order by i.id for update;
  -- 3. both must exist
  select * into f from public.inventory_items where id = p_from;
  if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found', 'item', 'from'); end if;
  select * into t from public.inventory_items where id = p_to;
  if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found', 'item', 'to'); end if;
  -- 4. the gate, an executed statement (never a lateral subquery, which a planner may drop)
  perform public.admin_require('manage_inventory', f.property_id);
  -- 5. replay: after the locks (a concurrent same-key call waits and then sees the committed row) and before not_enough (a replay after the shelf changed still replays)
  select * into m from public.inventory_item_moves where idempotency_key = p_idempotency_key;
  if found then
    if m.kind <> 'stock' or m.from_item_id <> p_from or m.to_item_id <> p_to or m.qty <> p_qty or m.usage_id is not null or m.undo_of is not null then
      return jsonb_build_object('ok', false, 'reason', 'key_conflict');
    end if;
    return public.s_inventory_move_json_v1(m.id, true);
  end if;
  -- 6. what may move
  v_ref := public.s_inventory_move_check_v1(f, t);
  if v_ref is not null then return v_ref; end if;
  v_fb := coalesce(f.qty_on_hand, 0); v_tb := coalesce(t.qty_on_hand, 0);
  if v_fb < p_qty then return jsonb_build_object('ok', false, 'reason', 'not_enough', 'on_hand', v_fb); end if;
  -- 7. write: the move row first, so a unique_violation on the key leaves the shelves untouched
  begin
    insert into public.inventory_item_moves(property_id, kind, from_item_id, to_item_id, qty, note, actor_user_id, idempotency_key, before_from, after_from, before_to, after_to)
    values (f.property_id, 'stock', f.id, t.id, p_qty, v_note, auth.uid(), p_idempotency_key, v_fb, v_fb - p_qty, v_tb, v_tb + p_qty)
    returning id into v_id;
  exception when unique_violation then
    select * into m from public.inventory_item_moves where idempotency_key = p_idempotency_key;
    if found and m.kind = 'stock' and m.from_item_id = p_from and m.to_item_id = p_to and m.qty = p_qty and m.usage_id is null and m.undo_of is null then
      return public.s_inventory_move_json_v1(m.id, true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'key_conflict');
  end;
  update public.inventory_items set qty_on_hand = v_fb - p_qty where id = f.id;
  update public.inventory_items set qty_on_hand = v_tb + p_qty where id = t.id;
  insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor) values
    ('inventory_items', f.id, 'stock_moved_out', jsonb_build_object('qty_on_hand', v_fb),
       jsonb_build_object('qty_on_hand', v_fb - p_qty, 'move_id', v_id, 'other_item_id', t.id, 'other_item_name', t.name), auth.uid()::text),
    ('inventory_items', t.id, 'stock_moved_in', jsonb_build_object('qty_on_hand', v_tb),
       jsonb_build_object('qty_on_hand', v_tb + p_qty, 'move_id', v_id, 'other_item_id', f.id, 'other_item_name', f.name), auth.uid()::text);
  return public.s_inventory_move_json_v1(v_id, false);
end $$;

-- 4. move_inventory_usage_v1 ---------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.move_inventory_usage_v1(p_usage_id uuid, p_to uuid, p_idempotency_key text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  u public.inventory_usage%rowtype; f public.inventory_items%rowtype; t public.inventory_items%rowtype; m public.inventory_item_moves%rowtype;
  v_ref jsonb; v_id uuid; v_fb numeric; v_tb numeric; v_qty numeric; v_item uuid;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 160 then return jsonb_build_object('ok', false, 'reason', 'bad_key'); end if;
  -- the usage row first, then both items in id order, then the row's item again
  select * into u from public.inventory_usage where id = p_usage_id for update;
  if not found or u.item_id is null then return jsonb_build_object('ok', false, 'reason', 'usage_not_found'); end if;
  perform 1 from public.inventory_items i where i.id in (u.item_id, p_to) order by i.id for update;
  select * into u from public.inventory_usage where id = p_usage_id;
  v_item := u.item_id;
  if v_item is null then return jsonb_build_object('ok', false, 'reason', 'usage_not_found'); end if;
  select * into f from public.inventory_items where id = v_item;
  if not found then return jsonb_build_object('ok', false, 'reason', 'usage_not_found'); end if;
  select * into t from public.inventory_items where id = p_to;
  if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found', 'item', 'to'); end if;
  perform public.admin_require('manage_inventory', f.property_id);
  v_qty := u.used_qty;
  -- replay: the row already sits under p_to through this key
  select * into m from public.inventory_item_moves where idempotency_key = p_idempotency_key;
  if found then
    if m.kind <> 'usage' or m.usage_id is distinct from p_usage_id or m.to_item_id <> p_to or m.undo_of is not null or m.qty <> v_qty then
      return jsonb_build_object('ok', false, 'reason', 'key_conflict');
    end if;
    return public.s_inventory_move_json_v1(m.id, true);
  end if;
  if f.id = t.id then return jsonb_build_object('ok', false, 'reason', 'same_item'); end if;
  if u.property_id is not null and u.property_id <> f.property_id then return jsonb_build_object('ok', false, 'reason', 'other_property'); end if;
  v_ref := public.s_inventory_move_check_v1(f, t);
  if v_ref is not null then return v_ref; end if;
  -- the row leaves f (its shelf gets the units back) and arrives under t (its shelf gives them up)
  v_fb := coalesce(f.qty_on_hand, 0); v_tb := coalesce(t.qty_on_hand, 0);
  if v_tb < v_qty then return jsonb_build_object('ok', false, 'reason', 'not_enough', 'on_hand', v_tb); end if;
  begin
    insert into public.inventory_item_moves(property_id, kind, from_item_id, to_item_id, qty, usage_id, actor_user_id, idempotency_key, before_from, after_from, before_to, after_to)
    values (f.property_id, 'usage', f.id, t.id, v_qty, u.id, auth.uid(), p_idempotency_key, v_fb, v_fb + v_qty, v_tb, v_tb - v_qty)
    returning id into v_id;
  exception when unique_violation then
    select * into m from public.inventory_item_moves where idempotency_key = p_idempotency_key;
    if found and m.kind = 'usage' and m.usage_id = p_usage_id and m.to_item_id = p_to and m.undo_of is null and m.qty = v_qty then
      return public.s_inventory_move_json_v1(m.id, true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'key_conflict');
  end;
  update public.inventory_usage set item_id = t.id, moved_from_item_id = coalesce(moved_from_item_id, f.id), moved_at = now() where id = u.id;
  update public.inventory_items set qty_on_hand = v_fb + v_qty where id = f.id;
  update public.inventory_items set qty_on_hand = v_tb - v_qty where id = t.id;
  -- no qty_on_hand numbers here: inventory_qty_at_v1 already sees the re-pointed row in its usage sum
  insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor) values
    ('inventory_items', f.id, 'usage_moved', jsonb_build_object('shelf_before', v_fb),
       jsonb_build_object('shelf_after', v_fb + v_qty, 'move_id', v_id, 'usage_id', u.id, 'qty', v_qty, 'direction', 'out', 'other_item_id', t.id, 'other_item_name', t.name), auth.uid()::text),
    ('inventory_items', t.id, 'usage_moved', jsonb_build_object('shelf_before', v_tb),
       jsonb_build_object('shelf_after', v_tb - v_qty, 'move_id', v_id, 'usage_id', u.id, 'qty', v_qty, 'direction', 'in', 'other_item_id', f.id, 'other_item_name', f.name), auth.uid()::text);
  return public.s_inventory_move_json_v1(v_id, false);
end $$;

-- 5. undo_inventory_move_v1 ----------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.undo_inventory_move_v1(p_move_id uuid, p_idempotency_key text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.inventory_item_moves%rowtype; m public.inventory_item_moves%rowtype; u public.inventory_usage%rowtype;
  f public.inventory_items%rowtype; t public.inventory_items%rowtype;
  v_ref jsonb; v_id uuid; v_fb numeric; v_tb numeric; v_fa numeric; v_ta numeric;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 160 then return jsonb_build_object('ok', false, 'reason', 'bad_key'); end if;
  -- the original move first: a concurrent second undo waits here and then sees undo_of taken (never a 23505)
  select * into o from public.inventory_item_moves where id = p_move_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'move_not_found'); end if;
  perform public.admin_require('manage_inventory', o.property_id);
  -- the same key again: this undo already happened
  select * into m from public.inventory_item_moves where idempotency_key = p_idempotency_key;
  if found then
    if m.undo_of is distinct from o.id then return jsonb_build_object('ok', false, 'reason', 'key_conflict'); end if;
    return public.s_inventory_move_json_v1(m.id, true);
  end if;
  if o.undo_of is not null then return jsonb_build_object('ok', false, 'reason', 'not_undoable'); end if;
  if exists (select 1 from public.inventory_item_moves x where x.undo_of = o.id) then
    return jsonb_build_object('ok', true, 'replayed', true, 'reason', 'already_undone');
  end if;
  if o.kind = 'usage' then
    select * into u from public.inventory_usage where id = o.usage_id for update;
    if not found then return jsonb_build_object('ok', false, 'reason', 'usage_not_found'); end if;
  end if;
  -- the undo moves the other way: from = where the move arrived, to = where it came from
  perform 1 from public.inventory_items i where i.id in (o.from_item_id, o.to_item_id) order by i.id for update;
  select * into f from public.inventory_items where id = o.to_item_id;
  select * into t from public.inventory_items where id = o.from_item_id;
  if o.kind = 'usage' then
    -- only the newest live move of the row, with the row still where that move put it
    if u.item_id is distinct from o.to_item_id
       or exists (select 1 from public.inventory_item_moves x
                   where x.usage_id = o.usage_id and x.id <> o.id and x.created_at > o.created_at and x.undo_of is null
                     and not exists (select 1 from public.inventory_item_moves y where y.undo_of = x.id)) then
      return jsonb_build_object('ok', false, 'reason', 'moved_since');
    end if;
  end if;
  v_ref := public.s_inventory_move_check_v1(f, t);
  if v_ref is not null then return v_ref; end if;
  v_fb := coalesce(f.qty_on_hand, 0); v_tb := coalesce(t.qty_on_hand, 0);
  if o.kind = 'stock' then
    -- the destination of the original gives the units back: refused when it has used them since
    if v_fb < o.qty then return jsonb_build_object('ok', false, 'reason', 'not_enough', 'on_hand', v_fb); end if;
    v_fa := v_fb - o.qty; v_ta := v_tb + o.qty;
  else
    -- the row goes back to its old item, which gives the units up again
    if v_tb < o.qty then return jsonb_build_object('ok', false, 'reason', 'not_enough', 'on_hand', v_tb); end if;
    v_fa := v_fb + o.qty; v_ta := v_tb - o.qty;
  end if;
  begin
    insert into public.inventory_item_moves(property_id, kind, from_item_id, to_item_id, qty, usage_id, note, actor_user_id, idempotency_key, undo_of, before_from, after_from, before_to, after_to)
    values (o.property_id, o.kind, f.id, t.id, o.qty, o.usage_id, 'undo', auth.uid(), p_idempotency_key, o.id, v_fb, v_fa, v_tb, v_ta)
    returning id into v_id;
  exception when unique_violation then
    select * into m from public.inventory_item_moves where idempotency_key = p_idempotency_key;
    if found and m.undo_of = o.id then return public.s_inventory_move_json_v1(m.id, true); end if;
    if exists (select 1 from public.inventory_item_moves x where x.undo_of = o.id) then
      return jsonb_build_object('ok', true, 'replayed', true, 'reason', 'already_undone');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'key_conflict');
  end;
  update public.inventory_items set qty_on_hand = v_fa where id = f.id;
  update public.inventory_items set qty_on_hand = v_ta where id = t.id;
  if o.kind = 'stock' then
    insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor) values
      ('inventory_items', f.id, 'stock_moved_out', jsonb_build_object('qty_on_hand', v_fb),
         jsonb_build_object('qty_on_hand', v_fa, 'move_id', v_id, 'undo_of', o.id, 'other_item_id', t.id, 'other_item_name', t.name), auth.uid()::text),
      ('inventory_items', t.id, 'stock_moved_in', jsonb_build_object('qty_on_hand', v_tb),
         jsonb_build_object('qty_on_hand', v_ta, 'move_id', v_id, 'undo_of', o.id, 'other_item_id', f.id, 'other_item_name', f.name), auth.uid()::text);
  else
    -- back with the first owner: the row is no longer "moved"; otherwise it keeps its first owner
    update public.inventory_usage
       set item_id = t.id,
           moved_from_item_id = case when moved_from_item_id = t.id then null else moved_from_item_id end,
           moved_at = case when moved_from_item_id = t.id then null else now() end
     where id = u.id;
    insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor) values
      ('inventory_items', f.id, 'usage_moved', jsonb_build_object('shelf_before', v_fb),
         jsonb_build_object('shelf_after', v_fa, 'move_id', v_id, 'undo_of', o.id, 'usage_id', u.id, 'qty', o.qty, 'direction', 'out', 'other_item_id', t.id, 'other_item_name', t.name), auth.uid()::text),
      ('inventory_items', t.id, 'usage_moved', jsonb_build_object('shelf_before', v_tb),
         jsonb_build_object('shelf_after', v_ta, 'move_id', v_id, 'undo_of', o.id, 'usage_id', u.id, 'qty', o.qty, 'direction', 'in', 'other_item_id', f.id, 'other_item_name', f.name), auth.uid()::text);
  end if;
  return public.s_inventory_move_json_v1(v_id, false);
end $$;

-- 6. get_inventory_item_moves_v1 -----------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.get_inventory_item_moves_v1(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  i public.inventory_items%rowtype; v_moves jsonb; v_usage jsonb; v_counts jsonb; v_today date := public.manila_today();
begin
  select * into i from public.inventory_items where id = p_item_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found'); end if;
  perform public.admin_require('read_operations', i.property_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'kind', s.kind, 'direction', case when s.to_item_id = i.id then 'in' else 'out' end,
           'otherItem', o.name, 'otherItemId', o.id, 'qty', s.qty, 'at', s.created_at,
           'undone', exists (select 1 from public.inventory_item_moves y where y.undo_of = s.id),
           'undoOf', s.undo_of,
           'canUndo', s.undo_of is null and not exists (select 1 from public.inventory_item_moves y where y.undo_of = s.id),
           'usageId', s.usage_id, 'note', s.note,
           'actor', (select coalesce(nullif(btrim(a.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(a.raw_user_meta_data ->> 'display_name'), '')) from auth.users a where a.id = s.actor_user_id)
         ) order by s.created_at desc, s.id), '[]'::jsonb) into v_moves
    from (select * from public.inventory_item_moves m where m.from_item_id = i.id or m.to_item_id = i.id order by m.created_at desc, m.id limit 50) s
    join public.inventory_items o on o.id = case when s.to_item_id = i.id then s.from_item_id else s.to_item_id end;

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'date', s.session_date, 'qty', s.used_qty, 'loggedBy', s.logged_by, 'at', s.created_at,
                                               'movedFrom', (select fi.name from public.inventory_items fi where fi.id = s.moved_from_item_id))
                           order by s.session_date desc, s.created_at desc nulls last, s.id), '[]'::jsonb) into v_usage
    from (select * from public.inventory_usage u where u.item_id = i.id and u.session_date >= v_today - 30
           order by u.session_date desc, u.created_at desc nulls last, u.id limit 50) s;

  select coalesce(jsonb_agg(jsonb_build_object('at', s.anchor_at, 'qty', s.qty_now) order by s.anchor_at desc), '[]'::jsonb) into v_counts
    from (select x.anchor_at, x.qty_now from public.inventory_usage_intervals x where x.item_id = i.id order by x.anchor_at desc limit 10) s;

  return jsonb_build_object('ok', true, 'moves', v_moves, 'usage', v_usage, 'counts', v_counts);
end $$;

-- 7. grants, stated in full (rehearsal restores are --no-acl, production has default privileges) -------------------------------------------------------------------------------
revoke all on function public.move_inventory_stock_v1(uuid, uuid, numeric, text, text) from public, anon, service_role;
revoke all on function public.move_inventory_usage_v1(uuid, uuid, text) from public, anon, service_role;
revoke all on function public.undo_inventory_move_v1(uuid, text) from public, anon, service_role;
revoke all on function public.get_inventory_item_moves_v1(uuid) from public, anon, service_role;
grant execute on function public.move_inventory_stock_v1(uuid, uuid, numeric, text, text) to authenticated;
grant execute on function public.move_inventory_usage_v1(uuid, uuid, text) to authenticated;
grant execute on function public.undo_inventory_move_v1(uuid, text) to authenticated;
grant execute on function public.get_inventory_item_moves_v1(uuid) to authenticated;

comment on function public.move_inventory_stock_v1(uuid, uuid, numeric, text, text) is
  'S122 (D-383): an admin (manage_inventory) moves p_qty units from one active consumable to another of the same unit and property. Not a count: a flow between counts (inventory_usage_intervals.moved_between). Replay-safe by the key.';
comment on function public.move_inventory_usage_v1(uuid, uuid, text) is
  'S122 (D-383): an admin re-points one usage row to another item; the from shelf gets the units back, the to shelf gives them up. The usage learning never reads usage rows. Replay-safe by the key.';
comment on function public.undo_inventory_move_v1(uuid, text) is
  'S122 (D-383): the reverse of one move, written as a new move row (undo_of). One undo per move; an undo cannot be undone; a usage move only while it is the newest live move of its row.';
comment on function public.get_inventory_item_moves_v1(uuid) is
  'S122 (D-383): the item''s moves (50), its usage rows of the last 30 days (50) and its last 10 counts. Needs read_operations.';

-- 8. in-place patches, each from the live body with an md5 guard (CR stripped) ---------------------------------------------------------------------------------------------------
-- 8.1 record_inventory_anchor_v1: original a8c9099d20a49fa57f266e0c2a73c3eb, patched f38dcf164dad76b9cda818509400a633
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)');
  if v_src is null then raise exception 's122: public.record_inventory_anchor_v1 is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = 'f38dcf164dad76b9cda818509400a633' then raise notice 's122: record_inventory_anchor_v1 already patched'; return; end if;
  if v_md5 is distinct from 'a8c9099d20a49fa57f266e0c2a73c3eb' then
    raise exception 's122: public.record_inventory_anchor_v1 is neither the body this release was cut from nor the patched one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$v_recv numeric; v_consumed numeric;$o0$, chr(13), ''), replace($n0$v_recv numeric; v_moved numeric; v_consumed numeric;$n0$, chr(13), ''));
  v_new := replace(v_new, replace($o1$  v_consumed := v_prev.qty_now + v_recv - p_qty_now;$o1$, chr(13), ''), replace($n1$  -- S122: stock moved between items (move_inventory_stock_v1 and its undo) is a flow between the two counts, like a purchase: units in minus units out
  v_moved := coalesce((select sum(case when m.to_item_id = i.id then m.qty else -m.qty end) from public.inventory_item_moves m
                        where m.kind = 'stock' and (m.to_item_id = i.id or m.from_item_id = i.id) and m.created_at > v_prev.anchor_at and m.created_at <= p_anchor_at), 0);
  v_consumed := v_prev.qty_now + v_recv + v_moved - p_qty_now;$n1$, chr(13), ''));
  v_new := replace(v_new, replace($o2$qty_prev, received_between, qty_now, consumed, days,$o2$, chr(13), ''), replace($n2$qty_prev, received_between, moved_between, qty_now, consumed, days,$n2$, chr(13), ''));
  v_new := replace(v_new, replace($o3$v_prev.qty_now, v_recv, p_qty_now, v_consumed, v_days,$o3$, chr(13), ''), replace($n3$v_prev.qty_now, v_recv, v_moved, p_qty_now, v_consumed, v_days,$n3$, chr(13), ''));
  if md5(v_new) is distinct from 'f38dcf164dad76b9cda818509400a633' then
    raise exception 's122: patching public.record_inventory_anchor_v1 did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_inventory_anchor_v1(p_item_id uuid, p_qty_now numeric, p_anchor_at timestamptz, p_source text) returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_inventory_anchor_v1(uuid, numeric, timestamptz, text) from public, anon, authenticated, service_role;

-- 8.2 record_missed_refill_v1: original d0d9cf73fea6e67150d0766bdede7d02, patched eb75c59afba9ac1984fb4b774554b503
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_missed_refill_v1(uuid,numeric)');
  if v_src is null then raise exception 's122: public.record_missed_refill_v1 is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = 'eb75c59afba9ac1984fb4b774554b503' then raise notice 's122: record_missed_refill_v1 already patched'; return; end if;
  if v_md5 is distinct from 'd0d9cf73fea6e67150d0766bdede7d02' then
    raise exception 's122: public.record_missed_refill_v1 is neither the body this release was cut from nor the patched one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$v_consumed := x.qty_prev + x.received_between + p_qty - x.qty_now;$o0$, chr(13), ''), replace($n0$v_consumed := x.qty_prev + x.received_between + x.moved_between + p_qty - x.qty_now;$n0$, chr(13), ''));
  v_new := replace(v_new, replace($o1$'minimum', x.qty_now - x.qty_prev - x.received_between)$o1$, chr(13), ''), replace($n1$'minimum', x.qty_now - x.qty_prev - x.received_between - x.moved_between)$n1$, chr(13), ''));
  if md5(v_new) is distinct from 'eb75c59afba9ac1984fb4b774554b503' then
    raise exception 's122: patching public.record_missed_refill_v1 did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_missed_refill_v1(p_item_id uuid, p_qty numeric) returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_missed_refill_v1(uuid, numeric) from public, anon, authenticated, service_role;
grant execute on function public.record_missed_refill_v1(uuid, numeric) to authenticated;

-- 8.3 record_inventory_usage: original c1c7bff8e55b4aab5528b9fc60a49740, patched 365f7c6d50258a611612465e4ad3624b
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_inventory_usage(uuid,date,text,text,jsonb)');
  if v_src is null then raise exception 's122: public.record_inventory_usage is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = '365f7c6d50258a611612465e4ad3624b' then raise notice 's122: record_inventory_usage already patched'; return; end if;
  if v_md5 is distinct from 'c1c7bff8e55b4aab5528b9fc60a49740' then
    raise exception 's122: public.record_inventory_usage is neither the body this release was cut from nor the patched one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$u.item_id = v_item and u.notes like '%[key:' || v_usage_key || ']%'$o0$, chr(13), ''), replace($n0$(u.item_id = v_item or u.moved_from_item_id = v_item) and u.notes like '%[key:' || v_usage_key || ']%'$n0$, chr(13), ''));
  if md5(v_new) is distinct from '365f7c6d50258a611612465e4ad3624b' then
    raise exception 's122: patching public.record_inventory_usage did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_inventory_usage(p_property_id uuid, p_session_date date, p_logged_by text, p_notes text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_inventory_usage(uuid, date, text, text, jsonb) from public, anon;
grant execute on function public.record_inventory_usage(uuid, date, text, text, jsonb) to authenticated, service_role;

-- 8.4 record_restock_v1: original 490f7db83c6cf1f1dfef72452a4f49e7, patched 94a9e42b7b2a439852be3c9ae591010d
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)');
  if v_src is null then raise exception 's122: public.record_restock_v1 is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = '94a9e42b7b2a439852be3c9ae591010d' then raise notice 's122: record_restock_v1 already patched'; return; end if;
  if v_md5 is distinct from '490f7db83c6cf1f1dfef72452a4f49e7' then
    raise exception 's122: public.record_restock_v1 is neither the body this release was cut from nor the patched one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$u.item_id = v_item and u.notes like '%[key:' || v_key || ']%'$o0$, chr(13), ''), replace($n0$(u.item_id = v_item or u.moved_from_item_id = v_item) and u.notes like '%[key:' || v_key || ']%'$n0$, chr(13), ''));
  if md5(v_new) is distinct from '94a9e42b7b2a439852be3c9ae591010d' then
    raise exception 's122: patching public.record_restock_v1 did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_restock_v1(p_property_id uuid, p_session_date date, p_logged_by text, p_notes text, p_rows jsonb, p_remember jsonb, p_upkeep jsonb) returns jsonb language plpgsql volatile security definer set search_path to '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb) to authenticated, service_role;

commit;
