-- 20260923020000_system_tasks.sql
-- Session 45 (Opus 5), D-218 (Lloyd 2026-09-23): "for non urgent matters, either create a task so that it
-- will be fixed or notify at least once a week. Otherwise, we will be buried with notifications."
--
-- A problem that stops being worth a daily message becomes ONE row in follow_up_tasks - the dashboard's
-- Follow-ups tab - and the scheduled jobs close it themselves when the problem goes away. The jobs run as
-- service_role, which holds no privilege on follow_up_tasks (the operational RLS lockdown), so they get two
-- narrow definer functions instead of a table grant:
--
--   system_task_open_v1          one task per (kind, ref), idempotent: calling it every day never duplicates
--   system_task_close_missing_v1 closes the open tasks of a kind whose ref is no longer reported, but only
--                                refs on or after p_since, so a problem that merely aged out of a job's
--                                lookback window is never closed as if it had been fixed
--
-- No table, column or policy changes. Adds two functions, executable by service_role only.

begin;

create or replace function public.system_task_open_v1(
  p_property_id uuid,
  p_source_kind text,
  p_source_ref  text,
  p_title       text,
  p_detail      text default null,
  p_priority    text default 'normal'
)
returns uuid
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_key text;
  v_id  uuid;
begin
  if p_source_kind is null or p_source_kind !~ '^[a-z_]{3,40}$' then
    raise exception 'source kind must be 3-40 lowercase letters or underscores' using errcode = '22023';
  end if;
  if p_source_ref is null or char_length(p_source_ref) not between 1 and 100 then
    raise exception 'source ref is required' using errcode = '22023';
  end if;
  v_key := 'system:' || p_source_kind || ':' || p_source_ref;

  insert into public.follow_up_tasks
    (property_id, purpose, title, detail, priority, status, source_kind, source_ref, idempotency_key)
  values
    (p_property_id, 'other', left(btrim(p_title), 200), p_detail, coalesce(p_priority, 'normal'), 'open',
     p_source_kind, p_source_ref, v_key)
  on conflict (idempotency_key) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.follow_up_tasks where idempotency_key = v_key;
  end if;
  return v_id;
end;
$function$;

create or replace function public.system_task_close_missing_v1(
  p_source_kind text,
  p_still_open  text[],
  p_since       text,
  p_note        text
)
returns integer
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare n integer;
begin
  if p_source_kind is null or p_source_kind !~ '^[a-z_]{3,40}$' then
    raise exception 'source kind must be 3-40 lowercase letters or underscores' using errcode = '22023';
  end if;
  update public.follow_up_tasks
     set status = 'done',
         completed_at = now(),
         completion_note = left(coalesce(p_note, 'Closed automatically: the problem is no longer reported.'), 500)
   where source_kind = p_source_kind
     and idempotency_key like 'system:%'
     and status in ('open', 'in_progress')
     and (p_since is null or source_ref >= p_since)
     and not (source_ref = any (coalesce(p_still_open, '{}'::text[])));
  get diagnostics n = row_count;
  return n;
end;
$function$;

revoke all on function public.system_task_open_v1(uuid, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.system_task_close_missing_v1(text, text[], text, text) from public, anon, authenticated;
grant execute on function public.system_task_open_v1(uuid, text, text, text, text, text) to service_role;
grant execute on function public.system_task_close_missing_v1(text, text[], text, text) to service_role;

comment on function public.system_task_open_v1(uuid, text, text, text, text, text) is
  'D-218: a scheduled job files a non-urgent problem as ONE Follow-ups task (idempotent per kind and ref). service_role only.';
comment on function public.system_task_close_missing_v1(text, text[], text, text) is
  'D-218: closes a job''s open tasks whose ref it no longer reports, only for refs on or after p_since. service_role only.';

commit;
