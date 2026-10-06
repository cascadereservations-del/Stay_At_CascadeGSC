-- Session 72, lane L4 (D-301): release d301_pay_rates_tasks_20261006.
-- 1. Pay rates. cleaner_rate_schedule stays the ONE source of the cleaning fee and the transport fee (staff_pay_rate_v1 already reads the
--    row in force on the clean's date for the payment-request RPCs). This release gives the owner/admin a way to change it:
--      admin_pay_rates_v1       read the rate in force today, the history and any rate that starts later (owner/admin).
--      admin_add_pay_rate_v1    ADD a new effective-dated row (owner/admin). Never an update or delete: the table is append-only
--                               (trigger), a new row must start after the latest one, and every insert is audited through
--                               admin_audit_row_v1 with the typed reason as the audit reason.
--    No hard-coded 500/150/1000 is left in these RPCs; the only literals live in the rows themselves.
-- 2. One task list. No second task store: tasks_list_v1 UNIONS follow_up_tasks (manual reminders, guest follow-ups, system tasks),
--    work_orders (cleaning issues, OPS/guest reports, manual work) and open verifier_findings (owner/admin only; they are acknowledged
--    with the existing ack_verifier_finding_v1).
--      tasks_list_v1            owner/admin (manage_operations) see all; any other staff role (read_operations) sees only what is
--                               theirs: assigned to them, or unassigned reminders, work orders and cleaning issues that name no guest.
--                               Staff text goes through staff_redact_v1 (phones, e-mails, money become [hidden]); staff rows carry
--                               no guest id, no booking id and no other staff id (D-289, D-302).
--      task_set_done_v1         done / undo on a follow-up task or work order the caller can see. No gate beyond that (D-302).
--      task_add_reminder_v1     owner/admin add a reminder (title, due date, assignee, note) as a follow_up_tasks row.
--      task_assignees_v1        owner/admin: the staff an assignee dropdown offers.
--      tasks_rows_v1            internal, no grant to any API role.
-- Correcting a rate row: there is no undo. Audit history undo is not available for pay rates. To fix a wrong row, a later migration drops the trigger
-- cleaner_rate_schedule_append_only, changes the row, and recreates the trigger.
-- Expand only: one unique index, two triggers on cleaner_rate_schedule (append-only, audit), eight functions. No data change, no new table, no new
-- telegram_pending kind. Rollback: supabase/rollbacks/20261006_d301_pay_rates_tasks.sql

begin;

-- 1. Pay rates -----------------------------------------------------------------------------------------------------------------

-- One row per property and start date. The four production rows (1900-01-01, 2026-01-02, 2026-05-07, 2026-09-30) already satisfy it.
create unique index if not exists cleaner_rate_schedule_property_from_uq on public.cleaner_rate_schedule(property_id, effective_from);

create or replace function public.cleaner_rate_schedule_append_only() returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = '55000', message = 'pay rates are append-only: add a new effective-dated rate instead of changing history';
end $$;
revoke all on function public.cleaner_rate_schedule_append_only() from public, anon, authenticated, service_role;

drop trigger if exists cleaner_rate_schedule_append_only on public.cleaner_rate_schedule;
create trigger cleaner_rate_schedule_append_only before update or delete on public.cleaner_rate_schedule
  for each row execute function public.cleaner_rate_schedule_append_only();

drop trigger if exists admin_audit_row on public.cleaner_rate_schedule;
create trigger admin_audit_row after insert on public.cleaner_rate_schedule for each row execute function public.admin_audit_row_v1();

create or replace function public.admin_pay_rates_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := public.manila_today(); v_in_force jsonb; v_next jsonb; v_hist jsonb;
begin
  perform public.admin_require('manage_staff', p_property_id);
  select coalesce(jsonb_agg(to_jsonb(r) order by r.effective_from desc), '[]'::jsonb) into v_hist
    from (select id, effective_from, regular_rate, general_rate, transport_rate, note, created_at
            from public.cleaner_rate_schedule where property_id = p_property_id order by effective_from desc limit 50) r;
  select to_jsonb(r) into v_in_force
    from (select id, effective_from, regular_rate, coalesce(general_rate, regular_rate) as general_rate, transport_rate, note, created_at
            from public.cleaner_rate_schedule where property_id = p_property_id and effective_from <= v_today
           order by effective_from desc limit 1) r;
  select to_jsonb(r) into v_next
    from (select id, effective_from, regular_rate, coalesce(general_rate, regular_rate) as general_rate, transport_rate, note, created_at
            from public.cleaner_rate_schedule where property_id = p_property_id and effective_from > v_today
           order by effective_from limit 1) r;
  return jsonb_build_object('ok', true, 'today', v_today, 'in_force', v_in_force, 'next', v_next, 'history', v_hist);
end $$;
revoke all on function public.admin_pay_rates_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_pay_rates_v1(uuid) to authenticated;
comment on function public.admin_pay_rates_v1(uuid) is 'D-301: the cleaning and transport rate in force today, the history and the next rate. Owner/admin only (manage_staff).';

-- p_transport null (or 0) = the base already includes transport, so staff get no transport toggle (the 650 era rule in SPEC-37 3.1).
create or replace function public.admin_add_pay_rate_v1(p_property_id uuid, p_effective_from date, p_regular numeric, p_general numeric, p_transport numeric, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_today date := public.manila_today(); v_note text := btrim(coalesce(p_note, '')); v_transport numeric := nullif(p_transport, 0);
  v_latest date; v_row public.cleaner_rate_schedule%rowtype;
begin
  perform public.admin_require('manage_staff', p_property_id);
  if not exists (select 1 from public.properties where id = p_property_id) then raise exception using errcode = 'P0002', message = 'property not found'; end if;
  if p_effective_from is null then raise exception using errcode = '22023', message = 'a start date is required'; end if;
  if p_regular is null or p_regular < 1 or p_regular > 10000 or p_regular <> round(p_regular, 2) then
    raise exception using errcode = '22023', message = 'the cleaning fee must be between 1 and 10,000'; end if;
  if p_general is null or p_general < 1 or p_general > 10000 or p_general <> round(p_general, 2) then
    raise exception using errcode = '22023', message = 'the deep clean fee must be between 1 and 10,000'; end if;
  if v_transport is not null and (v_transport < 1 or v_transport > 2000 or v_transport <> round(v_transport, 2)) then
    raise exception using errcode = '22023', message = 'the transport fee must be between 1 and 2,000, or empty when the fee already includes transport'; end if;
  if char_length(v_note) < 3 or char_length(v_note) > 500 then raise exception using errcode = '22023', message = 'a note of 3 to 500 characters is required'; end if;
  if p_effective_from > v_today + 366 then raise exception using errcode = '22023', message = 'the start date is more than a year away'; end if;

  perform pg_advisory_xact_lock(hashtext('pay_rate:' || p_property_id::text));
  -- A repeat tap with the same numbers on the same day is a replay, not an error.
  select * into v_row from public.cleaner_rate_schedule where property_id = p_property_id and effective_from = p_effective_from;
  if found then
    if v_row.regular_rate = p_regular and coalesce(v_row.general_rate, v_row.regular_rate) = p_general and v_row.transport_rate is not distinct from v_transport then
      return jsonb_build_object('ok', true, 'id', v_row.id, 'effective_from', v_row.effective_from, 'replayed', true);
    end if;
    raise exception using errcode = '22023', message = 'a rate already starts on that date; history is never changed, pick a later date';
  end if;
  select max(effective_from) into v_latest from public.cleaner_rate_schedule where property_id = p_property_id;
  if v_latest is not null and p_effective_from <= v_latest then
    raise exception using errcode = '22023', message = format('a new rate must start after the latest one (%s)', v_latest);
  end if;

  perform public.admin_audit_context_v1(v_note, null, null);
  insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
  values (p_property_id, p_effective_from, p_regular, p_general, v_transport, v_note) returning * into v_row;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'effective_from', v_row.effective_from, 'regular_rate', v_row.regular_rate,
                            'general_rate', v_row.general_rate, 'transport_rate', v_row.transport_rate, 'replayed', false);
end $$;
revoke all on function public.admin_add_pay_rate_v1(uuid, date, numeric, numeric, numeric, text) from public, anon, service_role;
grant execute on function public.admin_add_pay_rate_v1(uuid, date, numeric, numeric, numeric, text) to authenticated;
comment on function public.admin_add_pay_rate_v1(uuid, date, numeric, numeric, numeric, text) is
  'D-301: ADD an effective-dated cleaning/transport rate. Owner/admin only; append-only; audited with the note as the reason. The staff app and payment requests read the row in force on the clean''s date.';

-- 2. One task list -------------------------------------------------------------------------------------------------------------

-- Internal: every task the caller may see, one row each, in one shape. p_manager = owner/admin (manage_operations).
create or replace function public.tasks_rows_v1(p_property_id uuid, p_uid uuid, p_manager boolean, p_include_done boolean)
returns table (source text, id text, kind text, title text, detail text, priority text, status text, due_at timestamptz, assignee_id uuid,
               assignee_label text, mine boolean, created_at timestamptz, completed_at timestamptz, version integer, blocks_arrival boolean)
language sql stable security definer set search_path = '' as $$
  with names as (
    select p.user_id,
           coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                    nullif(initcap(replace(split_part(u.email, '@', 1), '.', ' ')), ''), 'Staff') as label
      from public.staff_access_profiles p join auth.users u on u.id = p.user_id
  ), src as (
    select 'follow_up_tasks'::text as source, f.id::text as id,
           case when f.guest_id is not null then 'guest_follow_up' when f.source_kind is null or f.source_kind = 'manual' then 'reminder' else 'system' end as kind,
           f.title, f.detail, f.priority, case when f.status in ('open', 'in_progress') then 'open' else 'done' end as status,
           f.due_at, f.assignee_user_id, f.created_at, f.completed_at, f.version, false as blocks_arrival,
           f.guest_id is not null as guesty, (f.source_kind is null or f.source_kind = 'manual') as plain, f.updated_at
      from public.follow_up_tasks f where f.property_id = p_property_id and f.status <> 'cancelled'
    union all
    select 'work_orders', w.id::text,
           case w.source_kind when 'cleaning_issue' then 'cleaning_issue' when 'guest_report' then 'guest_report' else 'work_order' end,
           w.title, w.description, w.priority, case when w.status = 'resolved' then 'done' else 'open' end,
           w.due_at, w.assignee_user_id, w.created_at, w.resolved_at, w.version, w.blocks_arrival,
           w.source_kind = 'guest_report', true, w.updated_at
      from public.work_orders w where w.property_id = p_property_id and w.status <> 'cancelled'
    union all
    select 'verifier_findings', v.key, 'verifier', v.title, null, case v.severity when 'red' then 'high' else 'normal' end,
           case when v.status = 'open' then 'open' else 'done' end,
           null::timestamptz, null::uuid, v.first_seen, v.acknowledged_at, 0, false, false, true, coalesce(v.acknowledged_at, v.first_seen)
      from public.verifier_findings v where p_manager and v.status in ('open', 'acknowledged')
  )
  select s.source, s.id, s.kind,
         case when p_manager then s.title else public.staff_redact_v1(s.title) end,
         case when p_manager then s.detail else public.staff_redact_v1(s.detail) end,
         s.priority, s.status, s.due_at,
         case when p_manager then s.assignee_user_id end,
         case when p_manager then n.label else public.staff_redact_v1(n.label) end,
         s.assignee_user_id is not distinct from p_uid and p_uid is not null,
         s.created_at, s.completed_at, s.version, s.blocks_arrival
    from src s left join names n on n.user_id = s.assignee_user_id
   where (s.status = 'open' or (p_include_done and coalesce(s.completed_at, s.updated_at) > now() - interval '14 days'))
     and (p_manager
          or s.assignee_user_id = p_uid
          or (s.assignee_user_id is null and not s.guesty and s.plain and s.source in ('follow_up_tasks', 'work_orders')));
$$;
revoke all on function public.tasks_rows_v1(uuid, uuid, boolean, boolean) from public, anon, authenticated, service_role;

create or replace function public.tasks_list_v1(p_property_id uuid, p_include_done boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_manager boolean; v_tasks jsonb;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  v_manager := public.current_staff_authorized('manage_operations', p_property_id);
  if not v_manager and not public.current_staff_authorized('read_operations', p_property_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', t.source, 'id', t.id, 'kind', t.kind, 'title', t.title, 'detail', t.detail, 'priority', t.priority, 'status', t.status,
           'due_at', t.due_at, 'assignee_id', t.assignee_id, 'assignee_label', t.assignee_label, 'mine', t.mine,
           'created_at', t.created_at, 'completed_at', t.completed_at, 'version', t.version, 'blocks_arrival', t.blocks_arrival)
         order by (t.status = 'done'), t.due_at nulls last,
                  case t.priority when 'urgent' then 0 when 'high' then 1 when 'normal' then 2 else 3 end, t.created_at), '[]'::jsonb)
    into v_tasks
    -- ponytail: the 200 cap is unordered; the property holds a handful of open tasks. Order before limiting if it ever nears 200.
    from (select * from public.tasks_rows_v1(p_property_id, v_uid, v_manager, coalesce(p_include_done, false)) limit 200) t;
  return jsonb_build_object('ok', true, 'manager', v_manager, 'today', public.manila_today(), 'tasks', v_tasks);
end $$;
revoke all on function public.tasks_list_v1(uuid, boolean) from public, anon, service_role;
grant execute on function public.tasks_list_v1(uuid, boolean) to authenticated;
comment on function public.tasks_list_v1(uuid, boolean) is
  'D-301: ONE view over follow_up_tasks, work_orders and open verifier findings. Owner/admin see all; other staff see only their own and unassigned non-guest tasks, redacted (no guest id, money or contact).';

-- Done / undo. A visible task is a toggleable task: no extra gate (D-302). The note is optional.
create or replace function public.task_set_done_v1(p_property_id uuid, p_source text, p_id uuid, p_done boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_manager boolean; v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_status text;
begin
  if v_uid is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_source not in ('follow_up_tasks', 'work_orders') then raise exception using errcode = '22023', message = 'source must be follow_up_tasks or work_orders'; end if;
  if p_done is null then raise exception using errcode = '22023', message = 'done must be true or false'; end if;
  v_manager := public.current_staff_authorized('manage_operations', p_property_id);
  if not v_manager and not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'tasks denied';
  end if;
  if not exists (select 1 from public.tasks_rows_v1(p_property_id, v_uid, v_manager, true) r where r.source = p_source and r.id = p_id::text) then
    raise exception using errcode = 'P0002', message = 'task not found';
  end if;
  perform public.admin_audit_context_v1(coalesce(left(v_note, 200), case when p_done then 'task marked done' else 'task reopened' end), null, null);
  if p_source = 'follow_up_tasks' then
    if p_done then
      update public.follow_up_tasks set status = 'done', completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, v_uid),
             completion_note = coalesce(left(v_note, 500), completion_note, 'Marked done in the task list'), updated_at = now(), version = version + 1
       where id = p_id and property_id = p_property_id and status in ('open', 'in_progress') returning status into v_status;
    else
      update public.follow_up_tasks set status = 'open', completed_at = null, completed_by = null, completion_note = null, updated_at = now(), version = version + 1
       where id = p_id and property_id = p_property_id and status = 'done' returning status into v_status;
    end if;
  else
    if p_done then
      update public.work_orders set status = 'resolved', resolved_at = coalesce(resolved_at, now()), resolved_by = coalesce(resolved_by, v_uid),
             resolution = coalesce(left(v_note, 500), resolution, 'Marked done in the task list'), updated_at = now(), version = version + 1
       where id = p_id and property_id = p_property_id and status in ('open', 'in_progress', 'awaiting_external') returning status into v_status;
    else
      update public.work_orders set status = 'open', resolved_at = null, resolved_by = null, resolution = null, updated_at = now(), version = version + 1
       where id = p_id and property_id = p_property_id and status = 'resolved' returning status into v_status;
    end if;
  end if;
  -- Already in the asked state (a double tap) is a quiet success, not an error.
  if v_status is null then return jsonb_build_object('ok', true, 'id', p_id, 'changed', false); end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'status', case when p_done then 'done' else 'open' end, 'changed', true);
end $$;
revoke all on function public.task_set_done_v1(uuid, text, uuid, boolean, text) from public, anon, service_role;
grant execute on function public.task_set_done_v1(uuid, text, uuid, boolean, text) to authenticated;
comment on function public.task_set_done_v1(uuid, text, uuid, boolean, text) is 'D-301: done / undo on a follow-up task or work order the caller can see in tasks_list_v1. Audited by the table triggers.';

create or replace function public.task_add_reminder_v1(p_property_id uuid, p_title text, p_due_at timestamptz, p_assignee_user_id uuid, p_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_title text := btrim(coalesce(p_title, '')); v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_id uuid; v_key text;
begin
  perform public.admin_require('manage_operations', p_property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 151 then raise exception using errcode = '22023', message = 'the idempotency key must be 16 to 151 characters'; end if;
  if char_length(v_title) not between 3 and 200 then raise exception using errcode = '22023', message = 'the title must be 3 to 200 characters'; end if;
  if v_note is not null and char_length(v_note) > 1000 then raise exception using errcode = '22023', message = 'the note is at most 1,000 characters'; end if;
  if p_assignee_user_id is not null and not exists (select 1 from public.staff_access_profiles p where p.user_id = p_assignee_user_id and p.disabled_at is null
       and (p.role = 'owner' or exists (select 1 from public.staff_property_access a where a.user_id = p_assignee_user_id and a.property_id = p_property_id))) then
    raise exception using errcode = '22023', message = 'the assignee is not an active staff account';
  end if;
  v_key := 'reminder:' || p_idempotency_key;
  select id into v_id from public.follow_up_tasks where idempotency_key = v_key;
  if found then return jsonb_build_object('ok', true, 'id', v_id, 'replayed', true); end if;
  perform public.admin_audit_context_v1('reminder added', null, null);
  insert into public.follow_up_tasks(property_id, purpose, title, detail, assignee_user_id, due_at, priority, status, source_kind, created_by, idempotency_key)
  values (p_property_id, 'other', v_title, v_note, p_assignee_user_id, p_due_at, 'normal', 'open', 'manual', auth.uid(), v_key)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'replayed', false);
end $$;
revoke all on function public.task_add_reminder_v1(uuid, text, timestamptz, uuid, text, text) from public, anon, service_role;
grant execute on function public.task_add_reminder_v1(uuid, text, timestamptz, uuid, text, text) to authenticated;
comment on function public.task_add_reminder_v1(uuid, text, timestamptz, uuid, text, text) is 'D-301: a manual reminder (title, due date, assignee, note) as a follow_up_tasks row. Owner/admin only.';

create or replace function public.task_assignees_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.admin_require('manage_operations', p_property_id);
  return jsonb_build_object('ok', true, 'staff', (
    select coalesce(jsonb_agg(jsonb_build_object('user_id', p.user_id, 'role', p.role,
             'label', coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                               nullif(initcap(replace(split_part(u.email, '@', 1), '.', ' ')), ''), 'Staff')) order by p.role, u.email, p.user_id), '[]'::jsonb)
      from public.staff_access_profiles p join auth.users u on u.id = p.user_id
     where p.disabled_at is null and u.deleted_at is null
       and (p.role = 'owner' or exists (select 1 from public.staff_property_access a where a.user_id = p.user_id and a.property_id = p_property_id))));
end $$;
revoke all on function public.task_assignees_v1(uuid) from public, anon, service_role;
grant execute on function public.task_assignees_v1(uuid) to authenticated;
comment on function public.task_assignees_v1(uuid) is 'D-301: the active staff an assignee dropdown offers. Owner/admin only.';

commit;
