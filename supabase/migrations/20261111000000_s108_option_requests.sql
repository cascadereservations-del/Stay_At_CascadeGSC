-- 20261111000000_s108_option_requests.sql
-- Session 108, lane SQL: release s108_option_requests_20261111 (phase backfill). Any staff user can ask to add, edit or delete a product option under a stock
-- item (Lloyd); the owner/admin (manage_inventory) approves. Staff with read_operations only create REQUESTS that wait; manage_inventory callers apply at once
-- (they are the approvers) and the change is recorded as an approved request. A caller without read_finance/manage_inventory never sends or sees a price.
--   1. Table  inventory_option_requests: RLS on, no grants to any client role, not in realtime; all access through the four definer RPCs.
--   2. RPCs   inventory_option_request_v1 (create / apply), inventory_option_requests_v1 (list), inventory_option_request_decide_v1 (approve / reject),
--             inventory_option_request_cancel_v1 (requester cancels own pending request).
--   3. Notify one follow-up task per item with pending requests (title 'Product change to approve: <item>', source_kind option_request) via
--             system_task_open_v1; closed through system_task_close_missing_v1 when no pending request remains.
--   4. Internal (no grants) s_inventory_option_payload_v1 (validate), s_inventory_option_apply_v1 (write), s_inventory_option_request_task_v1 (task).
-- Additive only: no existing table, column or function is changed.

-- 1. table ---------------------------------------------------------------------------------------------------------------------------------
create table public.inventory_option_requests (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete restrict,
  item_id uuid not null references public.inventory_items(id) on delete cascade,
  option_id uuid references public.inventory_item_options(id) on delete set null,
  option_title text check (option_title is null or char_length(option_title) <= 160), -- snapshot, so a deleted option still reads
  action text not null check (action in ('add', 'edit', 'delete')),
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object'),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  note text check (note is null or char_length(note) <= 500),
  idempotency_key text not null check (char_length(idempotency_key) between 16 and 160),
  requested_by uuid default auth.uid() references auth.users(id) on delete set null, -- s108 review: keep history when an account is deleted
  requested_at timestamptz not null default now(),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 500),
  result_option_id uuid,
  constraint inventory_option_requests_key_uq unique (requested_by, idempotency_key)
);
create index inventory_option_requests_prop_status_idx on public.inventory_option_requests (property_id, status);
create index inventory_option_requests_item_idx on public.inventory_option_requests (item_id);
alter table public.inventory_option_requests enable row level security;
revoke all on table public.inventory_option_requests from public, anon, authenticated, service_role;
comment on table public.inventory_option_requests is 'S108: staff requests to add/edit/delete a product option under a stock item. No client access: read and written through the inventory_option_request* definer RPCs; price only for read_finance.';

-- 2. internal helpers ----------------------------------------------------------------------------------------------------------------------
-- Validates and normalises a payload. Unknown keys, wrong types and bad urls raise 22023. A price from a caller who may not send one raises price_not_allowed
-- (a null price from such a caller is simply dropped). A null value for an optional field means "clear it".
create or replace function public.s_inventory_option_payload_v1(p_prop uuid, p_payload jsonb, p_allow_price boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_out jsonb := '{}'::jsonb; k text; v jsonb; t text;
begin
  if p_payload is null then return v_out; end if;
  if jsonb_typeof(p_payload) <> 'object' then raise exception using errcode = '22023', message = 'payload must be an object'; end if;
  for k, v in select * from jsonb_each(p_payload) loop
    if k <> all (array['title', 'brand', 'pack_label', 'pack_size', 'price', 'image_url', 'source_url', 'supplier_id', 'available']) then
      raise exception using errcode = '22023', message = 'field not allowed: ' || k;
    end if;
    if k = 'price' and not p_allow_price then
      if v <> 'null'::jsonb then raise exception using errcode = '22023', message = 'price_not_allowed'; end if;
      continue;
    end if;
    if v = 'null'::jsonb then
      if k in ('title', 'supplier_id') then raise exception using errcode = '22023', message = k || ' cannot be cleared'; end if;
      v_out := v_out || jsonb_build_object(k, null);
      continue;
    end if;
    t := jsonb_typeof(v);
    if k in ('title', 'brand', 'pack_label', 'image_url', 'source_url', 'supplier_id') and t <> 'string' then raise exception using errcode = '22023', message = k || ' must be text'; end if;
    if k in ('pack_size', 'price') and t <> 'number' then raise exception using errcode = '22023', message = k || ' must be a number'; end if;
    if k = 'available' and t <> 'boolean' then raise exception using errcode = '22023', message = 'available must be true or false'; end if;
    if k = 'title' and char_length(btrim(v #>> '{}')) not between 1 and 160 then raise exception using errcode = '22023', message = 'title must be 1 to 160 characters'; end if;
    if k = 'brand' and char_length(v #>> '{}') > 60 then raise exception using errcode = '22023', message = 'brand is too long'; end if;
    if k = 'pack_label' and char_length(v #>> '{}') > 40 then raise exception using errcode = '22023', message = 'pack label is too long'; end if;
    if k = 'pack_size' and not ((v #>> '{}')::numeric > 0 and (v #>> '{}')::numeric < 100000) then raise exception using errcode = '22023', message = 'pack size must be more than 0 and below 100000'; end if;
    if k = 'price' and not ((v #>> '{}')::numeric >= 0.01 and (v #>> '{}')::numeric < 1000000) then raise exception using errcode = '22023', message = 'price must be at least 0.01 and below 1000000'; end if;
    if k = 'image_url' and (v #>> '{}') !~ '^https://(cdn\.shopify\.com|down-ph\.img\.susercontent\.com)/' then raise exception using errcode = '22023', message = 'image link must be https on cdn.shopify.com or down-ph.img.susercontent.com'; end if;
    if k = 'source_url' and (v #>> '{}') !~ '^https://(shopsuki\.ph|shopee\.ph)/' then raise exception using errcode = '22023', message = 'product link must be https on shopsuki.ph or shopee.ph'; end if;
    if k in ('image_url', 'source_url') and char_length(v #>> '{}') > 500 then raise exception using errcode = '22023', message = k || ' is too long'; end if;
    if k = 'supplier_id' then
      if (v #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or not exists (select 1 from public.inventory_suppliers s where s.id = (v #>> '{}')::uuid and s.property_id = p_prop and s.is_active) then
        raise exception using errcode = '22023', message = 'supplier must be an active supplier of this property';
      end if;
    end if;
    v_out := v_out || jsonb_build_object(k, case when k = 'title' then to_jsonb(btrim(v #>> '{}')) else v end);
  end loop;
  return v_out;
end;
$$;

-- Writes one change and returns the option id. Callers hold the item lock and have run the payload through s_inventory_option_payload_v1.
create or replace function public.s_inventory_option_apply_v1(p_item uuid, p_prop uuid, p_action text, p_option uuid, p_payload jsonb, p_user uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare o public.inventory_item_options%rowtype; v_id uuid;
begin
  if p_action = 'add' then
    if not (p_payload ? 'title') then raise exception using errcode = '22023', message = 'title is required'; end if;
    if not (p_payload ? 'supplier_id') then raise exception using errcode = '22023', message = 'supplier is required'; end if;
    insert into public.inventory_item_options(property_id, item_id, supplier_id, title, brand, pack_label, pack_size, price, image_url, source_url, available, created_by)
    values (p_prop, p_item, (p_payload ->> 'supplier_id')::uuid, p_payload ->> 'title', p_payload ->> 'brand', p_payload ->> 'pack_label',
            (p_payload ->> 'pack_size')::numeric, (p_payload ->> 'price')::numeric, p_payload ->> 'image_url', p_payload ->> 'source_url', (p_payload ->> 'available')::boolean, p_user)
    returning id into v_id;
    return v_id;
  end if;
  select * into o from public.inventory_item_options x where x.id = p_option and x.item_id = p_item for update;
  if not found then raise exception using errcode = '22023', message = 'option_gone'; end if;
  if p_action = 'delete' then
    if o.is_usual then raise exception using errcode = '22023', message = 'usual_option'; end if;
    delete from public.inventory_item_options where id = o.id;
    return o.id;
  end if;
  if p_payload = '{}'::jsonb then raise exception using errcode = '22023', message = 'nothing to change'; end if;
  update public.inventory_item_options set
    title = coalesce(p_payload ->> 'title', title),
    supplier_id = coalesce((p_payload ->> 'supplier_id')::uuid, supplier_id),
    brand = case when p_payload ? 'brand' then p_payload ->> 'brand' else brand end,
    pack_label = case when p_payload ? 'pack_label' then p_payload ->> 'pack_label' else pack_label end,
    pack_size = case when p_payload ? 'pack_size' then (p_payload ->> 'pack_size')::numeric else pack_size end,
    price = case when p_payload ? 'price' then (p_payload ->> 'price')::numeric else price end,
    image_url = case when p_payload ? 'image_url' then p_payload ->> 'image_url' else image_url end,
    source_url = case when p_payload ? 'source_url' then p_payload ->> 'source_url' else source_url end,
    available = case when p_payload ? 'available' then (p_payload ->> 'available')::boolean else available end
   where id = o.id;
  -- the usual option feeds the item/supplier link (pack label, size, price): refresh it so the shopping list sees the edit
  if o.is_usual then perform public.s_inventory_option_make_usual_v1(o.id); end if;
  return o.id;
exception when unique_violation then
  raise exception using errcode = '22023', message = 'duplicate_option';
end;
$$;

-- One open follow-up task per item with pending requests; closed when no pending request is left anywhere.
create or replace function public.s_inventory_option_request_task_v1(p_prop uuid, p_item uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_n int; v_name text; v_id uuid;
begin
  select count(*) into v_n from public.inventory_option_requests r where r.item_id = p_item and r.status = 'pending';
  if v_n > 0 then
    select i.name into v_name from public.inventory_items i where i.id = p_item;
    v_id := public.system_task_open_v1(p_prop, 'option_request', p_item::text, 'Product change to approve: ' || v_name,
                                       v_n || ' staff request(s) wait in Inventory > Options for approval.', 'normal');
    -- s108 review: reopen a task an admin closed or cancelled, and keep the count in the detail current
    update public.follow_up_tasks set status = 'open', completed_at = null, completed_by = null, completion_note = null,
           detail = v_n || ' staff request(s) wait in Inventory > Options for approval.', updated_at = now(), version = version + 1
     where id = v_id and (status in ('done','cancelled') or detail is distinct from v_n || ' staff request(s) wait in Inventory > Options for approval.');
  else
    -- s108 review: close only this item's task (no cross-property scan, no race with another item)
    update public.follow_up_tasks set status = 'done', completed_at = now(), completion_note = 'No product change is waiting for approval.',
           updated_at = now(), version = version + 1
     where idempotency_key = 'system:option_request:' || p_item::text and status in ('open','in_progress');
  end if;
end;
$$;

-- 3. RPCs ----------------------------------------------------------------------------------------------------------------------------------
-- Create a request. manage_inventory callers: applied at once and recorded as approved. Everyone else with read_operations: pending.
create or replace function public.inventory_option_request_v1(p_item_id uuid, p_action text, p_option_id uuid, p_payload jsonb, p_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_mgr boolean; v_fin boolean; v_payload jsonb; v_id uuid; v_old public.inventory_option_requests%rowtype;
  o public.inventory_item_options%rowtype; v_res uuid;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  if p_action is null or p_action <> all (array['add', 'edit', 'delete']) then raise exception using errcode = '22023', message = 'action must be add, edit or delete'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  if p_note is not null and char_length(p_note) > 500 then raise exception using errcode = '22023', message = 'note must be at most 500 characters'; end if;

  select * into v_old from public.inventory_option_requests r where r.requested_by = v_uid and r.idempotency_key = p_idempotency_key;
  if found then
    if v_old.item_id <> p_item_id then raise exception using errcode = '22023', message = 'idempotency key already used for another item'; end if;
    return jsonb_build_object('ok', true, 'applied', v_old.status = 'approved', 'request_id', v_old.id, 'option_id', coalesce(v_old.result_option_id, v_old.option_id), 'replay', true);
  end if;

  perform 1 from public.inventory_items i where i.id = p_item_id for update;
  v_mgr := public.current_staff_authorized('manage_inventory', v_prop);
  v_fin := v_mgr or public.finance_human_authorized(v_prop);
  v_payload := case when p_action = 'delete' then '{}'::jsonb else public.s_inventory_option_payload_v1(v_prop, p_payload, v_fin) end;

  if p_action = 'add' then
    if not (v_payload ? 'title') then raise exception using errcode = '22023', message = 'title is required'; end if;
    if not (v_payload ? 'supplier_id') then raise exception using errcode = '22023', message = 'supplier is required'; end if;
  else
    select * into o from public.inventory_item_options x where x.id = p_option_id and x.item_id = p_item_id;
    if not found then raise exception using errcode = '22023', message = 'option must belong to the item'; end if;
    if p_action = 'delete' and o.is_usual then raise exception using errcode = '22023', message = 'usual_option'; end if;
    if p_action = 'edit' and v_payload = '{}'::jsonb then raise exception using errcode = '22023', message = 'nothing to change'; end if;
  end if;

  insert into public.inventory_option_requests(property_id, item_id, option_id, option_title, action, payload, note, idempotency_key, requested_by)
  values (v_prop, p_item_id, case when p_action = 'add' then null else p_option_id end, case when p_action = 'add' then v_payload ->> 'title' else o.title end,
          p_action, v_payload, nullif(btrim(p_note), ''), p_idempotency_key, v_uid)
  on conflict (requested_by, idempotency_key) do nothing returning id into v_id;
  if v_id is null then
    select * into v_old from public.inventory_option_requests r where r.requested_by = v_uid and r.idempotency_key = p_idempotency_key;
    return jsonb_build_object('ok', true, 'applied', v_old.status = 'approved', 'request_id', v_old.id, 'option_id', coalesce(v_old.result_option_id, v_old.option_id), 'replay', true);
  end if;

  if v_mgr then
    v_res := public.s_inventory_option_apply_v1(p_item_id, v_prop, p_action, p_option_id, v_payload, v_uid);
    update public.inventory_option_requests set status = 'approved', decided_by = v_uid, decided_at = now(), result_option_id = v_res where id = v_id;
    return jsonb_build_object('ok', true, 'applied', true, 'option_id', v_res, 'request_id', v_id);
  end if;
  perform public.s_inventory_option_request_task_v1(v_prop, p_item_id);
  return jsonb_build_object('ok', true, 'applied', false, 'request_id', v_id);
end;
$$;

-- List requests of a property. manage_inventory sees all; others only their own. Price (in payload and in 'current') only for read_finance.
-- p_status: pending (default), approved, rejected, cancelled, or all. Newest first, at most 200.
create or replace function public.inventory_option_requests_v1(p_property_id uuid, p_status text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_mgr boolean; v_fin boolean; v_list jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  if p_status is not null and p_status <> all (array['pending', 'approved', 'rejected', 'cancelled', 'all']) then raise exception using errcode = '22023', message = 'status not allowed'; end if;
  v_mgr := public.current_staff_authorized('manage_inventory', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  select coalesce(jsonb_agg(row_j order by at desc, id), '[]'::jsonb) into v_list from (
    select r.requested_at as at, r.id,
      jsonb_build_object('id', r.id, 'item_id', r.item_id, 'item', i.name, 'option_id', r.option_id, 'option_title', coalesce(o.title, r.option_title), 'action', r.action,
        'payload', case when v_fin then r.payload else r.payload - 'price' end, 'status', r.status, 'note', r.note,
        'requested_by', r.requested_by, 'requester', nullif(btrim(coalesce(u.raw_user_meta_data ->> 'display_name', '')), ''), 'mine', r.requested_by = v_uid, 'requested_at', r.requested_at,
        'decided_by', r.decided_by, 'decided_at', r.decided_at, 'decision_note', r.decision_note, 'result_option_id', r.result_option_id,
        'current', case when o.id is null then null else
          jsonb_build_object('title', o.title, 'brand', o.brand, 'pack_label', o.pack_label, 'pack_size', o.pack_size, 'image_url', o.image_url, 'source_url', o.source_url,
                             'supplier_id', o.supplier_id, 'available', o.available, 'usual', o.is_usual)
          || case when v_fin then jsonb_build_object('price', o.price) else '{}'::jsonb end end) as row_j
    from public.inventory_option_requests r
    join public.inventory_items i on i.id = r.item_id
    left join public.inventory_item_options o on o.id = r.option_id
    left join auth.users u on u.id = r.requested_by
    where r.property_id = p_property_id and (p_status is null or p_status = 'all' or r.status = p_status) and (v_mgr or r.requested_by = v_uid)
    order by r.requested_at desc, r.id limit 200) q;
  return jsonb_build_object('ok', true, 'property_id', p_property_id, 'manage', v_mgr, 'requests', v_list);
end;
$$;

-- Approve (optionally adjusting any allowed field, price included) or reject a pending request. manage_inventory only.
create or replace function public.inventory_option_request_decide_v1(p_request_id uuid, p_decision text, p_payload_override jsonb default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); r public.inventory_option_requests%rowtype; v_merged jsonb; v_res uuid;
begin
  select * into r from public.inventory_option_requests x where x.id = p_request_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'request not found'; end if;
  perform public.admin_require('manage_inventory', r.property_id);
  if p_decision is null or p_decision <> all (array['approve', 'reject']) then raise exception using errcode = '22023', message = 'decision must be approve or reject'; end if;
  if p_note is not null and char_length(p_note) > 500 then raise exception using errcode = '22023', message = 'note must be at most 500 characters'; end if;
  if r.status <> 'pending' then raise exception using errcode = '22023', message = 'not_pending'; end if;
  perform 1 from public.inventory_items i where i.id = r.item_id for update;

  if p_decision = 'reject' then
    update public.inventory_option_requests set status = 'rejected', decided_by = v_uid, decided_at = now(), decision_note = nullif(btrim(p_note), '') where id = r.id;
    perform public.s_inventory_option_request_task_v1(r.property_id, r.item_id);
    return jsonb_build_object('ok', true, 'request_id', r.id, 'status', 'rejected', 'option_id', null);
  end if;

  -- the stored payload was checked at request time; the supplier may have been deactivated since, so the merged result is checked again
  v_merged := case when r.action = 'delete' then '{}'::jsonb
                   else public.s_inventory_option_payload_v1(r.property_id, r.payload || public.s_inventory_option_payload_v1(r.property_id, p_payload_override, true), true) end;
  v_res := public.s_inventory_option_apply_v1(r.item_id, r.property_id, r.action, r.option_id, v_merged, r.requested_by);
  update public.inventory_option_requests set status = 'approved', payload = v_merged, decided_by = v_uid, decided_at = now(), decision_note = nullif(btrim(p_note), ''),
         result_option_id = v_res where id = r.id;
  perform public.s_inventory_option_request_task_v1(r.property_id, r.item_id);
  return jsonb_build_object('ok', true, 'request_id', r.id, 'status', 'approved', 'option_id', v_res);
end;
$$;

-- The requester withdraws their own pending request.
create or replace function public.inventory_option_request_cancel_v1(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); r public.inventory_option_requests%rowtype;
begin
  select * into r from public.inventory_option_requests x where x.id = p_request_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'request not found'; end if;
  perform public.admin_require('read_operations', r.property_id);
  if r.requested_by is distinct from v_uid then raise exception using errcode = '42501', message = 'only the requester can cancel a request'; end if;
  if r.status <> 'pending' then raise exception using errcode = '22023', message = 'not_pending'; end if;
  update public.inventory_option_requests set status = 'cancelled', decided_by = v_uid, decided_at = now() where id = r.id;
  perform public.s_inventory_option_request_task_v1(r.property_id, r.item_id);
  return jsonb_build_object('ok', true, 'request_id', r.id, 'status', 'cancelled');
end;
$$;

revoke all on function public.inventory_option_request_v1(uuid, text, uuid, jsonb, text, text) from public, anon, service_role;
revoke all on function public.inventory_option_requests_v1(uuid, text) from public, anon, service_role;
revoke all on function public.inventory_option_request_decide_v1(uuid, text, jsonb, text) from public, anon, service_role;
revoke all on function public.inventory_option_request_cancel_v1(uuid) from public, anon, service_role;
grant execute on function public.inventory_option_request_v1(uuid, text, uuid, jsonb, text, text) to authenticated;
grant execute on function public.inventory_option_requests_v1(uuid, text) to authenticated;
grant execute on function public.inventory_option_request_decide_v1(uuid, text, jsonb, text) to authenticated;
grant execute on function public.inventory_option_request_cancel_v1(uuid) to authenticated;
revoke all on function public.s_inventory_option_payload_v1(uuid, jsonb, boolean) from public, anon, authenticated, service_role;
revoke all on function public.s_inventory_option_apply_v1(uuid, uuid, text, uuid, jsonb, uuid) from public, anon, authenticated, service_role;
revoke all on function public.s_inventory_option_request_task_v1(uuid, uuid) from public, anon, authenticated, service_role;
