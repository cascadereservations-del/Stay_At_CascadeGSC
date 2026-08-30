begin;
select plan(16);
select has_column('public', 'cleaning_sessions', 'submitted_by_user_id', 'cleaning sessions record named submitter');
select has_column('public', 'meter_readings', 'submitted_by_user_id', 'meter readings record named submitter');
select has_column('public', 'inventory_usage', 'property_id', 'inventory usage is property scoped');
select has_column('public', 'inventory_usage', 'submitted_by_user_id', 'inventory usage records named submitter');
select has_table('public', 'cleaning_expense_claims', 'expense review queue exists');
select ok(not has_table_privilege('anon', 'public.inventory_usage', 'select'), 'anon cannot read inventory usage');
select ok(not has_table_privilege('anon', 'public.inventory_usage', 'insert'), 'anon cannot write inventory usage');
select ok(has_table_privilege('authenticated', 'public.inventory_usage', 'select'), 'authenticated staff may enter guarded inventory read');
select ok(has_table_privilege('authenticated', 'public.inventory_usage', 'insert'), 'authenticated cleaners may enter guarded inventory write');
select ok(not has_table_privilege('anon', 'public.cleaning_expense_claims', 'select'), 'anon cannot read expense claims');
select ok(not has_table_privilege('authenticated', 'public.cleaning_expense_claims', 'insert'), 'clients cannot directly create expense claims');
select ok(has_table_privilege('service_role', 'public.cleaning_expense_claims', 'insert'), 'authorized Edge Function may create pending claim');
select col_not_null('public', 'inventory_usage', 'property_id', 'inventory usage property is required');
select results_eq(
  $$select public from storage.buckets where id = 'cleaning-photos'$$,
  array[false],
  'cleaning photo bucket is private'
);
select results_eq(
  $$select count(*)::bigint from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname in ('anon read cleaning photos','anon upload cleaning photos','public_read_cleaning_photos')$$,
  array[0::bigint],
  'public cleaning-photo policies are removed'
);
select results_eq(
  $$select count(*)::bigint from pg_policies where schemaname = 'public' and tablename = 'inventory_usage' and policyname = 'inventory_usage_staff_insert'$$,
  array[1::bigint],
  'inventory usage has one guarded cleaner insert policy'
);
select * from finish();
rollback;
