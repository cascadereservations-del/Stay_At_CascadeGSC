-- Session 132: release s132_inventory_update_20261202 (D-396). The server side of the inventory Update sheet. Over s131b_followups_20261201 (D-395), which must already be applied.
--
--   NEW   inventory_damage_reports (table, RLS on, no grant), record_inventory_damage_v1 (broken or missing lasting stock: clamp at 0, movement for a controlled item, audit row, shopping-list proposal, ONE
--         follow-up task per report, idempotent on the key), undo_inventory_damage_v1, undo_inventory_usage_v1 (by the usage_key), undo_linen_stain_v1 (by the report key),
--         s_inventory_purchase_note_v1 (internal helper of the history, no grant). Undo window 15 minutes for the person who did it; manage_inventory any time.
--   CHANGED (same signature, grants restated, in place from the live body, the result pinned by md5)
--         s_inventory_staff_movement_v1, reconcile_inventory_baseline_v1, inventory_undo_v1   report_supply (laundry) also counts and undoes a count: one gate line each.
--         inventory_item_update_v1                                                           a category change into Kitchen utensils or Appliances with no consumable sent makes the item lasting.
--   CHANGED (new argument list, the old one dropped so a short call is never ambiguous)
--         record_inventory_receipt_v1   9 -> 10 arguments: p_note (stored after the key tag in the purchase notes).
--         inventory_receipt_manual_v1   4 -> 7 arguments: p_total_paid, p_receipt_path, p_note (stored on the draft row; still no finance write; the owner/admin task says "Paid PHP x" and "receipt photo").
--         record_linen_stains_v1        5 -> 6 arguments: p_photo_path; rows take reason ('stained'|'damaged') and note; report_supply also allowed; an undone report no longer counts toward its task.
--   CHANGED (same signature)
--         inventory_item_history_v1     every row gains note and source; usage, receipt, damage and linen rows join; rows of those kinds carry qty. Existing keys unchanged.
--   COLUMNS  linen_stain_reports.reason / note / photo_path / undone_at, inventory_receipt_drafts.note (all nullable; old rows keep null).
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
    ('public.inventory_item_update_v1(uuid,jsonb)', 'c6ec09668ba7416ababeebe6a225b9d0', '15e88d935d8423692c3baa417f395b5a'),
    ('public.inventory_item_history_v1(uuid)', 'a8669ba0b6ff6654edf352e9b8d98543', '34ead94c48ed4c05ea877603b2a33947')
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
    ('public.record_linen_stains_v1(uuid,date,text,text,jsonb)', '40167053bb97aa54d1cfff4f8dc243fe', 'public.record_linen_stains_v1(uuid,date,text,text,jsonb,text)', '66890c2410c4d09cde6895b5434a4a0d')
  ) t(sig_old, m_old, sig_new, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig_old);
    select md5(replace(p.prosrc, chr(13), '')) into v2 from pg_proc p where p.oid = to_regprocedure(r.sig_new);
    if not (v = r.m_old and v2 is null) and not (v is null and v2 = r.m_new) then
      raise exception using errcode = '55000', message = 's132: ' || r.sig_old || ' is not the body this release was cut from (md5 ' || coalesce(v, 'null') || ', new signature ' || coalesce(v2, 'absent') || '): re-cut it from the live body';
    end if;
  end loop;
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
    select i.name, i.unit, (i.movement_controlled_at is not null), coalesce(i.qty_on_hand, 0) into v_name, v_unit, v_ctl, v_before
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
    v_lines := v_lines || (trim_scale(v_qty)::text || ' x ' || v_name || ', ' || v_reason || coalesce(': ' || v_rnote, ''));
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
              || coalesce(E'\nNote: ' || v_note, '')
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
-- The stock comes back (a compensating movement for a controlled item, qty_on_hand for the others) and the usage row is deleted. inventory_qty_at_v1 rebuilds past stock from the usage rows, so the
-- deleted row IS the reversal for past counts: the audit row written here has the same quantity before and after (it only marks the key as undone, for already_undone).
create or replace function public.undo_inventory_usage_v1(p_usage_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); u public.inventory_usage%rowtype; v_prop uuid; v_mgr boolean; v_ids uuid[] := '{}'; v_id uuid; v_name text; v_ctl boolean; v_cur numeric; v_last numeric; v_new numeric;
  m public.inventory_stock_movements%rowtype; v_delta numeric; v_restored integer := 0;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_usage_key is null or char_length(p_usage_key) not between 1 and 160 then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  perform pg_advisory_xact_lock(hashtextextended('inventory_usage_undo|' || p_usage_key, 0));
  select coalesce(array_agg(x.id order by x.created_at, x.id), '{}') into v_ids from public.inventory_usage x where position('[key:' || p_usage_key || ']' in coalesce(x.notes, '')) > 0;
  if cardinality(v_ids) = 0 then
    if exists (select 1 from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.action = 'usage_undo' and a.after ->> 'usage_key' = p_usage_key) then
      return jsonb_build_object('ok', false, 'reason', 'already_undone');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- 1. check every row before anything is written
  foreach v_id in array v_ids loop
    select * into u from public.inventory_usage where id = v_id;
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
    select i.name, (i.movement_controlled_at is not null), coalesce(i.qty_on_hand, 0), i.property_id into v_name, v_ctl, v_cur, v_prop
      from public.inventory_items i where i.id = u.item_id for update;
    if v_ctl then
      -- the movement record_inventory_usage wrote for this row (none when the stock did not change): its quantity comes back as one adjustment
      select * into m from public.inventory_stock_movements x where x.item_id = u.item_id
         and x.idempotency_key = left('evt-' || encode(extensions.digest('inventory_usage|' || u.id::text || '|' || u.item_id::text || '|usage', 'sha256'), 'hex'), 80);
      if found then
        v_delta := m.quantity_before - m.quantity_after;
        select x.quantity_after into v_last from public.inventory_stock_movements x where x.item_id = u.item_id order by x.sequence_no desc limit 1;
        if v_last is distinct from v_cur then raise exception using errcode = '22023', message = 'stock reconciliation required for ' || v_name; end if;
        v_new := v_cur + v_delta;
        insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
        values (u.item_id, v_prop, 'adjustment', v_cur, v_new, 'Undo usage ' || u.session_date::text, v_uid,
                left('evt-' || encode(extensions.digest('inventory_usage|' || u.id::text || '|' || u.item_id::text || '|undo', 'sha256'), 'hex'), 80));
        update public.inventory_items set qty_on_hand = v_new where id = u.item_id;
        v_cur := v_new;
      end if;
    else
      v_new := v_cur + u.used_qty;
      update public.inventory_items set qty_on_hand = v_new where id = u.item_id;
      v_cur := v_new;
    end if;
    insert into public.inventory_audit_log(entity_type, entity_id, action, before, after, actor)
    values ('inventory_items', u.item_id, 'usage_undo', jsonb_build_object('qty_on_hand', v_cur), jsonb_build_object('qty_on_hand', v_cur, 'usage_key', p_usage_key), v_uid::text);
    delete from public.inventory_usage where id = u.id;
    v_restored := v_restored + 1;
  end loop;
  return jsonb_build_object('ok', true, 'restored', v_restored);
end;
$$;

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

-- inventory_item_update_v1: a category change into Kitchen utensils or Appliances with no consumable sent makes the item lasting
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_item_update_v1(uuid,jsonb)');
  if v_src is null then raise exception 's132: public.inventory_item_update_v1(uuid,jsonb) is missing' using errcode = '55000'; end if;
  if md5(v_src) = '15e88d935d8423692c3baa417f395b5a' then raise notice 's132: inventory_item_update_v1 already carries this change'; return; end if;
  if md5(v_src) <> 'c6ec09668ba7416ababeebe6a225b9d0' then raise exception 's132: inventory_item_update_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$    i.is_consumable := (p_patch->>'consumable')::boolean;
  end if;$f$, chr(13), ''), replace($r$    i.is_consumable := (p_patch->>'consumable')::boolean;
  elsif p_patch ? 'category' and lower(btrim(i.category)) in ('kitchen utensils', 'appliances') then
    -- s132: a move into a lasting group (no consumable sent) makes the item lasting
    i.is_consumable := false;
  end if;$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> '15e88d935d8423692c3baa417f395b5a' then raise exception 's132: inventory_item_update_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_item_update_v1(p_item_id uuid, p_patch jsonb)
    returns jsonb language plpgsql volatile security definer set search_path = '' as %L$e$, v_new);
end $g$;

revoke all on function public.s_inventory_staff_movement_v1(uuid, text, numeric, text, text) from public, anon, authenticated, service_role;
revoke all on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) from public, anon, service_role;
grant execute on function public.reconcile_inventory_baseline_v1(uuid, numeric, text, text) to authenticated;
revoke all on function public.inventory_undo_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.inventory_undo_v1(uuid, uuid) to authenticated;
revoke all on function public.inventory_item_update_v1(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_update_v1(uuid, jsonb) to authenticated;

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
         set title = left(v_title, 200), detail = 'Reported in the cleaning checklist. Buy or replace it, then mark this task done.' || coalesce(' Note: ' || v_rnote, '') || case when v_photo is not null then ' A photo was attached.' else '' end, updated_at = now()
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

-- 9. inventory_item_history_v1: every row gains note and source; usage, receipt, damage and linen rows join the movements ---------------------------------------------------------------------------------
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
          where ub.item_id = p_item_id
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
        (select l.created_at, coalesce(l.reason, 'stained'), l.stock_before, l.stock_after, public.s_inventory_actor_name_v1(l.reported_by_user_id), null::jsonb, 'linen', l.qty::numeric, l.note,
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
