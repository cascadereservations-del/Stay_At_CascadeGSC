begin;

select plan(12);

select ok(
  coalesce((select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.v_direct_bookings'::regclass), false),
  'direct bookings view uses invoker security'
);
select ok(
  coalesce((select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.v_direct_state_desync'::regclass), false),
  'direct state desync view uses invoker security'
);
select ok(
  coalesce((select reloptions @> array['security_invoker=true'] from pg_class where oid = 'public.v_status_desync_wide'::regclass), false),
  'wide status desync view uses invoker security'
);

select ok(not has_table_privilege('anon', 'public.v_direct_bookings', 'select'), 'anon cannot read direct bookings view');
select ok(not has_table_privilege('anon', 'public.v_direct_state_desync', 'select'), 'anon cannot read direct state desync view');
select ok(not has_table_privilege('anon', 'public.v_status_desync_wide', 'select'), 'anon cannot read wide status desync view');

select ok(not has_table_privilege('authenticated', 'public.v_direct_bookings', 'select'), 'authenticated cannot read direct bookings view');
select ok(not has_table_privilege('authenticated', 'public.v_direct_state_desync', 'select'), 'authenticated cannot read direct state desync view');
select ok(not has_table_privilege('authenticated', 'public.v_status_desync_wide', 'select'), 'authenticated cannot read wide status desync view');

select ok(has_table_privilege('service_role', 'public.v_direct_bookings', 'select'), 'service role can read direct bookings view');
select ok(has_table_privilege('service_role', 'public.v_direct_state_desync', 'select'), 'service role can read direct state desync view');
select ok(has_table_privilege('service_role', 'public.v_status_desync_wide', 'select'), 'service role can read wide status desync view');

select * from finish();

rollback;
