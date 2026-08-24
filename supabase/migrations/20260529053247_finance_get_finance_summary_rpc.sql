-- Monthly finance summary for the owner dashboard.
-- Counts CONFIRMED only (pending_review OCR rows are excluded until a human clears them).
-- p_month: any date inside the target month (defaults to current Manila month).
create or replace function public.get_finance_summary(
  p_month       date default ((now() at time zone 'Asia/Manila')::date),
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
)
returns jsonb
language sql
security invoker
set search_path = ''
stable
as $$
  with bounds as (
    select date_trunc('month', p_month)::date as m_start,
           (date_trunc('month', p_month) + interval '1 month')::date as m_next
  ),
  scoped as (
    select t.txn_type, t.category, t.gross_amount
    from public.transactions t, bounds b
    where t.property_id = p_property_id
      and t.status = 'confirmed'
      and t.transaction_date >= b.m_start
      and t.transaction_date <  b.m_next
  ),
  totals as (
    select
      coalesce(sum(gross_amount) filter (where txn_type = 'income'),  0) as income,
      coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) as expenses
    from scoped
  ),
  by_cat as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'category', x.category,
             'label',    coalesce(ec.label, initcap(replace(x.category,'_',' '))),
             'txn_type', x.txn_type,
             'total',    x.total,
             'count',    x.cnt
           ) order by x.total desc), '[]'::jsonb) as rows
    from (
      select txn_type, category, sum(gross_amount) as total, count(*) as cnt
      from scoped group by txn_type, category
    ) x
    left join public.expense_categories ec
      on ec.slug = x.category and ec.property_id = p_property_id
  ),
  pending as (
    select count(*) as cnt
    from public.transactions t, bounds b
    where t.property_id = p_property_id
      and t.status = 'pending_review'
      and t.transaction_date >= b.m_start
      and t.transaction_date <  b.m_next
  )
  select jsonb_build_object(
    'month',          to_char((select m_start from bounds), 'YYYY-MM'),
    'property_id',    p_property_id,
    'currency',       'PHP',
    'income',         (select income   from totals),
    'expenses',       (select expenses from totals),
    'net',            (select income - expenses from totals),
    'by_category',    (select rows from by_cat),
    'pending_review', (select cnt from pending)
  );
$$;

revoke all on function public.get_finance_summary(date, uuid) from public, anon;
grant execute on function public.get_finance_summary(date, uuid) to authenticated, service_role;;
