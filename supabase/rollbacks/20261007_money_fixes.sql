-- Compensating rollback for release money_fixes_20261007 (session 74, lane G3). Run with run-sql-on-host.sh; prefer a forward fix.
--  1. staff pay: the two functions go back to cleaned_at::date (the UTC day). Only worth it if the Manila day proves wrong.
--  2. cleaner_rate_schedule: the old owner/admin JWT-metadata policy and ALL grants to anon and authenticated come back as read on
--     2026-10-07 (supabase/schemas/000_remote_public_schema.sql + 20260529195649). This reopens direct API writes to owner/admin.
--  3. record_inventory_usage returns to v2 (movement only for movement-controlled items). Movement rows already written stay as history.
begin;

do $$
declare v_fn text; v_def text; v_new text;
begin
  foreach v_fn in array array['public.staff_pay_candidates_v1()', 'public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    v_new := regexp_replace(v_def, '\((\w+\.)?cleaned_at at time zone ''Asia/Manila''\)::date', '\1cleaned_at::date', 'g');
    if v_new <> v_def then execute v_new; end if;
  end loop;
end $$;

drop policy if exists cleaner_rate_staff_read on public.cleaner_rate_schedule;
create policy cleaner_rate_owner_admin_all on public.cleaner_rate_schedule
  for all to authenticated
  using      ((select auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']))
  with check ((select auth.jwt() -> 'app_metadata' ->> 'role') = any (array['owner','admin']));
grant all on table public.cleaner_rate_schedule to anon, authenticated;

create or replace function public.record_inventory_usage(
  p_property_id uuid,
  p_session_date date,
  p_logged_by text,
  p_notes text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb; v_item uuid; v_qty numeric; v_count integer := 0; v_controlled boolean; v_usage_id uuid; v_usage_key text; v_existing uuid; v_moves jsonb := '[]'::jsonb; v_name text;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not public.current_staff_authorized('submit_cleaning', p_property_id) then raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if p_session_date is null then raise exception using errcode = '22023', message = 'session_date required'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception using errcode = '22023', message = 'rows required'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty  := (v_row ->> 'used_qty')::numeric;
    v_usage_key := nullif(v_row ->> 'usage_key', '');
    if v_item is null or v_qty is null or v_qty <= 0 then raise exception using errcode = '22023', message = 'each row needs item_id and a positive used_qty'; end if;
    select (movement_controlled_at is not null), name into v_controlled, v_name from public.inventory_items i where i.id = v_item and i.property_id = p_property_id for update;
    if v_controlled is null then raise exception using errcode = '22023', message = 'unknown item for property'; end if;

    -- Replay: a usage row with the same client key already exists.
    if v_usage_key is not null then
      select id into v_existing from public.inventory_usage u where u.item_id = v_item and u.notes like '%[key:' || v_usage_key || ']%' limit 1;
      if v_existing is not null then v_count := v_count + 1; continue; end if;
    end if;

    insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
    values (v_item, v_qty, p_session_date, nullif(btrim(coalesce(p_logged_by, '')), ''),
            nullif(btrim(coalesce(p_notes, '')) || case when v_usage_key is not null then ' [key:' || v_usage_key || ']' else '' end, ''),
            p_property_id, auth.uid())
    returning id into v_usage_id;

    if v_controlled then
      if (select qty_on_hand from public.inventory_items where id = v_item) < v_qty then
        raise exception using errcode = '22023', message = 'insufficient stock for ' || v_name;
      end if;
      v_moves := v_moves || to_jsonb(public.inventory_apply_event_v1(v_item, 'usage', -v_qty, 'Usage ' || p_session_date::text || coalesce(' by ' || p_logged_by, ''), 'inventory_usage', v_usage_id::text));
    else
      update public.inventory_items set qty_on_hand = greatest(0, coalesce(qty_on_hand, 0) - v_qty) where id = v_item;
    end if;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'rows', v_count, 'movements', v_moves);
end;
$$;
comment on function public.record_inventory_usage(uuid, date, text, text, jsonb) is
  'v2 (admin modernisation): same contract. Movement-controlled items write inventory_stock_movements and reject insufficient stock; others keep the legacy decrement. Optional rows[i].usage_key makes retries replay-safe.';

commit;
