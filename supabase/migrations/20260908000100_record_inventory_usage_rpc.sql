-- Module A follow-on (D-031): the Inventory app's session save used to update
-- inventory_items.qty_on_hand directly and then insert inventory_usage rows.
-- Under the named-staff RLS a cleaner may insert usage but may not update
-- items, so the decrement would silently stop. This RPC does both in one
-- transaction under the caller's staff authorization and stamps the submitter.

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
  v_row jsonb;
  v_item uuid;
  v_qty numeric;
  v_count integer := 0;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if not public.current_staff_authorized('submit_cleaning', p_property_id) then
    raise exception using errcode = '42501', message = 'staff access denied';
  end if;
  if p_session_date is null then
    raise exception using errcode = '22023', message = 'session_date required';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'rows required';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_item := (v_row ->> 'item_id')::uuid;
    v_qty  := (v_row ->> 'used_qty')::numeric;
    if v_item is null or v_qty is null or v_qty <= 0 then
      raise exception using errcode = '22023', message = 'each row needs item_id and a positive used_qty';
    end if;
    if not exists (
      select 1 from public.inventory_items i where i.id = v_item and i.property_id = p_property_id
    ) then
      raise exception using errcode = '22023', message = 'unknown item for property';
    end if;

    insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
    values (v_item, v_qty, p_session_date, nullif(btrim(coalesce(p_logged_by, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''), p_property_id, auth.uid());

    update public.inventory_items
    set qty_on_hand = greatest(0, coalesce(qty_on_hand, 0) - v_qty)
    where id = v_item;

    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'rows', v_count);
end;
$$;

revoke all on function public.record_inventory_usage(uuid, date, text, text, jsonb) from public, anon;
grant execute on function public.record_inventory_usage(uuid, date, text, text, jsonb) to authenticated, service_role;

comment on function public.record_inventory_usage(uuid, date, text, text, jsonb) is
  'Attributed inventory usage for named staff: inserts usage rows and decrements stock in one transaction. Requires submit_cleaning on the property.';
