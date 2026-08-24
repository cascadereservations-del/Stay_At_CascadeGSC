
create or replace function match_inventory_item(
  p_name text,
  p_limit int default 1,
  p_threshold real default 0.3,
  p_consumable_only boolean default true
)
returns table (
  id uuid, name text, category text, is_consumable boolean,
  units_per_purchase numeric, qty_on_hand numeric, score real
)
language sql stable as $$
  select i.id, i.name, i.category, i.is_consumable,
         coalesce(i.units_per_purchase, 1) as units_per_purchase,
         i.qty_on_hand,
         greatest(similarity(i.name, p_name), word_similarity(i.name, p_name)) as score
  from inventory_items i
  where i.is_active
    and (not p_consumable_only or i.is_consumable)
    and greatest(similarity(i.name, p_name), word_similarity(i.name, p_name)) >= p_threshold
  order by score desc, i.is_consumable desc
  limit greatest(p_limit, 1);
$$;
;
