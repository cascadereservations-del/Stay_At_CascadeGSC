-- Admin CRUD with undo, one audit surface, meter review and health checks
-- (admin session 12, items 3, 5, 6; Lloyd 2026-09-14).
--
-- Every row a staff member writes from the admin must show in Settings → Audit
-- history and be undoable. Rather than teaching each RPC to audit, one row-level
-- trigger records before/after for the six tables the admin edits directly or
-- through v1 RPCs; the reason and the action label travel in transaction-local
-- settings (cascade.audit_reason, cascade.audit_action, cascade.audit_undo_of)
-- so existing RPC signatures stay unchanged. Undo restores the recorded
-- before-state through jsonb_populate_record (never a delete); undoing a create
-- applies that table's soft delete. Tables with their own history
-- (booking_lifecycle_events, inventory_stock_movements, acct_journals,
-- guest_profile_history, readiness/evidence reviews, staff_access_audit) are
-- read by the feed, not duplicated.
--
-- transactions gains a third txn_type, 'drawing' (owner transfers out). Every
-- existing reader filters on income or expense explicitly, so drawings are
-- excluded from revenue and from expenses everywhere until a screen asks.
--
-- Additive: one constraint widened, two tables, one trigger function on six
-- tables, eight functions. Nothing dropped, no data changed.
-- Rollback: supabase/rollbacks/20260914_admin_crud_audit_v1.sql

-- ---------------------------------------------------------------------------
-- 1. Audit log
-- ---------------------------------------------------------------------------
create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  entity_table text not null,
  entity_id uuid not null,
  action text not null check (action in ('insert','update','soft_delete','undo')),
  before_state jsonb,
  after_state jsonb,
  reason text,
  actor_user_id uuid,
  undo_of uuid references public.admin_audit_log(id),
  created_at timestamptz not null default now()
);
create index if not exists admin_audit_log_entity_idx on public.admin_audit_log (entity_table, entity_id, created_at desc);
create index if not exists admin_audit_log_property_idx on public.admin_audit_log (property_id, created_at desc);
alter table public.admin_audit_log enable row level security;
grant select on public.admin_audit_log to authenticated;
drop policy if exists admin_audit_log_staff_read on public.admin_audit_log;
create policy admin_audit_log_staff_read on public.admin_audit_log for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id)
         and (entity_table <> 'transactions' or public.current_staff_authorized('read_finance', property_id)));
comment on table public.admin_audit_log is 'Before/after of every admin-side row write on the audited tables. Written only by admin_audit_row_v1(); undo_of links an undo to what it reverted.';

create or replace function public.admin_audit_row_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_after jsonb; v_action text; v_undo uuid; v_prop uuid;
begin
  if tg_op = 'UPDATE' then
    v_before := to_jsonb(old) - 'updated_at' - 'version';
    v_after := to_jsonb(new) - 'updated_at' - 'version';
    if v_before = v_after then return null; end if;
    v_before := to_jsonb(old); v_after := to_jsonb(new);
  else
    v_before := null; v_after := to_jsonb(new);
  end if;
  v_action := nullif(current_setting('cascade.audit_action', true), '');
  if v_action is null or v_action not in ('soft_delete','undo') then v_action := case when tg_op = 'INSERT' then 'insert' else 'update' end; end if;
  v_undo := nullif(current_setting('cascade.audit_undo_of', true), '')::uuid;
  v_prop := (v_after->>'property_id')::uuid;
  if v_prop is null then return null; end if;
  insert into public.admin_audit_log(property_id, entity_table, entity_id, action, before_state, after_state, reason, actor_user_id, undo_of)
  values (v_prop, tg_table_name, (v_after->>'id')::uuid, v_action, v_before, v_after, nullif(current_setting('cascade.audit_reason', true), ''), auth.uid(), v_undo);
  return null;
end;
$$;
revoke all on function public.admin_audit_row_v1() from public, anon, authenticated, service_role;

do $$
declare t text;
begin
  foreach t in array array['transactions','work_orders','follow_up_tasks','ops_notices','inventory_shopping_list','meter_readings'] loop
    execute format('drop trigger if exists admin_audit_row on public.%I', t);
    execute format('create trigger admin_audit_row after insert or update on public.%I for each row execute function public.admin_audit_row_v1()', t);
  end loop;
end $$;

-- Transaction-local audit context for the RPCs below and for reviewed SQL.
create or replace function public.admin_audit_context_v1(p_reason text, p_action text default null, p_undo_of uuid default null)
returns void language sql volatile set search_path = '' as $$
  select set_config('cascade.audit_reason', coalesce(p_reason, ''), true),
         set_config('cascade.audit_action', coalesce(p_action, ''), true),
         set_config('cascade.audit_undo_of', coalesce(p_undo_of::text, ''), true);
$$;
revoke all on function public.admin_audit_context_v1(text, text, uuid) from public, anon, service_role;
grant execute on function public.admin_audit_context_v1(text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Drawings: owner transfers out are neither income nor expense.
-- ---------------------------------------------------------------------------
alter table public.transactions drop constraint if exists transactions_txn_type_check;
alter table public.transactions add constraint transactions_txn_type_check check (txn_type in ('income','expense','drawing'));
comment on column public.transactions.txn_type is 'income | expense | drawing. Drawings are owner transfers out of the business; every revenue and expense reader filters on the first two explicitly.';

-- ---------------------------------------------------------------------------
-- 3. Which capability edits which table, and how each table soft-deletes.
-- ---------------------------------------------------------------------------
create or replace function public.admin_table_action_v1(p_table text)
returns text language sql immutable set search_path = '' as $$
  select case p_table
    when 'transactions' then 'approve_payment'
    when 'work_orders' then 'manage_maintenance'
    when 'follow_up_tasks' then 'manage_operations'
    when 'ops_notices' then 'manage_operations'
    when 'inventory_shopping_list' then 'manage_inventory'
    when 'meter_readings' then 'inspect_cleaning'
  end;
$$;
revoke all on function public.admin_table_action_v1(text) from public, anon, service_role;
grant execute on function public.admin_table_action_v1(text) to authenticated;

create or replace function public.admin_soft_delete_v1(p_table text, p_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_action text; v_note text := btrim(coalesce(p_reason, ''));
begin
  v_action := public.admin_table_action_v1(p_table);
  if v_action is null or p_table = 'meter_readings' then raise exception using errcode = '22023', message = 'this record kind cannot be deleted'; end if;
  if char_length(v_note) < 3 then raise exception using errcode = '22023', message = 'a reason is required'; end if;
  execute format('select property_id from public.%I where id = $1', p_table) into v_prop using p_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'record not found'; end if;
  perform public.admin_require(v_action, v_prop);
  perform public.admin_audit_context_v1(v_note, 'soft_delete', null);
  case p_table
    when 'transactions' then update public.transactions set status = 'void', notes = concat_ws(' ', notes, '[voided: ' || v_note || ']'), updated_at = now() where id = p_id and status <> 'void';
    when 'work_orders' then update public.work_orders set status = 'cancelled', resolution = coalesce(resolution, v_note), updated_at = now(), version = version + 1 where id = p_id and status <> 'cancelled';
    when 'follow_up_tasks' then update public.follow_up_tasks set status = 'cancelled', completion_note = coalesce(completion_note, v_note), updated_at = now(), version = version + 1 where id = p_id and status <> 'cancelled';
    when 'ops_notices' then update public.ops_notices set is_active = false, updated_at = now() where id = p_id and is_active;
    when 'inventory_shopping_list' then update public.inventory_shopping_list set status = 'cancelled', approval_note = coalesce(approval_note, v_note), updated_at = now(), version = version + 1 where id = p_id and status not in ('cancelled','received');
  end case;
  if not found then raise exception using errcode = '22023', message = 'record is already deleted or cannot be deleted in its current state'; end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'auditId', (select id from public.admin_audit_log where entity_table = p_table and entity_id = p_id order by created_at desc limit 1));
end;
$$;
revoke all on function public.admin_soft_delete_v1(text, uuid, text) from public, anon, service_role;
grant execute on function public.admin_soft_delete_v1(text, uuid, text) to authenticated;

-- Undo: restore the before-state of an update or soft delete; for an insert,
-- apply the soft delete. Generated columns, ids, keys and timestamps are never
-- written back; version is bumped so a stale editor still loses.
create or replace function public.admin_undo_v1(p_audit_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.admin_audit_log%rowtype; v_cols text; v_action text; v_note text := btrim(coalesce(p_reason, ''));
begin
  select * into a from public.admin_audit_log where id = p_audit_id;
  if not found then raise exception using errcode = 'P0002', message = 'audit row not found'; end if;
  v_action := public.admin_table_action_v1(a.entity_table);
  perform public.admin_require(v_action, a.property_id);
  if char_length(v_note) < 3 then v_note := 'undo'; end if;
  if exists (select 1 from public.admin_audit_log u where u.undo_of = a.id) then raise exception using errcode = '22023', message = 'this change was already undone'; end if;
  if a.action = 'insert' or a.before_state is null then
    return public.admin_soft_delete_v1(a.entity_table, a.entity_id, 'undo of create: ' || v_note);
  end if;
  select string_agg(format('%I = r.%I', c.column_name, c.column_name), ', ')
    into v_cols
  from information_schema.columns c
  join pg_attribute att on att.attrelid = ('public.' || quote_ident(a.entity_table))::regclass and att.attname = c.column_name
  where c.table_schema = 'public' and c.table_name = a.entity_table
    and c.column_name not in ('id','created_at','updated_at','version','idempotency_key','property_id','sequence_no')
    and att.attgenerated = '' and a.before_state ? c.column_name;
  perform public.admin_audit_context_v1(v_note, 'undo', a.id);
  execute format('update public.%I t set %s%s%s from jsonb_populate_record(null::public.%I, $1) r where t.id = $2',
    a.entity_table, v_cols,
    case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = a.entity_table and column_name = 'updated_at') then ', updated_at = now()' else '' end,
    case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = a.entity_table and column_name = 'version') then ', version = t.version + 1' else '' end,
    a.entity_table) using a.before_state, a.entity_id;
  if not found then raise exception using errcode = 'P0002', message = 'record no longer exists'; end if;
  return jsonb_build_object('ok', true, 'id', a.entity_id, 'undoOf', a.id, 'auditId', (select id from public.admin_audit_log where undo_of = a.id order by created_at desc limit 1));
end;
$$;
revoke all on function public.admin_undo_v1(uuid, text) from public, anon, service_role;
grant execute on function public.admin_undo_v1(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Manual ledger rows from the admin (create and edit). Void is the delete.
-- ---------------------------------------------------------------------------
create or replace function public.admin_save_transaction_v1(p_property_id uuid, p_txn jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_row public.transactions%rowtype; v_type text; v_amount numeric; v_date date; v_ref text; v_reason text;
begin
  perform public.admin_require('approve_payment', p_property_id);
  v_id := nullif(p_txn->>'id', '')::uuid;
  v_type := coalesce(p_txn->>'txn_type', 'expense');
  if v_type not in ('income','expense','drawing') then raise exception using errcode = '22023', message = 'txn_type must be income, expense or drawing'; end if;
  v_amount := nullif(p_txn->>'gross_amount', '')::numeric;
  v_date := nullif(p_txn->>'transaction_date', '')::date;
  v_reason := nullif(btrim(coalesce(p_txn->>'reason', '')), '');
  if v_id is null then
    if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
    if v_amount is null or v_amount < 0 or v_date is null then raise exception using errcode = '22023', message = 'amount and date are required'; end if;
    v_ref := coalesce(nullif(p_txn->>'external_ref', ''), 'admin:' || p_idempotency_key);
    select * into v_row from public.transactions where property_id = p_property_id and external_ref = v_ref;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', true); end if;
    perform public.admin_audit_context_v1(coalesce(v_reason, 'created in admin'), null, null);
    insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, or_number, payee_name, notes, external_ref, income_stage, reservation_id, booking_id, logged_by)
    values (p_property_id, v_type, coalesce(nullif(p_txn->>'category', ''), case v_type when 'drawing' then 'owner_drawing' else 'other' end), coalesce(nullif(p_txn->>'status', ''), 'confirmed'), 'manual', v_date, v_amount, 'PHP',
            nullif(p_txn->>'or_number', ''), nullif(p_txn->>'payee_name', ''), nullif(p_txn->>'notes', ''), v_ref, case when v_type = 'income' then 'confirmed' end,
            nullif(p_txn->>'reservation_id', '')::uuid, nullif(p_txn->>'booking_id', '')::uuid, 'admin')
    returning * into v_row;
  else
    select * into v_row from public.transactions where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'transaction not found'; end if;
    if v_row.status = 'void' then raise exception using errcode = '22023', message = 'a void transaction cannot be edited; undo the void first'; end if;
    if v_reason is null then raise exception using errcode = '22023', message = 'a reason is required to edit a ledger row'; end if;
    perform public.admin_audit_context_v1(v_reason, null, null);
    update public.transactions set
      txn_type = case when p_txn ? 'txn_type' then v_type else txn_type end,
      category = coalesce(nullif(p_txn->>'category', ''), category),
      transaction_date = coalesce(v_date, transaction_date),
      gross_amount = coalesce(v_amount, gross_amount),
      or_number = case when p_txn ? 'or_number' then nullif(p_txn->>'or_number', '') else or_number end,
      payee_name = case when p_txn ? 'payee_name' then nullif(p_txn->>'payee_name', '') else payee_name end,
      notes = case when p_txn ? 'notes' then nullif(p_txn->>'notes', '') else notes end,
      reservation_id = case when p_txn ? 'reservation_id' then nullif(p_txn->>'reservation_id', '')::uuid else reservation_id end,
      status = case when p_txn ? 'status' and (p_txn->>'status') in ('confirmed','pending_review') then p_txn->>'status' else status end,
      updated_at = now()
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'auditId', (select id from public.admin_audit_log where entity_table = 'transactions' and entity_id = v_row.id order by created_at desc limit 1));
end;
$$;
revoke all on function public.admin_save_transaction_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_save_transaction_v1(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Meter reading review: a flag with a reason, never an edit of the numbers.
-- ---------------------------------------------------------------------------
create or replace function public.review_meter_reading_v1(p_reading_id uuid, p_flag text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid; v_flag text := nullif(btrim(coalesce(p_flag, '')), '');
begin
  select property_id into v_prop from public.meter_readings where id = p_reading_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'meter reading not found'; end if;
  perform public.admin_require('inspect_cleaning', v_prop);
  if v_flag is not null and v_flag not in ('first_reading','re_entry','misread','duplicate','under_review') then raise exception using errcode = '22023', message = 'unknown meter flag'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception using errcode = '22023', message = 'a reason is required'; end if;
  perform public.admin_audit_context_v1(btrim(p_reason), null, null);
  update public.meter_readings set meter_flag = v_flag, meter_override_note = btrim(p_reason) where id = p_reading_id;
  return jsonb_build_object('ok', true, 'id', p_reading_id, 'flag', v_flag, 'auditId', (select id from public.admin_audit_log where entity_table = 'meter_readings' and entity_id = p_reading_id order by created_at desc limit 1));
end;
$$;
revoke all on function public.review_meter_reading_v1(uuid, text, text) from public, anon, service_role;
grant execute on function public.review_meter_reading_v1(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. One audit feed for Settings → Audit history.
-- ---------------------------------------------------------------------------
create or replace function public.admin_audit_feed_v1(p_property_id uuid, p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fin boolean; v_staff boolean; v_rows jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_staff := public.current_staff_authorized('manage_staff', p_property_id);
  with feed as (
    select a.id, a.created_at at, 'admin' src, a.entity_table, a.entity_id::text entity_id, a.action, a.actor_user_id actor, a.reason, a.before_state before_state, a.after_state after_state,
           (a.action <> 'undo' and not exists (select 1 from public.admin_audit_log u where u.undo_of = a.id)) undoable, a.undo_of
    from public.admin_audit_log a where a.property_id = p_property_id and (v_fin or a.entity_table <> 'transactions')
    union all
    select s.id, s.created_at, 'staff', 'staff_access_profiles', s.target_user_id::text, s.action, s.actor_user_id, s.reason, s.before_state, s.after_state, false, null
    from public.staff_access_audit s where v_staff
    union all
    select e.id, e.created_at, 'booking', 'booking_inquiries', e.booking_id::text, e.event_type, e.actor_user_id, e.reason, e.before_state, e.after_state, false, null
    from public.booking_lifecycle_events e where e.property_id = p_property_id
    union all
    select m.id, m.created_at, 'inventory', 'inventory_items', m.item_id::text, m.kind, m.actor_user_id, m.reason, jsonb_build_object('quantity', m.quantity_before), jsonb_build_object('quantity', m.quantity_after), false, null
    from public.inventory_stock_movements m where m.property_id = p_property_id
    union all
    select j.id, j.posted_at, 'journal', 'acct_journals', j.id::text, case when j.reversal_of is not null then 'reversal' else 'posted' end, j.posted_by, coalesce(j.reversal_reason, j.description), null, jsonb_build_object('journalNo', j.journal_no, 'entryDate', j.entry_date, 'status', j.status), false, null
    from public.acct_journals j where j.property_id = p_property_id and v_fin
    union all
    select r.id, r.reviewed_at, 'readiness', 'cleaning_sessions', r.cleaning_session_id::text, 'readiness_' || r.outcome, r.reviewer_user_id, r.reason, null, jsonb_build_object('forCheckin', r.for_checkin_date), false, null
    from public.readiness_reviews r where r.property_id = p_property_id
    union all
    select v.id, v.reviewed_at, 'evidence', 'cleaning_verification_evidence', v.evidence_id::text, 'evidence_' || v.outcome, v.reviewer_user_id, v.reason, null, null, false, null
    from public.cleaning_verification_reviews v where v.property_id = p_property_id
    union all
    select h.id, h.changed_at, 'guest', 'guests', h.guest_id::text, 'profile_update', h.changed_by, h.reason, h.before_state, h.after_state, false, null
    from public.guest_profile_history h join public.guests g on g.id = h.guest_id where g.property_id = p_property_id
  )
  select coalesce(jsonb_agg(to_jsonb(f) order by f.at desc), '[]'::jsonb) into v_rows
  from (select * from feed order by at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) f;
  return jsonb_build_object('rows', v_rows, 'financeVisible', v_fin, 'staffVisible', v_staff);
end;
$$;
revoke all on function public.admin_audit_feed_v1(uuid, integer) from public, anon, service_role;
grant execute on function public.admin_audit_feed_v1(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Cross-tab health checks, runnable from System health, last run kept.
-- ---------------------------------------------------------------------------
create table if not exists public.admin_health_check_runs (
  property_id uuid not null references public.properties(id),
  check_key text not null,
  label text not null,
  status text not null check (status in ('pass','warn','fail')),
  count integer not null default 0,
  detail jsonb,
  ran_at timestamptz not null default now(),
  ran_by uuid,
  primary key (property_id, check_key)
);
alter table public.admin_health_check_runs enable row level security;
grant select on public.admin_health_check_runs to authenticated;
drop policy if exists admin_health_check_runs_staff_read on public.admin_health_check_runs;
create policy admin_health_check_runs_staff_read on public.admin_health_check_runs for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

create or replace function public.run_health_checks_v1(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_today date; v_fin boolean; r record; v_out jsonb := '[]'::jsonb; v_checks jsonb := '[]'::jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_today := public.manila_today();

  -- Ledger ↔ reservations: every confirmed payout e-mail names its stay.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_rows_linked', 'l', 'Payout e-mails linked to a stay', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'ref', t.external_ref, 'date', t.transaction_date, 'amount', t.gross_amount)) filter (where t.id is not null), '[]'::jsonb))
  from (select * from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null limit 20) t);

  -- Reservations ↔ payouts: every completed stay has a confirmed payout row.
  v_checks := v_checks || (select jsonb_build_object('k', 'completed_stays_paid', 'l', 'Completed stays with a payout row', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', r.confirmation_code, 'guest', r.guest_name, 'checkout', r.checkout_date, 'payout', r.host_payout)) filter (where r.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date < v_today
        and not exists (select 1 from public.transactions t where t.reservation_id = x.id and t.source = 'airbnb_payout_email' and t.status = 'confirmed') limit 20) r);

  -- Payout totals: Σ reservation payout_amount = Σ payout e-mails + Σ Airbnb adjustments.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_totals_agree', 'l', 'Reservation payouts equal payout e-mails plus adjustments', 's', case when abs(d.diff) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
    jsonb_build_object('reservationPayouts', d.res, 'payoutEmails', d.em, 'adjustments', d.adj, 'difference', d.diff))
  from (select res, em, adj, res - em - adj diff from (
    select (select coalesce(sum(payout_amount), 0) from public.airbnb_reservations where property_id = p_property_id and payout_amount is not null) res,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed') em,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb' and txn_type = 'expense' and category = 'airbnb_adjustment' and status = 'confirmed') adj) x) d);

  -- Cleaning log ↔ stays: a checkout in the last 90 days has a cleaning within three days.
  v_checks := v_checks || (select jsonb_build_object('k', 'checkouts_cleaned', 'l', 'Checkouts (90 days) followed by a cleaning', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', s.confirmation_code, 'guest', s.guest_name, 'checkout', s.checkout_date)) filter (where s.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date >= v_today - 90 and x.checkout_date < v_today
        and not exists (select 1 from public.cleaning_sessions c where c.property_id = p_property_id and (c.checkout_date = x.checkout_date or (c.cleaned_at::date between x.checkout_date and x.checkout_date + 3))) limit 20) s);

  -- Cleaning log ↔ ledger: every fee owed is settled by a live transaction.
  if v_fin then
    v_checks := v_checks || (select jsonb_build_object('k', 'cleaner_fees_settled', 'l', 'Cleaning fees settled in the ledger', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('session', c.id, 'guest', c.last_guest_name, 'cleaned', c.cleaned_at::date, 'fee', c.fee_amount)) filter (where c.id is not null), '[]'::jsonb))
    from (select * from public.cleaning_sessions x where x.property_id = p_property_id and coalesce(x.fee_amount, 0) > 0
          and (x.fee_paid_at is null or x.fee_txn_id is null or not exists (select 1 from public.transactions t where t.id = x.fee_txn_id and t.status <> 'void')) limit 20) c);
  end if;

  -- Meter readings: first entries and negative re-entries carry a review flag.
  v_checks := v_checks || (select jsonb_build_object('k', 'meter_readings_reviewed', 'l', 'Odd meter readings reviewed', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'session', m.session_id, 'recorded', m.recorded_at::date, 'electricDelta', m.electric_delta, 'waterDelta', m.water_delta)) filter (where m.id is not null), '[]'::jsonb))
  from (select * from public.meter_readings x where x.property_id = p_property_id and x.meter_flag is null
        and (coalesce(x.electric_prev, 0) = 0 or coalesce(x.water_prev, 0) = 0 or coalesce(x.electric_delta, 0) < 0 or coalesce(x.water_delta, 0) < 0) limit 20) m);

  -- Inventory: ledger-controlled items agree with their last movement; nothing negative.
  v_checks := v_checks || (select jsonb_build_object('k', 'inventory_ledger_consistent', 'l', 'Inventory quantities agree with movements', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('item', i.name, 'onHand', i.qty_on_hand, 'lastMovement', i.last_after)) filter (where i.id is not null), '[]'::jsonb))
  from (select x.id, x.name, x.qty_on_hand, (select quantity_after from public.inventory_stock_movements m where m.item_id = x.id order by sequence_no desc limit 1) last_after
        from public.inventory_items x where x.property_id = p_property_id and x.is_active) i
  where i.qty_on_hand < 0 or (i.last_after is not null and i.last_after <> i.qty_on_hand));

  if v_fin then
    -- Ledger: duplicate live rows (same date, amount, payee, type, source).
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_duplicates', 'l', 'Duplicate ledger rows', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('date', g.transaction_date, 'amount', g.gross_amount, 'payee', g.payee, 'n', g.n)), '[]'::jsonb))
    from (select transaction_date, gross_amount, coalesce(payee_name, '') payee, count(*) n from public.transactions
          where property_id = p_property_id and status <> 'void' and source not in ('airbnb','airbnb_email')
          group by transaction_date, gross_amount, coalesce(payee_name, ''), txn_type, source having count(*) > 1 limit 20) g);

    -- Ledger position: income − expenses − drawings on confirmed, non-mirror rows.
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_position', 'l', 'Cash position: income − expenses − drawings', 's', case when abs(p.net) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
      jsonb_build_object('income', p.inc, 'expenses', p.exp, 'drawings', p.drw, 'net', p.net, 'asOf', v_today))
    from (select inc, exp, drw, inc - exp - drw net from (
      select coalesce(sum(gross_amount) filter (where txn_type = 'income'), 0) inc, coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) exp, coalesce(sum(gross_amount) filter (where txn_type = 'drawing'), 0) drw
      from public.transactions where property_id = p_property_id and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= v_today) x) p);

    -- Journals: every posted journal balances.
    v_checks := v_checks || (select jsonb_build_object('k', 'journals_balanced', 'l', 'Posted journals balance', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('journalNo', j.journal_no, 'debits', j.d, 'credits', j.c)), '[]'::jsonb))
    from (select j.journal_no, sum(l.debit) d, sum(l.credit) c from public.acct_journals j join public.acct_journal_lines l on l.journal_id = j.id
          where j.property_id = p_property_id and j.status = 'posted' group by j.journal_no having sum(l.debit) <> sum(l.credit) limit 20) j);
  end if;

  for r in select e->>'k' k, e->>'l' l, e->>'s' s, (e->>'n')::int n, e->'d' d from jsonb_array_elements(v_checks) e loop
    insert into public.admin_health_check_runs(property_id, check_key, label, status, count, detail, ran_at, ran_by)
    values (p_property_id, r.k, r.l, r.s, r.n, r.d, now(), auth.uid())
    on conflict (property_id, check_key) do update set label = excluded.label, status = excluded.status, count = excluded.count, detail = excluded.detail, ran_at = excluded.ran_at, ran_by = excluded.ran_by;
  end loop;
  select coalesce(jsonb_agg(to_jsonb(h) order by h.check_key), '[]'::jsonb) into v_out from public.admin_health_check_runs h where h.property_id = p_property_id and (v_fin or h.check_key not in ('cleaner_fees_settled','ledger_duplicates','ledger_position','journals_balanced'));
  return jsonb_build_object('ranAt', now(), 'checks', v_out);
end;
$$;
revoke all on function public.run_health_checks_v1(uuid) from public, anon, service_role;
grant execute on function public.run_health_checks_v1(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Forward check.
-- ---------------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_trigger where tgname = 'admin_audit_row' and not tgisinternal;
  if n <> 6 then raise exception 'expected 6 audit triggers, found %', n; end if;
  if not exists (select 1 from pg_constraint where conname = 'transactions_txn_type_check' and pg_get_constraintdef(oid) like '%drawing%') then raise exception 'txn_type check not widened'; end if;
end $$;
