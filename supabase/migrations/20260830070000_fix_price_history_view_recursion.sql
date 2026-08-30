-- The recovered production view selected from itself and raised SQLSTATE 42P17.
-- Preserve its six-column contract while restoring the intended purchase history.
create or replace view public.price_history_by_item
with (security_invoker = true)
as
select
  p.item_id,
  i.name as item_name,
  p.supplier,
  p.unit_cost,
  p.purchased_at,
  row_number() over (
    partition by p.item_id
    order by p.purchased_at desc, p.created_at desc, p.id desc
  ) as recency_rank
from public.inventory_purchases p
join public.inventory_items i on i.id = p.item_id
where p.unit_cost is not null;

comment on view public.price_history_by_item is
  'Inventory purchase price history ranked newest-first per item.';
