-- 20261120000002_s120_linen_stains.sql
-- Session 120, lane R (SQL): release s120_linen_stains_20261120 (D-374). The checklist's linen check asks which piece is stained and what happened to it.
--
--   record_linen_stains_v1(p_property uuid, p_session_date date, p_logged_by text, p_idempotency_key text, p_rows jsonb) returns jsonb
--     authenticated only. Gate: submit_cleaning on the property (cleaner, inspector, owner, admin), else 42501 'staff access denied'. laundry has no submit_cleaning.
--     rows: [{item_id, qty (whole number 1..99), outcome: 'cleaned' | 'needs_replacing' | 'replaced'}], 1 to 30 rows. The item must be active, on the property and
--     NOT consumable (22023 'unknown linen item' otherwise). One key per submission (16 to 160 characters); the same key from the same person replays: nothing is written twice
--     and the result carries replayed true. The same key from anyone else, or the same key with different rows, is 22023 'idempotency_key_reused'.
--     "Same rows" is a fingerprint (sha256 over the rows sorted by item, outcome and quantity, so the order does not matter) stored on every report row as rows_hash.
--     cleaned          audit row only. The piece is back in use, stock does not change.
--     needs_replacing  audit row, stock goes down by qty (clamped at 0, a cleaner is never refused for a low shelf) and ONE open follow-up task per item adds the quantity up.
--     replaced         audit row and the same stock decrease, no task (the replacement is already in place).
--     A movement-controlled item also gets its ledger movement (kind 'adjustment', not 'usage': this is not consumption, and the usage learning must not read it), written
--     with the same invariant record_inventory_usage keeps: the ledger must agree with the shelf first (22023 'stock reconciliation required for <item>').
--     0 of 78 items are movement-controlled in production on 2026-11-18, so that refusal is a corner that cannot fire today.
--   public.linen_stain_reports   the audit table. RLS on, no grant to any API role (read it as the owner role or add a reviewed read model later).
--
-- WHY NOT inventory_usage: its readers (KPI usage cost, the supply log of a clean) treat every row as consumption of a consumable. A towel
-- that left the shelf is a loss, not a use. Nothing here writes inventory_usage, inventory_purchases or any finance table, so those readers are untouched.
--
-- HOW THE TASK CLOSES: system_task_open_v1 keys one task per (kind 'linen_replace', ref '<item id>:<generation>'). While one is open, later needs_replacing rows for that item
-- add to it and rewrite the title ("Replace 3 x Bath Towel, stained on 20 Nov"). A person closes it (mark done) once the replacement is bought; the next stain then opens
-- generation n+1. No sweeper closes it: none of the s102/s104 sweeps or the s117 system_tasks_expire_v1 know the kind, and a missing towel does not fix itself.
-- shortcut: no automatic close when stock is bought back, upgrade if tasks pile up unclosed.
--
-- Linen membership is decided in the checklist from data (non-consumable, active; names read live 2026-11-18). The function does not list items, the checklist reads
-- inventory_items through the existing column grant (id, name, category, is_consumable, is_active are granted to authenticated since s84).
--
-- Additive: one table, one function. Rollback: supabase/rollbacks/20261120_s120_linen_stains.sql (drops both; the audit rows go with the table; the stock, the tasks and the inventory_audit_log rows they wrote stay).

begin;

create table public.linen_stain_reports (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  item_id uuid not null references public.inventory_items(id) on delete restrict,
  session_date date not null,
  qty integer not null check (qty between 1 and 99),
  outcome text not null check (outcome in ('cleaned', 'needs_replacing', 'replaced')),
  logged_by text check (logged_by is null or char_length(logged_by) <= 80),
  reported_by_user_id uuid references auth.users(id) on delete set null,
  idempotency_key text not null check (char_length(idempotency_key) between 16 and 160),
  row_no integer not null check (row_no >= 1),
  rows_hash text not null check (char_length(rows_hash) = 64),
  stock_before numeric,
  stock_after numeric,
  task_id uuid references public.follow_up_tasks(id) on delete set null,
  movement_id uuid references public.inventory_stock_movements(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint linen_stain_reports_key_row unique (idempotency_key, row_no)
);
create index linen_stain_reports_item_idx on public.linen_stain_reports (item_id, created_at);
create index linen_stain_reports_task_idx on public.linen_stain_reports (task_id) where task_id is not null;
alter table public.linen_stain_reports enable row level security;
revoke all on table public.linen_stain_reports from public, anon, authenticated, service_role;
comment on table public.linen_stain_reports is 'S120 (D-374): one row per stained linen piece the cleaner reported in the checklist, with the stock it changed. Written only by record_linen_stains_v1; no API grant.';

create or replace function public.record_linen_stains_v1(p_property uuid, p_session_date date, p_logged_by text, p_idempotency_key text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_today date := public.manila_today(); v_who text; v_row jsonb; v_no integer := 0;
  v_item uuid; v_qty numeric; v_out text; v_name text; v_ctl boolean; v_before numeric; v_after numeric; v_last numeric;
  v_rid uuid; v_move uuid; v_moves jsonb := '[]'::jsonb; v_tasks jsonb := '[]'::jsonb;
  v_prev public.linen_stain_reports%rowtype; v_tid uuid; v_gen integer; v_total integer; v_title text; v_hash text;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_property is null or not public.current_staff_authorized('submit_cleaning', p_property) then
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

    insert into public.linen_stain_reports(property_id, item_id, session_date, qty, outcome, logged_by, reported_by_user_id, idempotency_key, row_no, stock_before, stock_after, rows_hash)
    values (p_property, v_item, p_session_date, v_qty::integer, v_out, v_who, v_uid, p_idempotency_key, v_no, v_before, v_after, v_hash)
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
      select coalesce(sum(r.qty), 0)::integer into v_total from public.linen_stain_reports r where r.task_id = v_tid;
      v_title := 'Replace ' || case when v_total = 1 then '1 ' else v_total::text || ' x ' end || v_name || ', stained on ' || to_char(p_session_date, 'FMDD Mon');
      update public.follow_up_tasks t
         set title = left(v_title, 200), detail = 'Reported in the cleaning checklist. Buy or replace it, then mark this task done.', updated_at = now()
       where t.id = v_tid;
      if not v_tasks @> to_jsonb(v_tid) then v_tasks := v_tasks || to_jsonb(v_tid); end if;
    end if;
    v_tid := null;
  end loop;

  return jsonb_build_object('ok', true, 'replayed', false, 'rows', v_no, 'tasks', v_tasks, 'movements', v_moves);
end;
$$;
revoke all on function public.record_linen_stains_v1(uuid, date, text, text, jsonb) from public, anon, service_role;
grant execute on function public.record_linen_stains_v1(uuid, date, text, text, jsonb) to authenticated;
comment on function public.record_linen_stains_v1(uuid, date, text, text, jsonb) is
  'S120 (D-374): the checklist linen check. cleaned = audit row; needs_replacing / replaced = stock down (clamp 0, ledger adjustment for a controlled item); needs_replacing also adds to ONE open linen_replace task per item. Key replays write nothing. Needs submit_cleaning.';

commit;
