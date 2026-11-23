-- s134 back-fill PREVIEW. Read only: no insert, update or delete. Run it, show Lloyd the table, and run s134_backfill.sql only after his yes.
-- Start date default 2026-08-01; change the one date literal below to preview another date (s134_backfill.sql takes it from "set s134.start_date").
select g.grp as expense_group, g.prop as property_id, g.first_date, g.n as purchases, g.priced as priced_lines,
       coalesce(d.total, g.priced_sum) as would_be_amount,
       (d.total is null and g.priced < g.n) as amount_incomplete,
       exists (select 1 from public.transactions o
                where o.property_id = g.prop and o.txn_type = 'expense' and o.status <> 'void' and o.category in ('supplies', 'maintenance', 'repairs')
                  and o.source not in ('airbnb', 'airbnb_email') and abs(o.transaction_date - g.first_date) <= 3
                  and not exists (select 1 from public.inventory_purchases ip where ip.transaction_id = o.id)) as possible_duplicate
  from (select coalesce(p.expense_group, public.s_stock_expense_group_of_v1(p.id, p.notes)) as grp, (array_agg(i.property_id))[1] as prop, min(p.purchased_at) as first_date,
               round(coalesce(sum(p.qty * p.unit_cost) filter (where p.unit_cost > 0), 0), 2) as priced_sum, count(*) as n, count(*) filter (where p.unit_cost > 0) as priced
          from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
         group by 1
        having bool_and(p.transaction_id is null)
           and not bool_or(exists (select 1 from public.transactions tx where tx.id = public.s_stock_expense_txn_of_v1(p.notes)))
           and min(p.purchased_at) >= date '2026-08-01' and count(*) filter (where p.unit_cost > 0) > 0) g
  left join public.inventory_receipt_drafts d on g.grp = 'draft:' || d.id::text and d.total > 0
 where not exists (select 1 from public.transactions t where t.external_ref = 'stock:' || g.grp and t.txn_type = 'expense')
   and not exists (select 1 from public.inventory_receipt_drafts dd where g.grp = 'draft:' || dd.id::text and dd.transaction_id is not null)
 order by g.first_date, g.grp;
