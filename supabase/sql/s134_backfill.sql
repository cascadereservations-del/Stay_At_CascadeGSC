-- s134 stock-to-expense back-fill (D-405). One-off, reviewed SQL, additive, idempotent. NOT a schema migration: run it AFTER the s134 migration, with
-- scripts/recovery run-sql-on-host.sh, only after Lloyd has seen the preview (supabase/sql/s134_backfill_preview.sql) and said yes.
-- What it does, for stock bought on or after the start date (default 2026-08-01; override in the same session with:  set s134.start_date = '2026-09-01';):
--   B1  gives every legacy purchase its expense_group (same rule as the insert trigger).
--   B2  links purchases to an expense that already exists: "(txn <uuid>)" in the note, or the scanned draft's own transaction.
--   B4  for each group whose purchases are ALL unlinked, priced somewhere, and with no stock:<group> row of any status: ONE pending_review row
--       (source inventory, category supplies, external_ref stock:<group>, logged_by system), then links the group's purchases to it.
-- It NEVER confirms a row and never guesses: a human approves each one in Expenses. A look-alike (same house, supplies/maintenance/repairs, within 3 days,
-- not itself linked to stock) is flagged in the note with " [possible duplicate]". Running it twice changes nothing (the second run finds every group linked).
-- Undo of the data: void the rows whose external_ref starts with 'stock:' and whose note contains '[back-fill s134]' (admin soft delete), nothing else.
begin;
-- BACKFILL-BEGIN
do $bf$
declare
  v_from date := coalesce(nullif(current_setting('s134.start_date', true), ''), '2026-08-01')::date;
  g record; v_new uuid; v_names text[]; v_note text; v_dup boolean; v_made integer := 0; v_b1 integer; v_b2 integer; v_b2b integer;
begin
  -- B1
  update public.inventory_purchases p set expense_group = public.s_stock_expense_group_of_v1(p.id, p.notes) where p.expense_group is null;
  get diagnostics v_b1 = row_count;
  -- B2
  update public.inventory_purchases p set transaction_id = t.id
    from public.transactions t
   where p.transaction_id is null and t.id = public.s_stock_expense_txn_of_v1(p.notes);
  get diagnostics v_b2 = row_count;
  update public.inventory_purchases p set transaction_id = d.transaction_id
    from public.inventory_receipt_drafts d
   where p.transaction_id is null and p.expense_group = 'draft:' || d.id::text and d.transaction_id is not null
     and exists (select 1 from public.transactions t where t.id = d.transaction_id);
  get diagnostics v_b2b = row_count;
  -- B4
  for g in
    select p.expense_group as grp, (array_agg(i.property_id))[1] as prop, min(p.purchased_at) as first_date,
           round(coalesce(sum(p.qty * p.unit_cost) filter (where p.unit_cost > 0), 0), 2) as priced_sum,
           count(*) as n, count(*) filter (where p.unit_cost > 0) as priced,
           count(distinct nullif(btrim(p.supplier), '')) as nsup, min(nullif(btrim(p.supplier), '')) as sup
      from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
     where p.expense_group is not null
     group by p.expense_group
    having bool_and(p.transaction_id is null) and min(p.purchased_at) >= v_from and count(*) filter (where p.unit_cost > 0) > 0
       and not exists (select 1 from public.transactions t where t.external_ref = 'stock:' || p.expense_group and t.txn_type = 'expense')
     order by min(p.purchased_at), p.expense_group
  loop
    declare
      v_total numeric := (select round(d.total, 2) from public.inventory_receipt_drafts d where g.grp like 'draft:%' and d.id::text = substr(g.grp, 7) and d.total > 0);
      v_amt numeric; v_incomplete boolean;
    begin
      v_amt := coalesce(v_total, g.priced_sum);
      v_incomplete := v_total is null and g.priced < g.n;
      continue when v_amt is null or v_amt <= 0;
      select array_agg(x.name order by x.first_at, x.name) into v_names
        from (select i.name, min(p.created_at) first_at from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id where p.expense_group = g.grp group by i.name) x;
      v_dup := exists (select 1 from public.transactions o
                        where o.property_id = g.prop and o.txn_type = 'expense' and o.status <> 'void' and o.category in ('supplies', 'maintenance', 'repairs')
                          and o.source not in ('airbnb', 'airbnb_email') and abs(o.transaction_date - g.first_date) <= 3
                          and not exists (select 1 from public.inventory_purchases ip where ip.transaction_id = o.id));
      v_note := 'Stock bought: ' || array_to_string(v_names[1:3], ', ') || case when array_length(v_names, 1) > 3 then ' (+' || (array_length(v_names, 1) - 3) || ' more)' else '' end
                || case when g.nsup >= 2 then ' - Several suppliers' else '' end
                || case when v_incomplete then ' - amount incomplete' else '' end
                || ' [back-fill s134]' || case when v_dup then ' [possible duplicate]' else '' end;
      perform public.admin_audit_context_v1('s134 back-fill', null, null);
      insert into public.transactions (property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by, ocr_raw)
      values (g.prop, 'expense', 'supplies', 'pending_review', 'inventory', g.first_date, v_amt, 'PHP', case when g.nsup = 1 then g.sup end, v_note, 'stock:' || g.grp, 'system',
              jsonb_build_object('s134_auto', false, 's134_amount', v_amt, 's134_group', g.grp, 's134_backfill', true))
      returning id into v_new;
      perform public.admin_audit_context_v1('', null, null);
      update public.inventory_purchases set transaction_id = v_new where expense_group = g.grp and transaction_id is null;
      v_made := v_made + 1;
    end;
  end loop;
  raise notice 's134 back-fill: % purchase(s) given a group, % linked to an existing expense, % pending_review row(s) created', v_b1, v_b2 + v_b2b, v_made;
end
$bf$;
-- BACKFILL-END
commit;
