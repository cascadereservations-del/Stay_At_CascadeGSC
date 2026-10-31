-- Rollback for s107_preferred_picks_20261110: restores the s106 bodies of inventory_item_options_v1 and inventory_item_option_set_usual_v1 verbatim, drops the two
-- s107 internal functions, puts the s106 image_url check back and drops inventory_item_options.is_preferred.
-- NOT undone (safe_until in the release contract says the same): the usual choices and preferred supplier links the data step changed, the 4 Colgate options deleted from
-- Toiletries, the Shopsuki link removed from Toiletries, the Shopee supplier, the new item 'All-Purpose Cleaner (Mr Muscle)' and the 16 option rows it inserted. They are harmless
-- under the s106 code and can be re-seeded from docs/s106/shopsuki-capture.json (s106 options) if ever needed. The s106 image check allows only the Shopify host, so Shopee option
-- images (down-ph.img.susercontent.com) are set to null before it is restored; the option rows stay.
begin;

create or replace function public.inventory_item_options_v1(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid; v_fin boolean; v_list jsonb;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  select coalesce(jsonb_agg(
    jsonb_build_object('id', o.id, 'supplier_id', o.supplier_id, 'supplier', s.name, 'title', o.title, 'brand', o.brand, 'pack_label', o.pack_label,
                       'pack_size', o.pack_size, 'image_url', o.image_url, 'source_url', o.source_url, 'usual', o.is_usual, 'available', o.available,
                       'captured_at', o.captured_at)
    || case when v_fin then jsonb_build_object('price', o.price) else '{}'::jsonb end
    order by o.is_usual desc, case when v_fin then o.price end nulls last, lower(o.title), o.id), '[]'::jsonb) into v_list
  from public.inventory_item_options o join public.inventory_suppliers s on s.id = o.supplier_id
  where o.item_id = p_item_id;
  return jsonb_build_object('ok', true, 'item_id', p_item_id, 'options', v_list);
end;
$$;

create or replace function public.inventory_item_option_set_usual_v1(p_option_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o public.inventory_item_options%rowtype; v_prop uuid; v_label text;
begin
  select * into o from public.inventory_item_options x where x.id = p_option_id for update;
  if found then perform 1 from public.inventory_items where id = o.item_id for update; end if; -- s106 review: serialise set-usual per item
  if not found then raise exception using errcode = 'P0002', message = 'option not found'; end if;
  perform public.admin_require('manage_inventory', o.property_id);
  select i.property_id into v_prop from public.inventory_items i where i.id = o.item_id;
  if v_prop is distinct from o.property_id then raise exception using errcode = '22023', message = 'option does not belong to the item property'; end if;
  if not exists (select 1 from public.inventory_suppliers s where s.id = o.supplier_id and s.property_id = o.property_id) then
    raise exception using errcode = '22023', message = 'supplier does not belong to the option property';
  end if;
  v_label := left(coalesce(nullif(btrim(o.pack_label), ''),
                           case when o.brand is null or starts_with(lower(o.title), lower(o.brand)) then o.title else o.brand || ' ' || o.title end), 40);
  update public.inventory_item_options set is_usual = false where item_id = o.item_id and is_usual and id <> o.id;
  update public.inventory_item_options set is_usual = true where id = o.id and not is_usual;
  update public.inventory_item_suppliers set is_preferred = false where item_id = o.item_id and supplier_id <> o.supplier_id and is_preferred;
  insert into public.inventory_item_suppliers as k(item_id, supplier_id, pack_label, pack_size, quoted_pack_price, is_preferred)
  values (o.item_id, o.supplier_id, v_label, o.pack_size, o.price, true)
  on conflict (item_id, supplier_id) do update
    set pack_label = excluded.pack_label, pack_size = coalesce(excluded.pack_size, k.pack_size), quoted_pack_price = coalesce(excluded.quoted_pack_price, k.quoted_pack_price), is_preferred = true;
  return public.inventory_item_options_v1(o.item_id);
end;
$$;

revoke all on function public.inventory_item_options_v1(uuid) from public, anon, service_role;
revoke all on function public.inventory_item_option_set_usual_v1(uuid) from public, anon, service_role;
grant execute on function public.inventory_item_options_v1(uuid) to authenticated;
grant execute on function public.inventory_item_option_set_usual_v1(uuid) to authenticated;

drop function if exists public.s_inventory_preferred_picks_v1();
drop function if exists public.s_inventory_option_make_usual_v1(uuid);

update public.inventory_item_options set image_url = null where image_url is not null and image_url !~ '^https://cdn\.shopify\.com/';
alter table public.inventory_item_options drop constraint if exists inventory_item_options_image_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_image_url_check check (image_url is null or image_url ~ '^https://cdn\.shopify\.com/');
alter table public.inventory_item_options drop column if exists is_preferred;

commit;
