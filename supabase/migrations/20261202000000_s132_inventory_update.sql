-- Session 132: release s132_inventory_update_20261202 (D-396). The server side of the inventory Update sheet. Over s131b_followups_20261201 (D-395), which must already be applied.
--
--   NEW   inventory_damage_reports (table, RLS on, no grant), record_inventory_damage_v1 (broken or missing lasting stock: clamp at 0, movement for a controlled item, audit row, shopping-list proposal, ONE
--         follow-up task per report, idempotent on the key), undo_inventory_damage_v1, undo_inventory_usage_v1 (by the usage_key), undo_linen_stain_v1 (by the report key),
--         s_inventory_purchase_note_v1 (internal helper of the history, no grant). Undo window 15 minutes for the person who did it; manage_inventory any time.
--   CHANGED (same signature, grants restated, in place from the live body, the result pinned by md5)
--         s_inventory_staff_movement_v1, reconcile_inventory_baseline_v1, inventory_undo_v1   report_supply (laundry) also counts and undoes a count: one gate line each.
--         inventory_item_update_v1                                                           a category change into Kitchen utensils or Appliances with no consumable sent makes the item lasting, for a caller with manage_inventory only (a cleaner cannot flip is_consumable that way).
--         get_inventory_catalogue_v1, get_inventory_item_moves_v1                            the usage reads skip a usage row that was undone (undone_at is not null).
--         inventory_item_change_undo_v1                                                      (round 2) the "used since the add" test of a created item skips an undone usage row (one anchored line, md5 pinned).
--   A usage undo keeps a tombstone (F7): inventory_usage gains undone_at / undone_qty / removed_qty; an undone row has used_qty 0 (so every sum over usage ignores it), keeps its [key:K] note (so the same
--   usage_key sent again is a replay, not a second record), and is skipped by the readers that count rows or days. removed_qty is what record_inventory_usage really took off the shelf (a use of 3 on stock 1
--   clamps at 0 and takes 1); a BEFORE INSERT trigger fills it, because record_inventory_usage is not replaced here. The undo of a not-controlled item puts back only that amount (F1).
--   CHANGED (new argument list, the old one dropped so a short call is never ambiguous)
--         record_inventory_receipt_v1   9 -> 10 arguments: p_note (stored after the key tag in the purchase notes).
--         inventory_receipt_manual_v1   4 -> 7 arguments: p_total_paid, p_receipt_path, p_note (stored on the draft row; still no finance write; the owner/admin task says "Paid PHP x" and "receipt photo").
--         record_linen_stains_v1        5 -> 6 arguments: p_photo_path; rows take reason ('stained'|'damaged') and note; report_supply also allowed; an undone report no longer counts toward its task.
--   CHANGED (same signature)
--         inventory_item_history_v1     every row gains note and source; usage, receipt, damage and linen rows join; rows of those kinds carry qty. Existing keys unchanged.
--   COLUMNS  linen_stain_reports.reason / note / photo_path / undone_at, inventory_receipt_drafts.note, inventory_usage.undone_at / undone_qty / removed_qty (all nullable; old rows keep null).
--   TRIGGER  inventory_usage_removed_v1 (BEFORE INSERT on inventory_usage, internal function s_inventory_usage_removed_v1, security invoker, no grant).
--   CHANGED (round 3, same signature, md5 pinned) inventory_qty_at_v1 (past stock knows the usage tombstone), get_usage_medians (skips an undone use).
-- Round 3 (fix round, narrow list):
--   F8   undo_inventory_usage_v1 writes the usage_undo audit row with the REAL shelf before and after; inventory_qty_at_v1 is re-cut (section 4b, md5 75e63656... -> 14b0a491...): a tombstone created after T is added back,
--        the undo audit delta is subtracted by the existing audit term, so stock S, use r, undo gives S before the use, S - r between use and undo, S after the undo.
--   F9   the removed_qty trigger is SECURITY INVOKER and gives removed_qty 0 when current_user is authenticated or anon (a direct REST insert never lowered any stock); inside record_inventory_usage (owner postgres) it is unchanged.
--        DEVIATION from the "security definer" wording of F14: a definer trigger function sees its owner as current_user for both callers and could not tell them apart; it keeps search_path '' and no grant.
--   F10  get_usage_medians() (legacy, defined only in schemas/000) skips an undone row (md5 30168efb... -> eb605dd6...).
--   F11  the undo changes no stock when the amount to put back is 0 or qty_on_hand is null; a controlled item with no movement for the use gets an adjustment of removed_qty.
--   F12  record_inventory_usage is pinned (365f7c6d50258a611612465e4ad3624b) in the guard.   F13  the undo locks the usage rows (for update) in its first phase.
-- Known limits: a LIVE usage row that was clamped (used 3, shelf 1) still adds back used_qty in inventory_qty_at_v1 (the s99f limit; the tombstone add-back uses what was really taken); a direct REST insert as authenticated
-- records a usage row but changes no stock (its undo restores 0).
-- Round 2: record_inventory_usage is NOT patched: its gate has accepted report_supply since s110 (20261112000000; the body 365f7c6d... pinned by s122). The guard asserts it (55000 if the live body lacks report_supply) and the grants are restated.
-- Not replaced: record_inventory_usage, inventory_item_create_v1 (already defaults a new item to lasting; see the lane report), s_inventory_receipt_confirm_core_v1 and every other function.
-- Guard (55000, nothing changes): each replaced function must be the body it was cut from or this release (md5 of prosrc, CR stripped). Grants restated (ML-21).
-- Rollback: supabase/rollbacks/20261202_s132_inventory_update.sql (puts the exact previous bodies back and drops what is new; the md5s of the previous bodies are the first value of each guard row above).

begin;

-- 1. guard ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v text; v2 text; r record;
begin
  -- what this release builds on
  for r in select * from (values ('public.linen_stain_reports'), ('public.inventory_receipt_drafts'), ('public.inventory_shopping_list'), ('public.inventory_usage'), ('public.inventory_item_moves'),
                                  ('public.inventory_audit_log'), ('public.follow_up_tasks'), ('public.inventory_item_changes')) t(rel) loop
    if to_regclass(r.rel) is null then raise exception using errcode = '55000', message = 's132: ' || r.rel || ' is missing: apply the earlier releases first'; end if;
  end loop;
  for r in select * from (values ('public.system_task_open_v1(uuid,text,text,text,text,text)'), ('public.s_inventory_actor_name_v1(uuid)'), ('public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)'),
                                  ('public.s_inventory_receipt_confirm_core_v1(uuid,jsonb,date,text,boolean)'), ('public.record_inventory_usage(uuid,date,text,text,jsonb)'), ('public.finance_human_authorized(uuid)')) t(sig) loop
    if to_regprocedure(r.sig) is null then raise exception using errcode = '55000', message = 's132: ' || r.sig || ' is missing: apply the earlier releases first'; end if;
  end loop;
  -- the replaced functions must be the body they were cut from, or already this release (md5 of prosrc, CR stripped)
  for r in select * from (values
    ('public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text)', '61b51c8b14d81d167dffd74c14dfe6e0', 'b56d8bce61c205b3265ff99b8336bf35'),
    ('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)', '18bea3e74b205dc7526a9614b83521cc', 'fdeaf212bebc578ee82f9240e6c05417'),
    ('public.inventory_undo_v1(uuid,uuid)', 'b1c19525aa43a0a529c511932d97a2fa', '5125463a4d686d5a180f1ee599fa00b7'),
    ('public.inventory_item_update_v1(uuid,jsonb)', 'c6ec09668ba7416ababeebe6a225b9d0', '618e3ec14138f9ce05c4c3dc1b1fe7fa'),
    ('public.get_inventory_catalogue_v1(uuid)', '6832ffc21ce22a01f591cbcf03f42497', '2ed1f4a50454e4072409d98ed0eea53c'),
    ('public.get_inventory_item_moves_v1(uuid)', '84eaa4f00f2e7fcdb2e92a2b13b48f26', '865a052a81b49407dcf1b4e5f8f91f4e'),
    ('public.inventory_item_history_v1(uuid)', 'a8669ba0b6ff6654edf352e9b8d98543', 'bbf90cfbd5f97158307e12502ae1223e'),
    ('public.inventory_item_change_undo_v1(uuid)', '86d7879703760fdc90e6b455e33bdacd', 'f513d523af5ef4f99055ca73e789b7ce'),
    ('public.inventory_qty_at_v1(uuid,timestamptz)', '75e63656262684e72e8e02bdf6179818', '14b0a49112a97cbc3ca8318461af2078'),
    ('public.get_usage_medians()', '30168efbcee85ff9cccd6ab8f76d5a7d', 'eb605dd66ebd70bb83061e2f38795132')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 's132: ' || r.sig || ' is neither the body this release was cut from nor this release (md5 ' || coalesce(v, 'null') || '): re-cut it from the live body';
    end if;
  end loop;
  -- the three functions that gain arguments: the old signature is the body below, or the new signature is already this release
  for r in select * from (values
    ('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)', '549d602feb38ab8f0ab0a7bd8fb95ab3', 'public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid,text)', 'd190f6b6051be034e9e9babb99cbbf56'),
    ('public.inventory_receipt_manual_v1(jsonb,date,text,text)', '654f5be5d88cc9210c0a682f0fc16c43', 'public.inventory_receipt_manual_v1(jsonb,date,text,text,numeric,text,text)', '8c407320edbbc9d944a86461bef23adf'),
    ('public.record_linen_stains_v1(uuid,date,text,text,jsonb)', '40167053bb97aa54d1cfff4f8dc243fe', 'public.record_linen_stains_v1(uuid,date,text,text,jsonb,text)', 'e4cfcd996dda6d2cd7a3239cf574ab9e')
  ) t(sig_old, m_old, sig_new, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig_old);
    select md5(replace(p.prosrc, chr(13), '')) into v2 from pg_proc p where p.oid = to_regprocedure(r.sig_new);
    if not (v = r.m_old and v2 is null) and not (v is null and v2 = r.m_new) then
      raise exception using errcode = '55000', message = 's132: ' || r.sig_old || ' is not the body this release was cut from (md5 ' || coalesce(v, 'null') || ', new signature ' || coalesce(v2, 'absent') || '): re-cut it from the live body';
    end if;
  end loop;
end $g$;

-- contract rev 1: a laundry worker (report_supply) records "Used up" through record_inventory_usage. The gate has accepted report_supply since s110; refuse to go on if the live body does not.
do $g$
declare v_src text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.record_inventory_usage(uuid,date,text,text,jsonb)');
  if v_src is null or position($a$public.current_staff_authorized('report_supply', p_property_id)$a$ in v_src) = 0 then
    raise exception using errcode = '55000', message = 's132: record_inventory_usage does not accept report_supply (md5 ' || coalesce(md5(v_src), 'null') || '): the s110 gate patch is missing, re-cut it from the live body';
  end if;
  -- F12: the undo and the removed_qty trigger lean on exactly this body (it inserts the usage row before it lowers the shelf, and takes the stock from inventory_items itself): pin it (s122 patched body)
  if md5(v_src) is distinct from '365f7c6d50258a611612465e4ad3624b' then
    raise exception using errcode = '55000', message = 's132: record_inventory_usage is not the body this release was cut from (md5 ' || coalesce(md5(v_src), 'null') || ', expected 365f7c6d50258a611612465e4ad3624b): re-cut it from the live body';
  end if;
end $g$;

-- 2. tables and columns -------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- one row per damage report from the Update sheet or the turnover check; written only by record_inventory_damage_v1 (RLS on, no grant to any API role, like linen_stain_reports)
create table public.inventory_damage_reports (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  idempotency_key text unique check (idempotency_key is null or char_length(idempotency_key) between 16 and 160),
  rows jsonb not null check (jsonb_typeof(rows) = 'array'),
  reason text check (reason is null or reason in ('broken', 'missing')),
  photo_path text check (photo_path is null or char_length(photo_path) <= 500),
  booking_id uuid,
  note text check (note is null or char_length(note) <= 500),
  source text not null check (source in ('update', 'turnover')),
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  undone_at timestamptz
);
create index inventory_damage_reports_property_idx on public.inventory_damage_reports (property_id, created_at desc);
alter table public.inventory_damage_reports enable row level security;
revoke all on table public.inventory_damage_reports from public, anon, authenticated, service_role;
comment on table public.inventory_damage_reports is 'S132 (D-396): one row per broken or missing report (rows hold item_id, qty, reason, note, before, after, clamped, movement_id per line). Written only by record_inventory_damage_v1, undone only by undo_inventory_damage_v1; no API grant.';

-- the Update sheet adds a reason, a note and a photo to a linen report, and a linen report can be undone (undone_at); the three new columns are nullable, old rows keep null
alter table public.linen_stain_reports add column if not exists reason text check (reason is null or reason in ('stained', 'damaged'));
alter table public.linen_stain_reports add column if not exists note text check (note is null or char_length(note) <= 500);
alter table public.linen_stain_reports add column if not exists photo_path text check (photo_path is null or char_length(photo_path) <= 500);
alter table public.linen_stain_reports add column if not exists undone_at timestamptz;

-- a usage undo keeps a tombstone instead of deleting the row (F7): undone_at marks it, undone_qty keeps the quantity that was logged, and used_qty is set to 0 so every sum over usage (KPI, forecast,
-- accounting) ignores it with no change to those readers (inventory_qty_at_v1 and get_usage_medians are re-cut in section 4b); the [key:K] note stays, so the same usage_key sent again is a replay and records nothing.
-- removed_qty is what record_inventory_usage really took off the shelf (F1): a use of 3 on stock 1 clamps at 0 and takes 1, so its undo puts back 1. The trigger below fills it on insert
-- (record_inventory_usage inserts the row before it lowers qty_on_hand, so the shelf is still the "before" there); a controlled item keeps the full quantity (its ledger movement is the truth).
-- Rows from before this release have removed_qty null: an undo then puts back used_qty, as it would have.
alter table public.inventory_usage add column if not exists undone_at timestamptz;
alter table public.inventory_usage add column if not exists undone_qty numeric(10, 2);
alter table public.inventory_usage add column if not exists removed_qty numeric(10, 2);
-- F9: SECURITY INVOKER on purpose. A direct REST insert (authenticated has INSERT on inventory_usage) never lowered any stock, so it must not record that it "removed" anything, or its undo would raise
-- the shelf. The trigger tells the two callers apart by current_user: inside record_inventory_usage (security definer, owned by the migration owner postgres, see schemas/000 "OWNER TO postgres") the current
-- user is that owner; a PostgREST insert runs as the JWT role, authenticated or anon, and gets removed_qty 0. (A definer trigger function could not tell: current_user would be its owner in both cases.)
-- Every other role (the owner, service_role) takes the computed amount, so a fixture or script insert as the owner behaves as before.
create or replace function public.s_inventory_usage_removed_v1()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.removed_qty := 0;
    return new;
  end if;
  select case when i.movement_controlled_at is not null then new.used_qty else least(new.used_qty, greatest(0, coalesce(i.qty_on_hand, 0))) end
    into new.removed_qty from public.inventory_items i where i.id = new.item_id;
  return new;
end;
$$;
revoke all on function public.s_inventory_usage_removed_v1() from public, anon, authenticated, service_role;
drop trigger if exists inventory_usage_removed_v1 on public.inventory_usage;
create trigger inventory_usage_removed_v1 before insert on public.inventory_usage for each row execute function public.s_inventory_usage_removed_v1();

-- the staff supply entry takes a note (the total paid and the receipt photo use the existing total and receipt_path columns)
alter table public.inventory_receipt_drafts add column if not exists note text check (note is null or char_length(note) <= 500);

-- internal helper of the history: the note typed with a receipt (admin: the text after the key tag; staff: the draft's note). No grant to any role.
create or replace function public.s_inventory_purchase_note_v1(p_notes text)
returns text language sql stable security definer set search_path = '' as $$
  select nullif(btrim(coalesce(
    substring(p_notes from '^Admin receipt \[key:[^]]*\]\s*(.*)$'),
    (select d.note from public.inventory_receipt_drafts d where d.id::text = substring(p_notes from '^Staff receipt \[key:([0-9a-f-]{36})\]')),
    '')), '')
$$;
revoke all on function public.s_inventory_purchase_note_v1(text) from public, anon, authenticated, service_role;

-- 3. damage reports ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- broken or missing lasting stock, from the Update sheet (p_source 'update') or the turnover utensils check ('turnover'). Refuses the whole call for a used-up item (consumable_item) or linen (linen_item),
-- clamps every row at 0, writes a stock movement for a movement-controlled item and an inventory_audit_log row for every changed item (inventory_qty_at_v1 rebuilds past stock from them), proposes a
-- replacement on the shopping list, and opens ONE follow-up task per report. The same key again changes nothing (duplicate true).
create or replace function public.record_inventory_damage_v1(p_property_id uuid, p_rows jsonb, p_photo_path text default null, p_booking_id uuid default null, p_add_to_list boolean default true, p_source text default 'update', p_note text default null, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_today date := public.manila_today(); v_row jsonb; v_no integer := 0; v_item uuid; v_qty numeric; v_reason text; v_rnote text;
  v_name text; v_unit text; v_cat text; v_cons boolean; v_ctl boolean; v_before numeric; v_after numeric; v_last numeric; v_clamped boolean; v_move uuid;
  v_rid uuid; v_prev public.inventory_damage_reports%rowtype; v_photo text; v_note text; v_first text; v_out jsonb := '[]'::jsonb; v_store jsonb := '[]'::jsonb;
  v_bits text[] := '{}'; v_lines text[] := '{}'; v_title text; v_detail text; v_tid uuid; v_listed integer := 0;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  -- F2: who sees the Update button is the app's call (D-396: hidden for finance, inspector and maintenance); this gate is only the server-side floor and hides nothing by role name.
  if p_property_id is null or not (public.current_staff_authorized('manage_inventory', p_property_id) or public.current_staff_authorized('submit_cleaning', p_property_id)
                                   or public.current_staff_authorized('report_supply', p_property_id)) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if p_source is null or p_source not in ('update', 'turnover') then return jsonb_build_object('ok', false, 'reason', 'source_invalid'); end if;
  if p_idempotency_key is not null and char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters';
  end if;
  v_photo := nullif(btrim(coalesce(p_photo_path, '')), '');
  if v_photo is not null and (char_length(v_photo) > 500 or v_photo like '%..%') then raise exception using errcode = '22023', message = 'photo path is not valid'; end if;
  v_note := left(nullif(btrim(coalesce(p_note, '')), ''), 500);

  -- a retry racing the first call waits here and then sees the first call's report
  if p_idempotency_key is not null then
    perform pg_advisory_xact_lock(hashtextextended('inventory_damage|' || p_idempotency_key, 0));
    select * into v_prev from public.inventory_damage_reports r where r.idempotency_key = p_idempotency_key;
    if found then
      if v_prev.property_id <> p_property_id or v_prev.actor_user_id is distinct from v_uid then raise exception using errcode = '22023', message = 'idempotency_key_reused'; end if;
      return jsonb_build_object('ok', true, 'duplicate', true, 'report_id', v_prev.id,
        'rows', (select coalesce(jsonb_agg(jsonb_build_object('item_id', e.value -> 'item_id', 'before', e.value -> 'before', 'after', e.value -> 'after', 'clamped', e.value -> 'clamped') order by e.ord), '[]'::jsonb)
                   from jsonb_array_elements(v_prev.rows) with ordinality e(value, ord)),
        'task_id', (select t.id from public.follow_up_tasks t where t.idempotency_key = 'system:inventory_damage:' || v_prev.id::text));
    end if;
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) not between 1 and 30 then return jsonb_build_object('ok', false, 'reason', 'rows_invalid'); end if;

  -- 1. check every row before anything is written (the whole call is refused when one row is)
  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row) <> 'object' or jsonb_typeof(v_row -> 'item_id') is distinct from 'string'
       or (v_row ->> 'item_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      return jsonb_build_object('ok', false, 'reason', 'rows_invalid');
    end if;
    if jsonb_typeof(v_row -> 'qty') is distinct from 'number' then return jsonb_build_object('ok', false, 'reason', 'qty_invalid'); end if;
    v_qty := (v_row ->> 'qty')::numeric;
    if v_qty <> floor(v_qty) or v_qty < 1 or v_qty > 99 then return jsonb_build_object('ok', false, 'reason', 'qty_invalid'); end if;
    if coalesce(v_row ->> 'reason', '') not in ('broken', 'missing') then return jsonb_build_object('ok', false, 'reason', 'rows_invalid'); end if;
    select i.is_consumable, i.category into v_cons, v_cat from public.inventory_items i
     where i.id = (v_row ->> 'item_id')::uuid and i.property_id = p_property_id and i.is_active;
    if not found then return jsonb_build_object('ok', false, 'reason', 'item_not_found'); end if;
    if coalesce(v_cons, false) then return jsonb_build_object('ok', false, 'reason', 'consumable_item'); end if;
    if lower(btrim(coalesce(v_cat, ''))) like 'linen%' then return jsonb_build_object('ok', false, 'reason', 'linen_item'); end if;
  end loop;
  v_first := p_rows -> 0 ->> 'reason';

  insert into public.inventory_damage_reports(property_id, idempotency_key, rows, reason, photo_path, booking_id, note, source, actor_user_id)
  values (p_property_id, p_idempotency_key, '[]'::jsonb, v_first, v_photo, p_booking_id, v_note, p_source, v_uid) returning id into v_rid;

  -- 2. write the rows
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_no := v_no + 1;
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty := (v_row ->> 'qty')::numeric;
    v_reason := v_row ->> 'reason';
    v_rnote := left(nullif(btrim(coalesce(v_row ->> 'note', '')), ''), 300);
    -- F5: the shopping row is bought in the item's pack name when it has one (purchase_unit), else in its unit
    select i.name, coalesce(nullif(btrim(i.purchase_unit), ''), i.unit), (i.movement_controlled_at is not null), coalesce(i.qty_on_hand, 0) into v_name, v_unit, v_ctl, v_before
      from public.inventory_items i where i.id = v_item for update;
    v_clamped := v_before < v_qty;
    v_after := greatest(0, v_before - v_qty);
    v_move := null;
    if v_after <> v_before then
      if v_ctl then
        select m.quantity_after into v_last from public.inventory_stock_movements m where m.item_id = v_item order by m.sequence_no desc limit 1;
        if v_last is distinct from v_before then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
      end if;
      update public.inventory_items set qty_on_hand = v_after where id = v_item;
      -- inventory_qty_at_v1 rebuilds past stock from these rows, so a back-dated count stays right.
      insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
      values ('inventory_items', v_item, 'damage', jsonb_build_object('qty_on_hand', v_before), jsonb_build_object('qty_on_hand', v_after), v_uid::text);
      if v_ctl then
        insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
        values (v_item, p_property_id, 'adjustment', v_before, v_after, 'Damage ' || v_reason || ' ' || v_today::text, v_uid,
                left('evt-' || encode(extensions.digest('inventory_damage_reports|' || v_rid::text || '|' || v_item::text || '|' || v_no::text || '|adjustment', 'sha256'), 'hex'), 80))
        returning id into v_move;
      end if;
    end if;
    v_store := v_store || jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', v_qty, 'reason', v_reason, 'note', v_rnote, 'before', v_before, 'after', v_after, 'clamped', v_clamped, 'movement_id', v_move));
    v_out := v_out || jsonb_build_array(jsonb_build_object('item_id', v_item, 'before', v_before, 'after', v_after, 'clamped', v_clamped));
    v_bits := v_bits || (trim_scale(v_qty)::text || ' x ' || v_name || ' (' || v_reason || ')');
    v_lines := v_lines || (trim_scale(v_qty)::text || ' x ' || v_name || ', ' || v_reason || coalesce(': ' || public.staff_redact_v1(v_rnote), ''));   -- F4: free text goes through staff_redact_v1 like the supply task
    if coalesce(p_add_to_list, true) then
      insert into public.inventory_shopping_list(property_id, item_id, item_name, quantity, purchase_unit, reason, proposed_by, idempotency_key)
      values (p_property_id, v_item, v_name, v_qty, v_unit, 'Replace ' || v_reason || ' (damage report)', v_uid, 'damage-' || v_rid::text || '-' || v_no::text);
      v_listed := v_listed + 1;
    end if;
  end loop;
  update public.inventory_damage_reports set rows = v_store where id = v_rid;

  -- 3. ONE follow-up task for the report
  v_title := case when p_booking_id is not null then 'Damage during a guest stay: ' else 'Damage reported: ' end || array_to_string(v_bits, ', ');
  v_detail := array_to_string(v_lines, E'\n')
              || case when p_booking_id is not null then E'\nHappened during a guest stay.' else '' end
              || coalesce(E'\nNote: ' || public.staff_redact_v1(v_note), '')
              || case when v_photo is not null then E'\nA photo was attached.' else '' end
              || case when v_listed > 0 then E'\nA replacement was proposed on the shopping list.' else '' end
              || case when p_source = 'turnover' then E'\nFound in the turnover utensils check.' else E'\nReported from the inventory Update sheet.' end;
  v_tid := public.system_task_open_v1(p_property_id, 'inventory_damage', v_rid::text, left(v_title, 200), v_detail, 'normal');

  return jsonb_build_object('ok', true, 'report_id', v_rid, 'rows', v_out, 'task_id', v_tid,
                            'list', case when coalesce(p_add_to_list, true) then 'table' else 'off' end);
end;
$$;

-- puts a damage report back: each row's stock returns (a movement for a controlled item, an audit row for every item), the replacement rows still only proposed are cancelled, the task is closed.
-- The reporter inside 15 minutes; manage_inventory any time.
create or replace function public.undo_inventory_damage_v1(p_report_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); r public.inventory_damage_reports%rowtype; v_mgr boolean; e record; v_delta numeric; v_name text; v_ctl boolean; v_cur numeric; v_last numeric; v_new numeric; v_restored integer := 0;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select * into r from public.inventory_damage_reports where id = p_report_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_mgr := public.current_staff_authorized('manage_inventory', r.property_id);
  if not (v_mgr or public.current_staff_authorized('submit_cleaning', r.property_id) or public.current_staff_authorized('report_supply', r.property_id)) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if r.undone_at is not null then return jsonb_build_object('ok', false, 'reason', 'already_undone'); end if;
  if not v_mgr then
    if r.actor_user_id is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_allowed'); end if;
    if r.created_at <= now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
  end if;

  for e in select x.value, x.ord from jsonb_array_elements(r.rows) with ordinality x(value, ord) order by x.ord loop
    v_delta := coalesce((e.value ->> 'before')::numeric, 0) - coalesce((e.value ->> 'after')::numeric, 0);
    if v_delta <= 0 then continue; end if;
    select i.name, (i.movement_controlled_at is not null), coalesce(i.qty_on_hand, 0) into v_name, v_ctl, v_cur
      from public.inventory_items i where i.id = (e.value ->> 'item_id')::uuid for update;
    if v_name is null then continue; end if;
    v_new := v_cur + v_delta;
    if v_ctl then
      select m.quantity_after into v_last from public.inventory_stock_movements m where m.item_id = (e.value ->> 'item_id')::uuid order by m.sequence_no desc limit 1;
      if v_last is distinct from v_cur then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
    end if;
    update public.inventory_items set qty_on_hand = v_new where id = (e.value ->> 'item_id')::uuid;
    insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
    values ('inventory_items', (e.value ->> 'item_id')::uuid, 'damage_undo', jsonb_build_object('qty_on_hand', v_cur), jsonb_build_object('qty_on_hand', v_new), v_uid::text);
    if v_ctl then
      insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
      values ((e.value ->> 'item_id')::uuid, r.property_id, 'adjustment', v_cur, v_new, 'Undo damage report ' || to_char((r.created_at at time zone 'Asia/Manila')::date, 'YYYY-MM-DD'), v_uid,
              left('evt-' || encode(extensions.digest('inventory_damage_reports|' || r.id::text || '|' || (e.value ->> 'item_id') || '|' || e.ord::text || '|undo', 'sha256'), 'hex'), 80));
    end if;
    v_restored := v_restored + 1;
  end loop;

  update public.inventory_shopping_list s set status = 'cancelled', version = s.version + 1, updated_at = now()
   where s.property_id = r.property_id and s.idempotency_key like 'damage-' || r.id::text || '-%' and s.status = 'proposed';
  update public.follow_up_tasks t set status = 'cancelled', completion_note = 'The damage report was undone.', updated_at = now(), version = t.version + 1
   where t.source_kind = 'inventory_damage' and t.source_ref = r.id::text and t.status in ('open', 'in_progress');
  update public.inventory_damage_reports set undone_at = now() where id = r.id;
  return jsonb_build_object('ok', true, 'restored', v_restored);
end;
$$;

-- 4. undo of a usage line and of a linen report ----------------------------------------------------------------------------------------------------------------------------------------------
-- p_usage_key is the usage_key the client sent to record_inventory_usage (kept in the row's notes as [key:K]). The person who logged it inside 15 minutes; manage_inventory any time.
-- The stock comes back (a compensating movement for a controlled item; for the others qty_on_hand gets back only what the use really took, removed_qty: a use of 3 on stock 1 clamped at 0 and took 1) and the
-- usage row stays as a tombstone (undone_at, undone_qty, used_qty 0): the same usage_key sent again to record_inventory_usage finds the row and is a replay, so an undone use is never recorded twice, and every
-- reader that sums usage sees 0. inventory_qty_at_v1 (re-cut in section 4b) rebuilds past stock from the usage rows AND the audit rows: the undo audit row written here carries the REAL shelf before and after
-- (F8), so the stock at a time between the use and its undo is the shelf without the restore. A phase 1 lock (for update) is taken on the usage rows; a null qty_on_hand is never turned into 0 and a zero
-- restore changes nothing (F11); a usage made before the item became movement-controlled (no movement for it) comes back as one adjustment of removed_qty (F11).
create or replace function public.undo_inventory_usage_v1(p_usage_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); u public.inventory_usage%rowtype; v_prop uuid; v_mgr boolean; v_ids uuid[] := '{}'; v_id uuid; v_name text; v_ctl boolean; v_cur numeric; v_last numeric; v_new numeric;
  m public.inventory_stock_movements%rowtype; v_delta numeric; v_restored integer := 0; v_raw numeric; v_before numeric; v_after numeric;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_usage_key is null or char_length(p_usage_key) not between 1 and 160 then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  perform pg_advisory_xact_lock(hashtextextended('inventory_usage_undo|' || p_usage_key, 0));
  select coalesce(array_agg(x.id order by x.created_at, x.id), '{}') into v_ids from public.inventory_usage x
   where position('[key:' || p_usage_key || ']' in coalesce(x.notes, '')) > 0 and x.undone_at is null;
  if cardinality(v_ids) = 0 then
    -- every row of the key is a tombstone: it was undone already
    if exists (select 1 from public.inventory_usage x where position('[key:' || p_usage_key || ']' in coalesce(x.notes, '')) > 0 and x.undone_at is not null) then
      return jsonb_build_object('ok', false, 'reason', 'already_undone');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- 1. check every row before anything is written
  foreach v_id in array v_ids loop
    select * into u from public.inventory_usage where id = v_id for update;
    if u.undone_at is not null then return jsonb_build_object('ok', false, 'reason', 'already_undone'); end if;
    select i.property_id into v_prop from public.inventory_items i where i.id = u.item_id;
    v_mgr := public.current_staff_authorized('manage_inventory', v_prop);
    if not (v_mgr or public.current_staff_authorized('submit_cleaning', v_prop) or public.current_staff_authorized('report_supply', v_prop)) then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    if not v_mgr then
      if u.submitted_by_user_id is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_allowed'); end if;
      if u.created_at <= now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
    end if;
    -- inventory_item_moves.usage_id is on delete restrict: a usage line a move was made from stays
    if exists (select 1 from public.inventory_item_moves mv where mv.usage_id = u.id) then return jsonb_build_object('ok', false, 'reason', 'not_allowed'); end if;
  end loop;

  -- 2. put the stock back
  foreach v_id in array v_ids loop
    select * into u from public.inventory_usage where id = v_id;
    select i.name, (i.movement_controlled_at is not null), i.qty_on_hand, i.property_id into v_name, v_ctl, v_raw, v_prop
      from public.inventory_items i where i.id = u.item_id for update;
    v_cur := coalesce(v_raw, 0); v_before := v_raw; v_after := v_raw;
    if v_ctl then
      -- the movement record_inventory_usage wrote for this row (none when the stock did not change): its quantity comes back as one adjustment
      select * into m from public.inventory_stock_movements x where x.item_id = u.item_id
         and x.idempotency_key = left('evt-' || encode(extensions.digest('inventory_usage|' || u.id::text || '|' || u.item_id::text || '|usage', 'sha256'), 'hex'), 80);
      if found then
        v_delta := m.quantity_before - m.quantity_after;
      elsif u.removed_qty is not null then
        -- F11: the use was made while the item was not controlled yet (no movement for it); the shelf took removed_qty, so the ledger gets it back as an adjustment
        v_delta := u.removed_qty;
      else
        v_delta := 0;
      end if;
      if v_delta <> 0 and v_raw is not null then
        select x.quantity_after into v_last from public.inventory_stock_movements x where x.item_id = u.item_id order by x.sequence_no desc limit 1;
        if v_last is distinct from v_cur then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
        v_new := v_cur + v_delta;
        insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
        values (u.item_id, v_prop, 'adjustment', v_cur, v_new, 'Undo usage ' || u.session_date::text, v_uid,
                left('evt-' || encode(extensions.digest('inventory_usage|' || u.id::text || '|' || u.item_id::text || '|undo', 'sha256'), 'hex'), 80));
        update public.inventory_items set qty_on_hand = v_new where id = u.item_id;
        v_cur := v_new; v_after := v_new;
      end if;
    else
      -- F1: only what the use really took off the shelf comes back (a use clamped at 0 took less than used_qty); a row from before this release has no removed_qty and puts back used_qty.
      -- F11: nothing to put back (0) or no shelf figure (null) changes nothing: a null qty_on_hand is never turned into 0
      v_delta := least(u.used_qty, coalesce(u.removed_qty, u.used_qty));
      if v_delta <> 0 and v_raw is not null then
        v_new := v_cur + v_delta;
        update public.inventory_items set qty_on_hand = v_new where id = u.item_id;
        v_cur := v_new; v_after := v_new;
      end if;
    end if;
    -- F8: the audit row carries the real shelf before and after the restore (equal when nothing changed); inventory_qty_at_v1 subtracts after - before for a time before this undo
    insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
    values ('inventory_items', u.item_id, 'usage_undo', jsonb_build_object('qty_on_hand', v_before), jsonb_build_object('qty_on_hand', v_after, 'usage_key', p_usage_key), v_uid::text);
    -- F7: the tombstone (see the header): undone_at marks it, the logged quantity is kept in undone_qty, used_qty goes to 0 so no sum counts it, the [key:K] note stays for the replay
    update public.inventory_usage set undone_at = now(), undone_qty = u.used_qty, used_qty = 0 where id = u.id;
    v_restored := v_restored + 1;
  end loop;
  return jsonb_build_object('ok', true, 'restored', v_restored);
end;
$$;

-- 4b. inventory_qty_at_v1 and get_usage_medians know the tombstone ---------------------------------------------------------------------------------------------------------------------------
-- inventory_qty_at_v1 (s99f body 75e63656...) = stock now + usage after T - purchases after T - audited changes after T. A tombstone has used_qty 0, so the usage term lost its use and for a T between the
-- use (t1) and its undo (t2) the old maths gave S instead of S - r. Derivation, shelf S0 before the use, g = what the use took (least(undone_qty, removed_qty); r unless clamped), shelf now S0:
--   deltas of the shelf after T:  use at t1: -g;  undo at t2: +g (the audit row usage_undo has before = S0 - g, after = S0, written by undo_inventory_usage_v1);  stock(T) = now - (sum of deltas after T).
--   T < t1:       deltas -g + g = 0  -> S0.  The formula: + g (tombstone created after T, added back below) - g (the undo audit delta, already counted by the existing audit term, t2 > T) = now.
--   t1 < T < t2:  delta +g           -> S0 - g.  The formula: tombstone created before T adds nothing; the undo audit delta (t2 > T) subtracts g = now - g = S - r.
--   T > t2:       no delta           -> now.  Neither term counts anything.
-- So ONE new term (the add-back of g for a tombstone created after T) is enough: the subtraction for "undone after T" is the audit row the existing term already sums; adding a second one would count it twice.
-- A live usage row keeps adding back used_qty (the disclosed s99f clamp limit is unchanged). A movement-controlled item still reads quantity_before of the first movement after T.
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
    + coalesce((select sum(least(u.undone_qty, coalesce(u.removed_qty, u.undone_qty))) from public.inventory_usage u
                 where u.item_id = it.id and u.undone_at is not null and u.created_at > p_at), 0)
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
  'S99f (D-351), s132: what was on hand for an item at a past time. Not controlled: qty_now + usage after T + what an undone usage took (created after T) - purchases after T - counts and other audited changes after T (the usage undo audit row carries the real before and after). Controlled: quantity_before of the first movement after T. Null time = now.';
revoke all on function public.inventory_qty_at_v1(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.inventory_qty_at_v1(uuid, timestamptz) to service_role;

-- F10: the legacy get_usage_medians() (schemas/000, SECURITY DEFINER, search_path public; no later migration defines it, only the grants of 20260925030000) took the median of used_qty over 90 days: a
-- tombstone (used_qty 0) would pull it down. Only the undone_at filter is added; signature, owner and attributes are the same.
create or replace function public.get_usage_medians()
returns table(item_id uuid, median_used numeric)
language sql security definer set search_path to 'public' as $$
  select item_id,
         percentile_cont(0.5) within group (order by used_qty)::numeric(10,2)
  from inventory_usage
  where session_date >= current_date - interval '90 days'
    and undone_at is null
  group by item_id;
$$;
revoke all on function public.get_usage_medians() from public, anon;
grant execute on function public.get_usage_medians() to authenticated, service_role;

-- p_idempotency_key is the key the client sent to record_linen_stains_v1 (one submission = one or more rows). The reporter inside 15 minutes; manage_inventory any time. Every changed row's stock
-- comes back (a movement for a controlled item, an audit row for every item), the row is marked undone, and the open linen_replace task is reduced by its quantity (cancelled at 0).
create or replace function public.undo_linen_stain_v1(p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_n integer; v_open integer; v_prop uuid; v_mgr boolean; l public.linen_stain_reports%rowtype; v_by uuid; v_at timestamptz; v_ctl boolean; v_name text; v_cur numeric; v_last numeric;
  v_new numeric; v_delta numeric; v_tid uuid; v_total integer; v_rest public.linen_stain_reports%rowtype; v_restored integer := 0;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  perform pg_advisory_xact_lock(hashtextextended('linen_stains|' || p_idempotency_key, 0));
  select count(*)::integer, (count(*) filter (where r.undone_at is null))::integer, min(r.property_id::text)::uuid, min(r.reported_by_user_id::text)::uuid, min(r.created_at)
    into v_n, v_open, v_prop, v_by, v_at from public.linen_stain_reports r where r.idempotency_key = p_idempotency_key;
  if v_n = 0 then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_mgr := public.current_staff_authorized('manage_inventory', v_prop);
  if not (v_mgr or public.current_staff_authorized('submit_cleaning', v_prop) or public.current_staff_authorized('report_supply', v_prop)) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if v_open = 0 then return jsonb_build_object('ok', false, 'reason', 'already_undone'); end if;
  if not v_mgr then
    if v_by is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_allowed'); end if;
    if v_at <= now() - interval '15 minutes' then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
  end if;

  for l in select * from public.linen_stain_reports r where r.idempotency_key = p_idempotency_key and r.undone_at is null order by r.row_no for update loop
    v_delta := coalesce(l.stock_before, 0) - coalesce(l.stock_after, 0);
    if v_delta > 0 then
      select i.name, (i.movement_controlled_at is not null), coalesce(i.qty_on_hand, 0) into v_name, v_ctl, v_cur from public.inventory_items i where i.id = l.item_id for update;
      if v_name is not null then
        v_new := v_cur + v_delta;
        if v_ctl then
          select m.quantity_after into v_last from public.inventory_stock_movements m where m.item_id = l.item_id order by m.sequence_no desc limit 1;
          if v_last is distinct from v_cur then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
        end if;
        update public.inventory_items set qty_on_hand = v_new where id = l.item_id;
        insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
        values ('inventory_items', l.item_id, 'linen_stain_undo', jsonb_build_object('qty_on_hand', v_cur), jsonb_build_object('qty_on_hand', v_new), v_uid::text);
        if v_ctl then
          insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
          values (l.item_id, l.property_id, 'adjustment', v_cur, v_new, 'Undo linen ' || replace(l.outcome, '_', ' ') || ' ' || l.session_date::text, v_uid,
                  left('evt-' || encode(extensions.digest('linen_stain_reports|' || l.id::text || '|' || l.item_id::text || '|undo', 'sha256'), 'hex'), 80));
        end if;
        v_restored := v_restored + 1;
      end if;
    end if;
    update public.linen_stain_reports set undone_at = now() where id = l.id;
  end loop;

  -- every linen_replace task these rows fed: recount what is left, retitle it, or cancel it at 0
  for v_tid in select distinct r.task_id from public.linen_stain_reports r where r.idempotency_key = p_idempotency_key and r.task_id is not null loop
    select coalesce(sum(r.qty), 0)::integer into v_total from public.linen_stain_reports r where r.task_id = v_tid and r.undone_at is null;
    if v_total = 0 then
      update public.follow_up_tasks t set status = 'cancelled', completion_note = 'The linen report was undone.', updated_at = now(), version = t.version + 1
       where t.id = v_tid and t.status in ('open', 'in_progress');
    else
      select * into v_rest from public.linen_stain_reports r where r.task_id = v_tid and r.undone_at is null order by r.created_at desc, r.row_no desc limit 1;
      select i.name into v_name from public.inventory_items i where i.id = v_rest.item_id;
      update public.follow_up_tasks t
         set title = left('Replace ' || case when v_total = 1 then '1 ' else v_total::text || ' x ' end || coalesce(v_name, 'linen') || ', '
                          || case when v_rest.reason = 'damaged' then 'damaged' else 'stained' end || ' on ' || to_char(v_rest.session_date, 'FMDD Mon'), 200),
             updated_at = now()
       where t.id = v_tid and t.status in ('open', 'in_progress');
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'restored', v_restored);
end;
$$;

-- 5. a laundry worker (report_supply) may count, and undo a count: three bodies change by one gate line each (patched in place from the live body, the result pinned by md5) -----------------------------------------
-- s_inventory_staff_movement_v1: the gate also accepts report_supply (the same movement, the same invariants)
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text)');
  if v_src is null then raise exception 's132: public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text) is missing' using errcode = '55000'; end if;
  if md5(v_src) = 'b56d8bce61c205b3265ff99b8336bf35' then raise notice 's132: s_inventory_staff_movement_v1 already carries this change'; return; end if;
  if md5(v_src) <> '61b51c8b14d81d167dffd74c14dfe6e0' then raise exception 's132: s_inventory_staff_movement_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$if not found or not public.current_staff_authorized('submit_cleaning', i.property_id) then$f$, chr(13), ''), replace($r$if not found or not (public.current_staff_authorized('submit_cleaning', i.property_id) or public.current_staff_authorized('report_supply', i.property_id)) then$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> 'b56d8bce61c205b3265ff99b8336bf35' then raise exception 's132: s_inventory_staff_movement_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.s_inventory_staff_movement_v1(p_item_id uuid, p_kind text, p_quantity numeric, p_reason text, p_idempotency_key text)
    returns uuid language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;

-- reconcile_inventory_baseline_v1: owner/admin (manage_inventory) as before, a cleaner (submit_cleaning) as before, else report_supply, else refused 42501
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)');
  if v_src is null then raise exception 's132: public.reconcile_inventory_baseline_v1(uuid,numeric,text,text) is missing' using errcode = '55000'; end if;
  if md5(v_src) = 'fdeaf212bebc578ee82f9240e6c05417' then raise notice 's132: reconcile_inventory_baseline_v1 already carries this change'; return; end if;
  if md5(v_src) <> '18bea3e74b205dc7526a9614b83521cc' then raise exception 's132: reconcile_inventory_baseline_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$perform public.admin_require('submit_cleaning', i.property_id);$f$, chr(13), ''), replace($r$if not public.current_staff_authorized('submit_cleaning', i.property_id) then perform public.admin_require('report_supply', i.property_id); end if;$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> 'fdeaf212bebc578ee82f9240e6c05417' then raise exception 's132: reconcile_inventory_baseline_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.reconcile_inventory_baseline_v1(p_item_id uuid, p_counted_qty numeric, p_note text, p_idempotency_key text)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;

-- inventory_undo_v1: the same one-line gate change (the purchase undo still needs manage_inventory: not_yours)
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_undo_v1(uuid,uuid)');
  if v_src is null then raise exception 's132: public.inventory_undo_v1(uuid,uuid) is missing' using errcode = '55000'; end if;
  if md5(v_src) = '5125463a4d686d5a180f1ee599fa00b7' then raise notice 's132: inventory_undo_v1 already carries this change'; return; end if;
  if md5(v_src) <> 'b1c19525aa43a0a529c511932d97a2fa' then raise exception 's132: inventory_undo_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$perform public.admin_require('submit_cleaning', i.property_id);$f$, chr(13), ''), replace($r$if not public.current_staff_authorized('submit_cleaning', i.property_id) then perform public.admin_require('report_supply', i.property_id); end if;$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> '5125463a4d686d5a180f1ee599fa00b7' then raise exception 's132: inventory_undo_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_undo_v1(p_movement_id uuid default null, p_purchase_id uuid default null)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;

-- inventory_item_update_v1: a category change into Kitchen utensils or Appliances with no consumable sent makes the item lasting (manage_inventory only)
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_item_update_v1(uuid,jsonb)');
  if v_src is null then raise exception 's132: public.inventory_item_update_v1(uuid,jsonb) is missing' using errcode = '55000'; end if;
  if md5(v_src) = '618e3ec14138f9ce05c4c3dc1b1fe7fa' then raise notice 's132: inventory_item_update_v1 already carries this change'; return; end if;
  if md5(v_src) <> 'c6ec09668ba7416ababeebe6a225b9d0' then raise exception 's132: inventory_item_update_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$    i.is_consumable := (p_patch->>'consumable')::boolean;
  end if;$f$, chr(13), ''), replace($r$    i.is_consumable := (p_patch->>'consumable')::boolean;
  elsif p_patch ? 'category' and v_mgr and lower(btrim(i.category)) in ('kitchen utensils', 'appliances') then
    -- s132: a move into a lasting group (no consumable sent) makes the item lasting; only for manage_inventory (a cleaner's edit never flips is_consumable, not even through the category)
    i.is_consumable := false;
  end if;$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> '618e3ec14138f9ce05c4c3dc1b1fe7fa' then raise exception 's132: inventory_item_update_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_item_update_v1(p_item_id uuid, p_patch jsonb)
    returns jsonb language plpgsql volatile security definer set search_path = '' as %L$e$, v_new);
end $g$;

-- get_inventory_catalogue_v1: the 30-day usage (sum and number of days) skips an undone usage row (the days count would otherwise count the day of a zeroed row)
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_catalogue_v1(uuid)');
  if v_src is null then raise exception 's132: public.get_inventory_catalogue_v1(uuid) is missing' using errcode = '55000'; end if;
  if md5(v_src) = '2ed1f4a50454e4072409d98ed0eea53c' then raise notice 's132: get_inventory_catalogue_v1 already carries this change'; return; end if;
  if md5(v_src) <> '6832ffc21ce22a01f591cbcf03f42497' then raise exception 's132: get_inventory_catalogue_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$from public.inventory_usage x where x.item_id = i.id and x.session_date >= public.manila_today() - 30$f$, chr(13), ''), replace($r$from public.inventory_usage x where x.item_id = i.id and x.undone_at is null and x.session_date >= public.manila_today() - 30$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> '2ed1f4a50454e4072409d98ed0eea53c' then raise exception 's132: get_inventory_catalogue_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.get_inventory_catalogue_v1(p_property_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
end $g$;

-- get_inventory_item_moves_v1: the item's usage rows of the last 30 days skip an undone one
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.get_inventory_item_moves_v1(uuid)');
  if v_src is null then raise exception 's132: public.get_inventory_item_moves_v1(uuid) is missing' using errcode = '55000'; end if;
  if md5(v_src) = '865a052a81b49407dcf1b4e5f8f91f4e' then raise notice 's132: get_inventory_item_moves_v1 already carries this change'; return; end if;
  if md5(v_src) <> '84eaa4f00f2e7fcdb2e92a2b13b48f26' then raise exception 's132: get_inventory_item_moves_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$from public.inventory_usage u where u.item_id = i.id and u.session_date >= v_today - 30$f$, chr(13), ''), replace($r$from public.inventory_usage u where u.item_id = i.id and u.undone_at is null and u.session_date >= v_today - 30$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> '865a052a81b49407dcf1b4e5f8f91f4e' then raise exception 's132: get_inventory_item_moves_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.get_inventory_item_moves_v1(p_item_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
end $g$;

-- inventory_item_change_undo_v1: the "used since the add" test of a created item (a usage row after the add) skips a usage row that was undone (undone_at is not null); everything else, the stock movement test included, is unchanged
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_item_change_undo_v1(uuid)');
  if v_src is null then raise exception 's132: public.inventory_item_change_undo_v1(uuid) is missing' using errcode = '55000'; end if;
  if md5(v_src) = 'f513d523af5ef4f99055ca73e789b7ce' then raise notice 's132: inventory_item_change_undo_v1 already carries this change'; return; end if;
  if md5(v_src) <> '86d7879703760fdc90e6b455e33bdacd' then raise exception 's132: inventory_item_change_undo_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$exists (select 1 from public.inventory_usage u where u.item_id = i.id and u.created_at > c.created_at)$f$, chr(13), ''), replace($r$exists (select 1 from public.inventory_usage u where u.item_id = i.id and u.undone_at is null and u.created_at > c.created_at)$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> 'f513d523af5ef4f99055ca73e789b7ce' then raise exception 's132: inventory_item_change_undo_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_item_change_undo_v1(p_change_id uuid)
    returns jsonb language plpgsql volatile security definer set search_path = '' as %L$e$, v_new);
end $g$;

revoke all on function public.s_inventory_staff_movement_v1(uuid, text, numeric, text, text) from public, anon, authenticated, service_role;
revoke all on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) from public, anon, service_role;
grant execute on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) to authenticated;
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;
revoke all on function public.inventory_item_update_v1(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_update_v1(uuid, jsonb) to authenticated;
revoke all on function public.get_inventory_catalogue_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_inventory_catalogue_v1(uuid) to authenticated;
revoke all on function public.get_inventory_item_moves_v1(uuid) from public, anon, service_role;
grant execute on function public.get_inventory_item_moves_v1(uuid) to authenticated;
revoke all on function public.inventory_item_change_undo_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_change_undo_v1(uuid) to authenticated;
-- record_inventory_usage is not replaced; its grants are restated as s122 left them (ML-21)
revoke all on function public.record_inventory_usage(uuid, date, text, text, jsonb) from public, anon;
grant execute on function public.record_inventory_usage(uuid, date, text, text, jsonb) to authenticated, service_role;

-- 6. record_inventory_receipt_v1 gains p_note (9 -> 10 arguments) -------------------------------------------------------------------------------------------------------------------------------------
-- built from the live body: the note goes after the key tag in the purchase notes ("Admin receipt [key:K] note"; the undo and replay lookups only read the prefix and the tag). The 9-argument function is dropped
-- so a call with 9 arguments cannot be ambiguous.
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)');
  if v_src is null then
    if to_regprocedure('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid,text)') is not null then raise notice 's132: record_inventory_receipt_v1 already has p_note'; return; end if;
    raise exception 's132: public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid) is missing' using errcode = '55000';
  end if;
  if md5(v_src) <> '549d602feb38ab8f0ab0a7bd8fb95ab3' then raise exception 's132: record_inventory_receipt_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$'Admin receipt [key:' || p_idempotency_key || ']'$f$, chr(13), ''), replace($r$'Admin receipt [key:' || p_idempotency_key || ']' || coalesce(' ' || left(nullif(btrim(translate(p_note, '[]', '()')), ''), 500), '')$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> 'd190f6b6051be034e9e9babb99cbbf56' then raise exception 's132: record_inventory_receipt_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.record_inventory_receipt_v1(p_item_id uuid, p_packs numeric, p_unit_cost numeric, p_supplier text, p_purchased_at date, p_receipt_path text, p_shopping_list_id uuid, p_idempotency_key text, p_supplier_id uuid default null, p_note text default null)
    returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
drop function if exists public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid);
revoke all on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid, text) from public, anon, service_role;
grant execute on function public.record_inventory_receipt_v1(uuid, numeric, numeric, text, date, text, uuid, text, uuid, text) to authenticated;

-- 7. inventory_receipt_manual_v1 gains the total paid, the receipt photo and a note (4 -> 7 arguments) ----------------------------------------------------------------------------------------------------
-- the staff supply entry: still no finance write; the total goes to the draft's existing total column, the photo to receipt_path (so the purchase rows carry it), the note to the new note column; the owner/admin task says
-- what was paid and that a receipt is attached.
create or replace function public.inventory_receipt_manual_v1(p_lines jsonb, p_purchased_on date default null, p_vendor text default null, p_idempotency_key text default null, p_total_paid numeric default null, p_receipt_path text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_prop uuid; v_id uuid; v_lines jsonb; v_conv jsonb; v_res jsonb; v_vendor text := nullif(btrim(coalesce(p_vendor, '')), ''); v_old public.inventory_receipt_drafts%rowtype;
  v_path text := nullif(btrim(coalesce(p_receipt_path, '')), ''); v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 500);
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select x.id into v_prop from public.properties x where public.current_staff_authorized('report_supply', x.id)
   order by exists (select 1 from public.staff_property_access a where a.user_id = v_uid and a.property_id = x.id) desc, (x.id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid) desc, x.id limit 1;
  if v_prop is null then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if p_idempotency_key is not null and char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters';
  end if;
  if v_vendor is not null and char_length(v_vendor) > 200 then raise exception using errcode = '22023', message = 'vendor is too long'; end if;
  if p_total_paid is not null and (p_total_paid < 0 or p_total_paid >= 100000000) then raise exception using errcode = '22023', message = 'total paid must be 0 or more'; end if;
  if v_path is not null and (char_length(v_path) > 500 or v_path like '%..%') then raise exception using errcode = '22023', message = 'receipt path is not valid'; end if;
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
  insert into public.inventory_receipt_drafts(property_id, created_by, receipt_path, vendor, purchased_on, total, note, lines, status)
  values (v_prop, v_uid, v_path, v_vendor, p_purchased_on, round(p_total_paid, 2), v_note, v_lines, 'draft') returning id into v_id;
  v_res := public.s_inventory_receipt_confirm_core_v1(v_id, v_conv, p_purchased_on, p_idempotency_key, true);
  if coalesce((v_res ->> 'ok')::boolean, false) is not true then
    update public.inventory_receipt_drafts set status = 'cancelled' where id = v_id;
  elsif v_path is not null or p_total_paid is not null or v_note is not null then
    -- s132: the owner/admin task says what was paid and that a receipt is attached (no finance write)
    update public.follow_up_tasks t
       set title = left(case when v_path is not null then replace(t.title, 'without a receipt', 'with a receipt photo') else t.title end, 200),
           detail = 'Staff added ' || coalesce(v_res ->> 'purchase_count', '0') || ' supply item(s) by hand, ' || case when v_path is not null then 'with a receipt photo' else 'with no receipt photo' end
                    || coalesce('. Paid PHP ' || to_char(p_total_paid, 'FM99999999990.00'), '') || coalesce('. Note: ' || public.staff_redact_v1(v_note), '') || '. Check the stock in Inventory.',
           updated_at = now()
     where t.source_kind = 'receipt_review' and t.source_ref = v_id::text;
  end if;
  return v_res;
end;
$$;
drop function if exists public.inventory_receipt_manual_v1(jsonb, date, text, text);
revoke all on function public.inventory_receipt_manual_v1(jsonb, date, text, text, numeric, text, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_receipt_manual_v1(jsonb, date, text, text, numeric, text, text) to authenticated;

-- 8. record_linen_stains_v1 gains p_photo_path and a laundry gate (5 -> 6 arguments) ----------------------------------------------------------------------------------------------------------------------
-- rows gain optional reason ('stained' | 'damaged') and note; the rows fingerprint stays item / outcome / quantity; a report that was undone no longer counts toward the open task.
create or replace function public.record_linen_stains_v1(p_property uuid, p_session_date date, p_logged_by text, p_idempotency_key text, p_rows jsonb, p_photo_path text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_today date := public.manila_today(); v_who text; v_row jsonb; v_no integer := 0;
  v_item uuid; v_qty numeric; v_out text; v_name text; v_ctl boolean; v_before numeric; v_after numeric; v_last numeric;
  v_rid uuid; v_move uuid; v_moves jsonb := '[]'::jsonb; v_tasks jsonb := '[]'::jsonb;
  v_prev public.linen_stain_reports%rowtype; v_reason text; v_rnote text; v_photo text; v_tid uuid; v_gen integer; v_total integer; v_title text; v_hash text;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_property is null or not (public.current_staff_authorized('submit_cleaning', p_property) or public.current_staff_authorized('report_supply', p_property)) then
    raise exception using errcode = '42501', message = 'staff access denied';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters';
  end if;
  if p_session_date is null or p_session_date > v_today + 1 or p_session_date < v_today - 30 then
    raise exception using errcode = '22023', message = 'session date out of range';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) not between 1 and 30 then
    raise exception using errcode = '22023', message = 'rows required (1 to 30)';
  end if;
  v_who := left(nullif(btrim(coalesce(p_logged_by, '')), ''), 80);
  v_photo := nullif(btrim(coalesce(p_photo_path, '')), '');
  if v_photo is not null and (char_length(v_photo) > 500 or v_photo like '%..%') then raise exception using errcode = '22023', message = 'photo path is not valid'; end if;
  -- what was sent, as a fingerprint: item, outcome and quantity per row, sorted, so the same rows in another order are the same send. A malformed row still hashes
  -- (the row loop below refuses it with its own message), so this never fails before the checks do.
  select encode(extensions.digest(coalesce(string_agg(x.k, ',' order by x.k), ''), 'sha256'), 'hex') into v_hash
    from (select lower(coalesce(e.value ->> 'item_id', '')) || ':' || coalesce(e.value ->> 'outcome', '') || ':'
                 || case when jsonb_typeof(e.value -> 'qty') = 'number' then trim_scale((e.value ->> 'qty')::numeric)::text else coalesce(e.value ->> 'qty', '') end as k
            from jsonb_array_elements(p_rows) e) x;

  -- two taps or a retry racing the first call wait here: the second one then sees the first one's rows and replays. Held to the end of the transaction, so the
  -- unique (idempotency_key, row_no) can no longer be hit by a replay (a hash clash between two keys only makes them wait for each other).
  perform pg_advisory_xact_lock(hashtextextended('linen_stains|' || p_idempotency_key, 0));

  -- the same submission sent again (a retry after a lost answer) writes nothing
  select * into v_prev from public.linen_stain_reports where idempotency_key = p_idempotency_key order by row_no limit 1;
  if found then
    if v_prev.reported_by_user_id is distinct from v_uid or v_prev.property_id <> p_property or v_prev.rows_hash is distinct from v_hash then
      raise exception using errcode = '22023', message = 'idempotency_key_reused';
    end if;
    return jsonb_build_object('ok', true, 'replayed', true,
      'rows', (select count(*) from public.linen_stain_reports where idempotency_key = p_idempotency_key));
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_no := v_no + 1;
    v_out := v_row ->> 'outcome';
    if jsonb_typeof(v_row -> 'item_id') is distinct from 'string' or jsonb_typeof(v_row -> 'qty') is distinct from 'number'
       or v_out is null or v_out not in ('cleaned', 'needs_replacing', 'replaced') then
      raise exception using errcode = '22023', message = 'each row needs item_id, a whole qty and an outcome';
    end if;
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty := (v_row ->> 'qty')::numeric;
    v_reason := nullif(v_row ->> 'reason', '');
    if v_reason is not null and v_reason not in ('stained', 'damaged') then raise exception using errcode = '22023', message = 'reason must be stained or damaged'; end if;
    v_rnote := left(nullif(btrim(coalesce(v_row ->> 'note', '')), ''), 500);
    if v_qty <> floor(v_qty) or v_qty < 1 or v_qty > 99 then
      raise exception using errcode = '22023', message = 'qty must be a whole number from 1 to 99';
    end if;

    select i.name, (i.movement_controlled_at is not null), coalesce(i.qty_on_hand, 0) into v_name, v_ctl, v_before
      from public.inventory_items i
     where i.id = v_item and i.property_id = p_property and i.is_active and not i.is_consumable for update;
    if v_name is null then raise exception using errcode = '22023', message = 'unknown linen item'; end if;

    v_after := case when v_out = 'cleaned' then v_before else greatest(0, v_before - v_qty) end;
    v_move := null;
    if v_ctl and v_after <> v_before then
      select m.quantity_after into v_last from public.inventory_stock_movements m where m.item_id = v_item order by m.sequence_no desc limit 1;
      if v_last is distinct from v_before then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
    end if;

    insert into public.linen_stain_reports(property_id, item_id, session_date, qty, outcome, logged_by, reported_by_user_id, idempotency_key, row_no, stock_before, stock_after, rows_hash, reason, note, photo_path)
    values (p_property, v_item, p_session_date, v_qty::integer, v_out, v_who, v_uid, p_idempotency_key, v_no, v_before, v_after, v_hash, v_reason, v_rnote, v_photo)
    returning id into v_rid;

    if v_after <> v_before then
      update public.inventory_items set qty_on_hand = v_after where id = v_item;
      -- inventory_qty_at_v1 rebuilds past stock from these rows, so a back-dated count stays right.
      insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
      values ('inventory_items', v_item, 'linen_stain', jsonb_build_object('qty_on_hand', v_before), jsonb_build_object('qty_on_hand', v_after), coalesce(v_who, v_uid::text, 'staff'));
      if v_ctl then
        insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
        values (v_item, p_property, 'adjustment', v_before, v_after,
                'Linen ' || replace(v_out, '_', ' ') || ' ' || p_session_date::text || coalesce(' by ' || v_who, ''), v_uid,
                left('evt-' || encode(extensions.digest('linen_stain_reports|' || v_rid::text || '|' || v_item::text || '|adjustment', 'sha256'), 'hex'), 80))
        returning id into v_move;
        update public.linen_stain_reports set movement_id = v_move where id = v_rid;
        v_moves := v_moves || to_jsonb(v_move);
      end if;
    end if;

    if v_out = 'needs_replacing' then
      -- one open task per item: add to it, or open generation n+1 when the last one was closed
      select t.id into v_tid from public.follow_up_tasks t
       where t.source_kind = 'linen_replace' and t.property_id = p_property and t.source_ref like v_item::text || ':%' and t.status in ('open', 'in_progress')
       order by t.created_at desc limit 1;
      if v_tid is null then
        select count(*) + 1 into v_gen from public.follow_up_tasks t where t.source_kind = 'linen_replace' and t.source_ref like v_item::text || ':%';
        v_tid := public.system_task_open_v1(p_property, 'linen_replace', v_item::text || ':' || v_gen::text, 'Replace linen', null, 'normal');
      end if;
      update public.linen_stain_reports set task_id = v_tid where id = v_rid;
      select coalesce(sum(r.qty), 0)::integer into v_total from public.linen_stain_reports r where r.task_id = v_tid and r.undone_at is null;
      v_title := 'Replace ' || case when v_total = 1 then '1 ' else v_total::text || ' x ' end || v_name || ', ' || case when v_reason = 'damaged' then 'damaged' else 'stained' end || ' on ' || to_char(p_session_date, 'FMDD Mon');
      update public.follow_up_tasks t
         set title = left(v_title, 200), detail = 'Reported in the cleaning checklist. Buy or replace it, then mark this task done.' || coalesce(' Note: ' || public.staff_redact_v1(v_rnote), '') || case when v_photo is not null then ' A photo was attached.' else '' end, updated_at = now()
       where t.id = v_tid;
      if not v_tasks @> to_jsonb(v_tid) then v_tasks := v_tasks || to_jsonb(v_tid); end if;
    end if;
    v_tid := null;
  end loop;

  return jsonb_build_object('ok', true, 'replayed', false, 'rows', v_no, 'tasks', v_tasks, 'movements', v_moves);
end;
$$;
drop function if exists public.record_linen_stains_v1(uuid, date, text, text, jsonb);
revoke all on function public.record_linen_stains_v1(uuid, date, text, text, jsonb, text) from public, anon, service_role;
grant execute on function public.record_linen_stains_v1(uuid, date, text, text, jsonb, text) to authenticated;
-- F7: the 5-argument function was dropped with its comment; the S120 text comes back unchanged, then the S132 additions
comment on function public.record_linen_stains_v1(uuid, date, text, text, jsonb, text) is
  'S120 (D-374): the checklist linen check. cleaned = audit row; needs_replacing / replaced = stock down (clamp 0, ledger adjustment for a controlled item); needs_replacing also adds to ONE open linen_replace task per item. Key replays write nothing. Needs submit_cleaning. S132 (D-396): p_photo_path added; rows take reason (stained or damaged) and note (the note goes into the task text through staff_redact_v1); report_supply (laundry) is allowed too; an undone report (undo_linen_stain_v1) no longer counts toward its task.';

-- 9. inventory_item_history_v1: every row gains note and source; usage, receipt, damage and linen rows join the movements ---------------------------------------------------------------------------------
-- The vocabulary of a history row {at, kind, before, after, who, note, source[, qty][, fields]} (the client words these; newest first, 10 rows):
--   source 'count'   kind 'counted' (a reconcile movement) | 'telegram_count' (a Telegram count)
--   source 'usage'   kind 'used' (a usage line, qty set; or the movement of a controlled use, before/after set) | an undone usage line is left out, and the undo of a controlled use shows as 'adjusted'
--   source 'receipt' kind 'received' (a stock movement, or a purchase row with qty)
--   source 'damage'  kind 'broken' | 'missing' (a damage report row with qty; undone reports are left out)
--   source 'linen'   kind 'stained' | 'damaged' (a linen report whose outcome is needs_replacing or replaced) | 'cleaned' (outcome cleaned: the stock does not change, before = after); qty; undone reports are left out
--   source 'edit'    kind 'adjusted' (any other stock movement) | 'undo' (the staff app's undo) | 'details' | 'price' | 'photo' (a change row: fields instead of before/after)
-- A damage or linen stock movement is shown by its report row, never twice. F2: who may open the Update sheet is decided in the app; this function only needs read_operations.
create or replace function public.inventory_item_history_v1(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid; v_fin boolean; v_c30 integer; v_c14 integer; v_used numeric; v_changes jsonb; v_last jsonb;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  select count(*)::integer, (count(*) filter (where cs.cleaned_at >= now() - interval '14 days'))::integer into v_c30, v_c14
  from public.cleaning_sessions cs
  where cs.property_id = v_prop and cs.cleaning_type in ('turnover', 'deep_clean') and cs.cleaned_at >= now() - interval '30 days';
  select coalesce(sum(u.used_qty), 0) into v_used from public.inventory_usage u where u.item_id = p_item_id and u.session_date >= public.manila_today() - 30;
  -- S124: movement rows keep their old shape; a change row is {at, kind: details|price|photo, who, fields}. Price amounts only for finance; photo fields are {}.
  -- S132: every row also carries note (the words typed with it; staff_redact_v1 for anyone without finance) and source ('count','usage','receipt','damage','linen','edit'); rows that were not in the list
  -- before (a usage line, a receipt, a damage report, a linen report) join it, each only when no stock movement already shows it; a row of a few kinds carries qty. A damage or linen movement is shown by its report row.
  select coalesce(jsonb_agg((case when x.fields is not null then jsonb_build_object('at', x.ts, 'kind', x.kind, 'who', x.who, 'fields', x.fields)
                                  else jsonb_build_object('at', x.ts, 'kind', x.kind, 'before', x.qb, 'after', x.qa, 'who', x.who) end)
                            || jsonb_build_object('note', case when x.note is null then null when v_fin then x.note else public.staff_redact_v1(x.note) end, 'source', x.src)
                            || case when x.qty is not null then jsonb_build_object('qty', x.qty) else '{}'::jsonb end
                            order by x.ts desc), '[]'::jsonb) into v_changes
  from (
    select y.ts, y.kind, y.qb, y.qa, y.who, y.fields, y.src, y.qty,
           coalesce(y.note,
             case y.mkind
               when 'usage' then (select nullif(btrim(regexp_replace(coalesce(u2.notes, ''), '\s*\[key:[^]]*\]', '', 'g')), '') from public.inventory_usage u2
                                   where u2.item_id = p_item_id and y.mk = left('evt-' || encode(extensions.digest('inventory_usage|' || u2.id::text || '|' || u2.item_id::text || '|usage', 'sha256'), 'hex'), 80) limit 1)
               when 'receipt' then (select public.s_inventory_purchase_note_v1(p2.notes) from public.inventory_purchases p2
                                     where p2.item_id = p_item_id and y.mk = left('evt-' || encode(extensions.digest('inventory_purchases|' || p2.id::text || '|' || p2.item_id::text || '|receipt', 'sha256'), 'hex'), 80) limit 1)
               when 'reconcile' then nullif(btrim(substring(y.rsn from '^Baseline count: (.*)$')), '')
             end) as note
    from (
      select * from (
        select m.created_at as ts,
               case when m.kind = 'adjustment' and m.reason like 'Undo in the staff app%' then 'undo' when m.kind = 'reconcile' then 'counted'
                    when m.kind = 'receipt' then 'received' when m.kind = 'usage' then 'used' else 'adjusted' end as kind,
               m.quantity_before as qb, m.quantity_after as qa,
               (select public.staff_redact_v1(split_part(btrim(coalesce(nullif(btrim(au.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(au.raw_user_meta_data ->> 'display_name'), ''),
                         initcap(replace(split_part(coalesce(au.email, ''), '@', 1), '.', ' ')))), ' ', 1)) from auth.users au where au.id = m.actor_user_id) as who,
               null::jsonb as fields,
               case when m.kind = 'reconcile' then 'count' when m.kind = 'receipt' then 'receipt' when m.kind = 'usage' or m.reason like 'Undo usage%' then 'usage' else 'edit' end as src,
               null::numeric as qty, null::text as note, m.kind as mkind, m.reason as rsn, m.idempotency_key as mk
        from public.inventory_stock_movements m
        where m.item_id = p_item_id
          and not (m.kind = 'adjustment' and (m.reason like 'Damage %' or m.reason like 'Undo damage %' or m.reason like 'Linen %' or m.reason like 'Undo linen %'))
        union all
        select a.created_at, 'telegram_count', (a.before ->> 'qty_on_hand')::numeric, (a.after ->> 'qty_on_hand')::numeric, null::text, null::jsonb, 'count', null::numeric, null::text, null::text, null::text, null::text
        from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = p_item_id and a.action = 'telegram_count'
        union all
        select c.created_at, c.kind, null::numeric, null::numeric, public.s_inventory_actor_name_v1(c.actor),
               case when c.kind = 'details' or (c.kind = 'price' and v_fin)
                    then (select coalesce(jsonb_object_agg(k.key, jsonb_build_object('before', c.before -> k.key, 'after', c.after -> k.key)), '{}'::jsonb) from jsonb_object_keys(c.after) as k(key))
                    else '{}'::jsonb end,
               'edit', null::numeric, null::text, null::text, null::text, null::text
        from public.inventory_item_changes c where c.item_id = p_item_id and c.undone_at is null
        union all
        (select ub.created_at, 'used', null::numeric, null::numeric, public.s_inventory_actor_name_v1(ub.submitted_by_user_id), null::jsonb, 'usage', ub.used_qty,
                nullif(btrim(regexp_replace(coalesce(ub.notes, ''), '\s*\[key:[^]]*\]', '', 'g')), ''), null::text, null::text, null::text
           from public.inventory_usage ub
          where ub.item_id = p_item_id and ub.undone_at is null
            and not exists (select 1 from public.inventory_stock_movements m2 where m2.item_id = ub.item_id
                              and m2.idempotency_key = left('evt-' || encode(extensions.digest('inventory_usage|' || ub.id::text || '|' || ub.item_id::text || '|usage', 'sha256'), 'hex'), 80))
          order by ub.created_at desc limit 10)
        union all
        (select pb.created_at, 'received', null::numeric, null::numeric, null::text, null::jsonb, 'receipt', pb.qty, public.s_inventory_purchase_note_v1(pb.notes), null::text, null::text, null::text
           from public.inventory_purchases pb
          where pb.item_id = p_item_id
            and not exists (select 1 from public.inventory_stock_movements m3 where m3.item_id = pb.item_id
                              and m3.idempotency_key = left('evt-' || encode(extensions.digest('inventory_purchases|' || pb.id::text || '|' || pb.item_id::text || '|receipt', 'sha256'), 'hex'), 80))
          order by pb.created_at desc limit 10)
        union all
        (select r.created_at, e.value ->> 'reason', (e.value ->> 'before')::numeric, (e.value ->> 'after')::numeric, public.s_inventory_actor_name_v1(r.actor_user_id), null::jsonb, 'damage',
                (e.value ->> 'qty')::numeric, coalesce(nullif(e.value ->> 'note', ''), r.note), null::text, null::text, null::text
           from public.inventory_damage_reports r cross join lateral jsonb_array_elements(r.rows) e(value)
          where r.property_id = v_prop and r.undone_at is null and e.value ->> 'item_id' = p_item_id::text
          order by r.created_at desc limit 10)
        union all
        (select l.created_at, case when l.outcome = 'cleaned' then 'cleaned' else coalesce(l.reason, 'stained') end, l.stock_before, l.stock_after, public.s_inventory_actor_name_v1(l.reported_by_user_id), null::jsonb, 'linen', l.qty::numeric, l.note,
                null::text, null::text, null::text
           from public.linen_stain_reports l
          where l.item_id = p_item_id and l.undone_at is null
          order by l.created_at desc limit 10)
      ) u order by u.ts desc limit 10
    ) y
  ) x;
  select jsonb_build_object('at', p.purchased_at, 'qty', p.qty) || case when v_fin then jsonb_build_object('unit_cost', p.unit_cost) else '{}'::jsonb end into v_last
  from public.inventory_purchases p where p.item_id = p_item_id order by p.purchased_at desc, p.created_at desc limit 1;
  return jsonb_build_object('ok', true,
    'usage', jsonb_build_object('cleans_30d', v_c30, 'used_30d', v_used, 'per_clean', case when v_c30 > 0 then round(v_used / v_c30, 2) end, 'cleans_14d', v_c14),
    'changes', v_changes, 'last_bought', v_last);
end;
$$;
revoke all on function public.inventory_item_history_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_history_v1(uuid) to authenticated;

-- 10. grants of the new functions (ML-21): authenticated only -----------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.record_inventory_damage_v1(uuid, jsonb, text, uuid, boolean, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.record_inventory_damage_v1(uuid, jsonb, text, uuid, boolean, text, text, text) to authenticated;
revoke all on function public.undo_inventory_damage_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.undo_inventory_damage_v1(uuid) to authenticated;
revoke all on function public.undo_inventory_usage_v1(text) from public, anon, authenticated, service_role;
grant execute on function public.undo_inventory_usage_v1(text) to authenticated;
revoke all on function public.undo_linen_stain_v1(text) from public, anon, authenticated, service_role;
grant execute on function public.undo_linen_stain_v1(text) to authenticated;

commit;
