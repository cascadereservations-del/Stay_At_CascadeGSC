-- Rollback of release s133_option_stock_20261203 (D-399 to D-402). Run it only when no client calls the new functions any more (revert the Cascade-Staff push first).
--   * the trigger and the new functions are dropped: inventory_option_count_v1, inventory_receipt_lines_v1, inventory_option_use_v1, inventory_group_update_v1, inventory_item_history_v2, inventory_log_v1, s_inventory_option_clamp_v1, s_inventory_derive_key_v1;
--   * s_inventory_option_payload_v1 and inventory_item_options_v1 go back to their previous bodies (md5 pinned, 55000 on a body that is neither);
--   * the two table checks go back to the previous host lists as NOT VALID (rows saved under the wider rule stay; only new writes are held to the old list);
--   * the columns inventory_item_options.qty_on_hand and inventory_purchases.option_id are dropped: the per-brand quantities and the brand of each receipt line are LOST. The item quantities are not touched.
-- Nothing of s132 is edited by this release, so nothing of s132 is touched here.

begin;

-- 1. guard
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.s_inventory_option_payload_v1(uuid,jsonb,boolean)');
  if v is distinct from 'ce729144e29fba1dd96aab1d46aadeff' and v is distinct from 'd59adbbd060e1d58cfc9d7aac893596b' then raise exception 's133 rollback: s_inventory_option_payload_v1 is neither this release nor the previous body (md5 %)', v using errcode = '55000'; end if;
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.inventory_item_options_v1(uuid)');
  if v is distinct from '8f1ca123739b2d13d23c92dcac3ba76d' and v is distinct from '55f85ee60e29243ef6dfc68173a76912' then raise exception 's133 rollback: inventory_item_options_v1 is neither this release nor the previous body (md5 %)', v using errcode = '55000'; end if;
end $g$;

-- 2. trigger and new functions
drop trigger if exists inventory_items_option_clamp_v1 on public.inventory_items;
drop function if exists public.s_inventory_option_clamp_v1();
drop function if exists public.inventory_option_count_v1(uuid, jsonb, numeric, text, text);
drop function if exists public.inventory_receipt_lines_v1(uuid, jsonb, numeric, date, uuid, text);
drop function if exists public.inventory_option_use_v1(uuid, uuid, uuid, numeric, text, date, text);
drop function if exists public.inventory_group_update_v1(uuid, text, jsonb, text);
drop function if exists public.inventory_item_history_v2(uuid);
drop function if exists public.inventory_log_v1(uuid, timestamptz, integer, text, uuid, boolean);
drop function if exists public.s_inventory_derive_key_v1(text, text);

-- 3. the payload validator back to the s116 body
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
    if k = 'source_url' and (v #>> '{}') !~ '^https://(shopsuki\.ph|shopee\.ph|mandauefoam\.ph|myhanabishi\.com)/' then raise exception using errcode = '22023', message = 'product link must be https on shopsuki.ph, shopee.ph, mandauefoam.ph or myhanabishi.com'; end if;
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
revoke all on function public.s_inventory_option_payload_v1(uuid, jsonb, boolean) from public, anon, authenticated, service_role;
do $g$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.s_inventory_option_payload_v1(uuid,jsonb,boolean)')) <> 'ce729144e29fba1dd96aab1d46aadeff' then
    raise exception 's133 rollback: s_inventory_option_payload_v1 did not return to the previous body' using errcode = '55000';
  end if;
end $g$;

-- 4. inventory_item_options_v1 without qty_on_hand
do $g$
declare v_src text; v_old text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_item_options_v1(uuid)');
  if md5(v_src) = '8f1ca123739b2d13d23c92dcac3ba76d' then raise notice 's133 rollback: inventory_item_options_v1 is already the previous body'; return; end if;
  v_old := replace(v_src, replace($r$'preferred', o.is_preferred, 'qty_on_hand', o.qty_on_hand, 'available', o.available,$r$, chr(13), ''), replace($f$'preferred', o.is_preferred, 'available', o.available,$f$, chr(13), ''));
  if md5(v_old) <> '8f1ca123739b2d13d23c92dcac3ba76d' then raise exception 's133 rollback: inventory_item_options_v1 did not return to the previous body (md5 %)', md5(v_old) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_item_options_v1(p_item_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_old);
end $g$;
revoke all on function public.inventory_item_options_v1(uuid) from public, anon, service_role;
grant execute on function public.inventory_item_options_v1(uuid) to authenticated;

-- 5. the table checks back to the previous host lists (NOT VALID: stored rows are not re-checked)
alter table public.inventory_item_options drop constraint if exists inventory_item_options_source_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_source_url_check
  check (source_url is null or source_url ~ '^https://(shopsuki\.ph|shopee\.ph|mandauefoam\.ph|myhanabishi\.com)/') not valid;
alter table public.inventory_item_options drop constraint if exists inventory_item_options_image_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_image_url_check
  check (image_url is null or image_url ~ '^https://(cdn\.shopify\.com|down-ph\.img\.susercontent\.com)/') not valid;

-- 6. the columns
alter table public.inventory_purchases drop column if exists option_id;
alter table public.inventory_item_options drop column if exists qty_on_hand;

commit;
