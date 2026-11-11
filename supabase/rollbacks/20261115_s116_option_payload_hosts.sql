-- Rollback for 20261115000200_s116_option_payload_hosts: puts the s108 body of public.s_inventory_option_payload_v1 back (shopsuki.ph and shopee.ph only, the old message).
-- Guard (55000, nothing changes): the live body must be the s116 one (md5 ce729144e29fba1dd96aab1d46aadeff). Grants restated as s108 had them (no client role).
-- Existing option rows are untouched; only new staff requests for a mandauefoam.ph or myhanabishi.com link are refused again.
begin;

do $g$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.s_inventory_option_payload_v1(uuid,jsonb,boolean)')) is distinct from 'ce729144e29fba1dd96aab1d46aadeff' then
    raise exception 's116: public.s_inventory_option_payload_v1(uuid,jsonb,boolean) is not the s116 body (md5 %): re-cut it from the live body',
      (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.s_inventory_option_payload_v1(uuid,jsonb,boolean)')) using errcode = '55000';
  end if;
end
$g$;

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

revoke all on function public.s_inventory_option_payload_v1(uuid, jsonb, boolean) from public, anon, authenticated, service_role;

commit;
