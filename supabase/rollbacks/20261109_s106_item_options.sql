-- Rollback for s106_item_options_20261109: drops the two RPCs, the internal seed function and the options table, then removes the Shopsuki
-- links and the Shopsuki supplier only when this release created them (name and notes match) and nothing else uses the supplier.
-- Not undone: preferred links an admin moved with inventory_item_option_set_usual_v1 (the previous preferred link of that item is not restored).
drop function if exists public.inventory_item_option_set_usual_v1(uuid);
drop function if exists public.inventory_item_options_v1(uuid);
drop function if exists public.s_inventory_item_options_seed_v1();
drop table if exists public.inventory_item_options;

do $$
declare v_sid uuid;
begin
  select s.id into v_sid from public.inventory_suppliers s
  where s.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and s.name = 'Shopsuki' and s.notes = 'Prices read from shopsuki.ph on 2026-10-31';
  if v_sid is null then return; end if;
  if exists (select 1 from public.inventory_purchases p where p.supplier_id = v_sid)
     or exists (select 1 from public.inventory_shopping_list l where l.supplier_id = v_sid) then
    raise notice 'Shopsuki supplier kept: purchases or shopping list rows use it';
    return;
  end if;
  delete from public.inventory_item_suppliers where supplier_id = v_sid;
  delete from public.inventory_suppliers where id = v_sid;
end $$;
