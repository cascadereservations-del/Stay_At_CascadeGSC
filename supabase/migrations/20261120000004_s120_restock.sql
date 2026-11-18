-- Session 120 (lane S6): release s120_restock_20261120. Server support for the Staff Restock screen (approved mockup docs/s120/mockup-restock-defaults.html, D-376).
--
--   restock_remembered_amounts   the amount a cleaner usually restocks per item, remembered per property (0..99). Closed table: RLS on, no grant to any API role.
--   restock_upkeep_checks        the Yes / No answer to "did you change the dish soap / the dish sponge?" (one row per answer). The migration seeds one changed = true
--                                row per kind and active property, so the count of reports since the last change starts at this release. Closed table.
--   restock_context_v1           what the screen needs in one read: stock of the active consumables, remembered amounts, which upkeep question is due and the tier of
--                                the next arriving guest (returning, regular, vip or null; never a name, id or date).
--   record_restock_v1            one transaction: usage rows (through record_inventory_usage, replay-safe by usage_key), remembered amounts, upkeep answers.
--                                Refuses with short_stock, and writes nothing, when the rows for one item add up to more than the shelf holds.
--   restock_remind_admin_v1      "ask the admin to restock this": one Follow-ups task per item per Manila day through system_task_open_v1.
--
-- Read before writing (production 2026-11-19 and the migrations): record_inventory_usage v3 (20261007112000) checks submit_cleaning, replays by [key:...] in
-- inventory_usage.notes and clamps non-controlled items at zero; system_task_open_v1 (20260923020000) is service_role only, idempotent per (kind, ref), argument
-- order (property, kind, ref, title, detail, priority); current_staff_authorized is the same gate the other staff RPCs use; report_supply was added with the laundry role
-- (20261112000000), so a laundry user may record a restock too. staff_current_next_stays_v1 slot next needs checkin_date > today and misses a guest who arrives today,
-- so it is NOT used: the next stay is read from calendar_events (checkin_date >= Manila today) and resolved through staff_stay_guest_id_v1 like staff_home_v1 does.
--
-- Readers and closers of follow_up_tasks, checked by source_kind: the admin overview and the Follow-ups list read every open task whatever its kind; the s102 / s104
-- sweeps close only guest_details, missed_cleaning, meter_no_photo, meter_estimate_waiting and meter_estimate_settled; the s117 closers touch only power_poster_unread
-- and low_stock; system_task_close_missing_v1 is called per kind by its jobs. restock_reminder is in none of those lists, so it is shown and never closed or dropped
-- by them. An admin closes it by hand in Follow-ups.
--
-- Upkeep is due when at least 3 reports of a turnover kind were cleaned on a Manila date LATER than the session_date of the latest changed = true row of that kind (so it
-- shows on the 4th report). A "No" never resets it, and a property with no changed row yet is never due. Turnover kind means the s110 definition, kept as is:
-- cleaning_type turnover, null (counts as turnover) or deep_clean; fee-only rows (telegram-expense bookManualCleaningFee, submission_id manual-...) are not reports and
-- are not counted. submit-cleaning is the only other writer of cleaning_sessions (checked s120).
-- Why dates and not timestamps: Restock is sent before the cleaning report row is written, so comparing cleaned_at with the Yes row's created_at counted that same report
-- toward the next three. A Yes is stored with the SERVER's Manila date (manila_today(), never the client's p_session_date, so a mistyped future date cannot stop the question
-- and a back-dated draft cannot bring it back early) and only later Manila days count, so a Yes followed by that same day's report leaves the count at 0.
-- The seed rows use the release's Manila date, so reports of the release day do not count either.
--
-- Additive: two new tables, three new functions, rows seeded into the new upkeep table. No existing function or column changes. One grant is restated, not changed:
-- system_task_open_v1 stays service_role only (its own migration says so; stated again here so a restore without ACLs, whose proacl is null, cannot leave it open to
-- signed-in users). The restock functions are SECURITY DEFINER, so they still call it as their owner.
-- Rollback: supabase/rollbacks/20261120_s120_restock.sql (drops the three functions and the two tables; remembered amounts and upkeep answers are lost by design;
-- the system_task_open_v1 grant is left as it is, because reverting it would only reopen a function that is meant to be closed).

begin;

create table if not exists public.restock_remembered_amounts (
  property_id uuid not null references public.properties(id),
  item_id uuid not null references public.inventory_items(id),
  amount integer not null check (amount between 0 and 99),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (property_id, item_id)
);

create table if not exists public.restock_upkeep_checks (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  kind text not null check (kind in ('dish_soap', 'dish_sponge')),
  changed boolean not null,
  session_date date not null,
  logged_by text,
  check_key text not null unique check (char_length(check_key) between 8 and 160),
  created_at timestamptz not null default now()
);
create index if not exists restock_upkeep_checks_kind_idx on public.restock_upkeep_checks(property_id, kind, created_at desc);

alter table public.restock_remembered_amounts enable row level security;
alter table public.restock_upkeep_checks enable row level security;
revoke all on table public.restock_remembered_amounts from public, anon, authenticated, service_role;
revoke all on table public.restock_upkeep_checks from public, anon, authenticated, service_role;

comment on table public.restock_remembered_amounts is 'S120: the amount a cleaner usually restocks per item (0..99). Closed table: read and written only through restock_context_v1 and record_restock_v1.';
comment on table public.restock_upkeep_checks is 'S120: one row per Yes / No answer to "did you change the dish soap / the dish sponge". The seed rows (changed = true, check_key seed:s120:...) start the count at the release. Closed table.';

-- the count starts at the release: one "changed" row per kind and active property
insert into public.restock_upkeep_checks(property_id, kind, changed, session_date, logged_by, check_key)
select p.id, k.kind, true, (now() at time zone 'Asia/Manila')::date, 'release', 'seed:s120:' || k.kind || ':' || p.id::text
  from public.properties p cross join (values ('dish_soap'), ('dish_sponge')) k(kind)
 where p.is_active
on conflict (check_key) do nothing;

-- 1. restock_context_v1 --------------------------------------------------------------------------------------------------------------------------
create or replace function public.restock_context_v1(p_property_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_today date := public.manila_today();
  v_stock jsonb; v_rem jsonb; v_due jsonb; v_tier text := null;
  v_uid text; v_linked uuid; v_in date; v_out date; v_guest uuid;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not (public.current_staff_authorized('submit_cleaning', p_property_id) or public.current_staff_authorized('report_supply', p_property_id)) then
    raise exception using errcode = '42501', message = 'staff access denied';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('item_id', i.id, 'on_hand', coalesce(i.qty_on_hand, 0)) order by i.name, i.id), '[]'::jsonb) into v_stock
    from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.is_consumable;

  select coalesce(jsonb_object_agg(r.item_id::text, r.amount), '{}'::jsonb) into v_rem
    from public.restock_remembered_amounts r join public.inventory_items i on i.id = r.item_id
   where r.property_id = p_property_id and i.property_id = p_property_id and i.is_active and i.is_consumable;

  -- no changed row: max() is null, the comparison is null, the count is 0 and the answer is false
  select jsonb_object_agg(k.kind, (select count(*) from public.cleaning_sessions cs
                                    where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')
                                      and coalesce(cs.submission_id, '') not like 'manual-%'
                                      and (cs.cleaned_at at time zone 'Asia/Manila')::date > (select max(c.session_date) from public.restock_upkeep_checks c
                                                                     where c.property_id = p_property_id and c.kind = k.kind and c.changed)) >= 3)
    into v_due from (values ('dish_soap'), ('dish_sponge')) k(kind);

  -- the next arriving guest: earliest confirmed stay checking in today or later (a same-day arrival counts); only the tier leaves this function
  select e.uid, e.linked_reservation_id, e.checkin_date, e.checkout_date into v_uid, v_linked, v_in, v_out
    from public.calendar_events e
   where e.property_id = p_property_id and e.status = 'confirmed' and e.checkin_date >= v_today
   order by e.checkin_date, e.uid limit 1;
  if v_uid is not null then
    v_guest := public.staff_stay_guest_id_v1(p_property_id, v_uid, v_linked, v_in, v_out);
    if v_guest is not null then
      select g.tier into v_tier from public.guests g where g.id = v_guest and g.property_id = p_property_id;
      if v_tier is not null and v_tier not in ('returning', 'regular', 'vip') then v_tier := null; end if;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'stock', v_stock, 'remembered', v_rem, 'upkeep_due', v_due, 'next_tier', to_jsonb(v_tier));
end;
$function$;

-- 2. record_restock_v1 ---------------------------------------------------------------------------------------------------------------------------
create or replace function public.record_restock_v1(
  p_property_id uuid,
  p_session_date date,
  p_logged_by text,
  p_notes text,
  p_rows jsonb,
  p_remember jsonb,
  p_upkeep jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_all jsonb := '[]'::jsonb; v_rem jsonb := '[]'::jsonb; v_row jsonb; v_item uuid; v_qty numeric; v_key text; v_seen text[] := '{}';
  v_short jsonb; v_res jsonb; v_written integer := 0; v_replayed integer := 0; v_who text;
  v_k text; v_v jsonb; v_amt numeric; v_up jsonb;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not (public.current_staff_authorized('submit_cleaning', p_property_id) or public.current_staff_authorized('report_supply', p_property_id)) then
    raise exception using errcode = '42501', message = 'staff access denied';
  end if;
  if p_session_date is null then raise exception using errcode = '22023', message = 'session_date required'; end if;
  p_rows := coalesce(p_rows, '[]'::jsonb); p_remember := coalesce(p_remember, '{}'::jsonb); p_upkeep := coalesce(p_upkeep, '[]'::jsonb);
  if jsonb_typeof(p_rows) <> 'array' or jsonb_typeof(p_upkeep) <> 'array' or jsonb_typeof(p_remember) <> 'object' then
    raise exception using errcode = '22023', message = 'rows and upkeep are arrays, remember is an object';
  end if;
  v_who := nullif(btrim(coalesce(p_logged_by, '')), '');

  -- validate everything before the first lock or write (a bad input raises and nothing is kept)
  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row) <> 'object' or coalesce(v_row ->> 'item_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       or (case when jsonb_typeof(v_row -> 'used_qty') = 'number' then (v_row ->> 'used_qty')::numeric <= 0 else true end)   -- parentheses: plpgsql ends an IF condition at the first THEN outside brackets
       or char_length(coalesce(v_row ->> 'usage_key', '')) not between 1 and 160 then
      raise exception using errcode = '22023', message = 'each row needs item_id, a positive used_qty and a usage_key of 1 to 160 characters';
    end if;
  end loop;
  for v_k, v_v in select key, value from jsonb_each(p_remember) loop
    if v_k !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or jsonb_typeof(v_v) <> 'number' then
      raise exception using errcode = '22023', message = 'remember is {item_id: whole number 0..99}';
    end if;
    v_amt := (v_v #>> '{}')::numeric;
    if v_amt <> trunc(v_amt) or v_amt < 0 or v_amt > 99 then raise exception using errcode = '22023', message = 'a remembered amount is a whole number from 0 to 99'; end if;
    if not exists (select 1 from public.inventory_items i where i.id = v_k::uuid and i.property_id = p_property_id and i.is_active and i.is_consumable) then
      raise exception using errcode = '22023', message = 'remember: unknown item for property';
    end if;
  end loop;
  for v_up in select value from jsonb_array_elements(p_upkeep) loop
    if jsonb_typeof(v_up) <> 'object' or coalesce(v_up ->> 'kind', '') not in ('dish_soap', 'dish_sponge')
       or jsonb_typeof(v_up -> 'changed') is distinct from 'boolean' or char_length(coalesce(v_up ->> 'check_key', '')) not between 8 and 160 then
      raise exception using errcode = '22023', message = 'each upkeep entry needs kind, changed and a check_key of 8 to 160 characters';
    end if;
  end loop;
  -- a check_key is one answer: reusing it with another property, kind or changed value (stored, or twice in this call) is refused with error check_key_conflict and nothing
  -- is written; the same answer again is a replay
  if exists (select 1 from jsonb_array_elements(p_upkeep) u
              where exists (select 1 from public.restock_upkeep_checks c where c.check_key = u.value ->> 'check_key'
                             and (c.property_id <> p_property_id or c.kind <> u.value ->> 'kind' or c.changed <> (u.value ->> 'changed')::boolean)))
     or (select count(distinct (u.value ->> 'check_key')) <> count(distinct (u.value ->> 'check_key', u.value ->> 'kind', u.value ->> 'changed')) from jsonb_array_elements(p_upkeep) u) then
    return jsonb_build_object('ok', false, 'error', 'check_key_conflict');
  end if;

  -- lock the items in id order, then sort the rows into new and replayed
  perform 1 from public.inventory_items i
   where i.property_id = p_property_id and i.id in (select (r.value ->> 'item_id')::uuid from jsonb_array_elements(p_rows) r) order by i.id for update;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_item := (v_row ->> 'item_id')::uuid; v_qty := (v_row ->> 'used_qty')::numeric; v_key := nullif(v_row ->> 'usage_key', '');
    if not exists (select 1 from public.inventory_items i where i.id = v_item and i.property_id = p_property_id) then
      raise exception using errcode = '22023', message = 'unknown item for property';
    end if;
    if v_key is not null and (v_item::text || ':' || v_key = any (v_seen) or exists (select 1 from public.inventory_usage u where u.item_id = v_item and u.notes like '%[key:' || v_key || ']%')) then
      v_replayed := v_replayed + 1; continue;
    end if;
    if v_key is not null then v_seen := v_seen || (v_item::text || ':' || v_key); end if;
    v_rem := v_rem || jsonb_build_array(v_row);
  end loop;

  -- short stock: one item's rows (a main row and a treat row) are added up before the shelf is compared. An item that is no longer an active consumable has nothing on
  -- the shelf as far as Restock is concerned (on_hand 0): a client with a stale list gets the same short_stock answer, keeps its entries, and nothing is written.
  select coalesce(jsonb_agg(jsonb_build_object('item_id', s.id, 'name', s.name, 'on_hand', s.on_hand, 'asked', s.asked) order by s.name, s.id), '[]'::jsonb) into v_short
    from (select i.id, i.name, case when i.is_active and i.is_consumable then coalesce(i.qty_on_hand, 0) else 0 end as on_hand, sum(r.used_qty) as asked
            from jsonb_to_recordset(v_rem) as r(item_id uuid, used_qty numeric) join public.inventory_items i on i.id = r.item_id and i.property_id = p_property_id
           group by i.id, i.name, i.qty_on_hand, i.is_active, i.is_consumable
          having sum(r.used_qty) > case when i.is_active and i.is_consumable then coalesce(i.qty_on_hand, 0) else 0 end) s;
  if jsonb_array_length(v_short) > 0 then
    return jsonb_build_object('ok', false, 'error', 'short_stock', 'short', v_short);
  end if;

  if jsonb_array_length(v_rem) > 0 then
    v_res := public.record_inventory_usage(p_property_id, p_session_date, p_logged_by, p_notes, v_rem);
    v_written := coalesce((v_res ->> 'rows')::integer, 0);
  end if;

  -- remembered amounts change only when this call wrote at least one new usage row: a full replay (stale) or a save with no rows (nothing used) must not overwrite a newer amount
  insert into public.restock_remembered_amounts as a(property_id, item_id, amount, updated_at, updated_by)
  select p_property_id, j.key::uuid, (j.value #>> '{}')::integer, now(), auth.uid() from jsonb_each(p_remember) j
   where jsonb_array_length(v_rem) > 0
  on conflict (property_id, item_id) do update set amount = excluded.amount, updated_at = excluded.updated_at, updated_by = excluded.updated_by
    where a.amount is distinct from excluded.amount;

  insert into public.restock_upkeep_checks(property_id, kind, changed, session_date, logged_by, check_key)
  -- shortcut: a Restock sent just before Manila midnight whose report is sent after it counts that report once toward the next three, upgrade by sending the report id with the Yes
  select p_property_id, u.value ->> 'kind', (u.value ->> 'changed')::boolean, public.manila_today(), v_who, u.value ->> 'check_key' from jsonb_array_elements(p_upkeep) u
  on conflict (check_key) do nothing;

  return jsonb_build_object('ok', true, 'rows', v_written, 'replayed', v_replayed);
end;
$function$;

-- 3. restock_remind_admin_v1 ---------------------------------------------------------------------------------------------------------------------
create or replace function public.restock_remind_admin_v1(p_property_id uuid, p_item_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_name text; v_qty numeric; v_today date := public.manila_today();
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not (public.current_staff_authorized('submit_cleaning', p_property_id) or public.current_staff_authorized('report_supply', p_property_id)) then
    raise exception using errcode = '42501', message = 'staff access denied';
  end if;
  select i.name, coalesce(i.qty_on_hand, 0) into v_name, v_qty from public.inventory_items i
   where i.id = p_item_id and i.property_id = p_property_id and i.is_active and i.is_consumable;
  if v_name is null then raise exception using errcode = '22023', message = 'unknown item for property'; end if;

  -- one task per item per Manila day: the key is kind + item + day, a repeat returns the same task. No cleaner name, no Telegram.
  perform public.system_task_open_v1(p_property_id, 'restock_reminder', p_item_id::text || ':' || v_today::text,
    'Restock: ' || left(v_name, 150) || case when v_qty <= 0 then ' is out' else ' is running out' end,
    case when v_qty <= 0 then 'None left in inventory.' else 'Only ' || trim_scale(v_qty)::text || ' left in inventory.' end || ' A cleaner asked for a reminder.',
    case when v_qty <= 0 then 'high' else 'normal' end);
  return jsonb_build_object('ok', true);
end;
$function$;

-- grants, stated in full (rehearsal restores are --no-acl, production has default privileges)
revoke all on function public.system_task_open_v1(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.system_task_open_v1(uuid, text, text, text, text, text) to service_role;
revoke all on function public.restock_context_v1(uuid) from public, anon;
revoke all on function public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb) from public, anon;
revoke all on function public.restock_remind_admin_v1(uuid, uuid) from public, anon;
grant execute on function public.restock_context_v1(uuid) to authenticated, service_role;
grant execute on function public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb) to authenticated, service_role;
grant execute on function public.restock_remind_admin_v1(uuid, uuid) to authenticated, service_role;

comment on function public.restock_context_v1(uuid) is
  'S120 Restock screen read: stock of active consumables, remembered amounts, upkeep_due (3 turnover reports since the last change), next_tier of the next arriving guest (tier only). Needs submit_cleaning or report_supply.';
comment on function public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb) is
  'S120 Restock save, one transaction: usage rows via record_inventory_usage (replay-safe by usage_key), remembered amounts, upkeep answers. short_stock writes nothing. Needs submit_cleaning or report_supply.';
comment on function public.restock_remind_admin_v1(uuid, uuid) is
  'S120: one Follow-ups task per item per Manila day (kind restock_reminder, high at 0 left) through system_task_open_v1. Needs submit_cleaning or report_supply.';

commit;
