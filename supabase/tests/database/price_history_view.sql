begin;

select plan(3);

select has_view('public', 'price_history_by_item', 'price history view exists');

select lives_ok(
  $$select * from public.price_history_by_item limit 1$$,
  'price history view does not recurse'
);

select ok(
  pg_get_viewdef(to_regclass('public.price_history_by_item'), true) like '%inventory_purchases%',
  'price history view reads inventory purchases'
);

select * from finish();
rollback;
