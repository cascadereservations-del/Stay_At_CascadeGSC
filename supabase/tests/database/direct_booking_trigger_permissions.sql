begin;

select plan(4);

select ok(
  exists (
    select 1
    from pg_proc
    where oid = 'public.fn_direct_booking_cascade()'::regprocedure
      and prorettype = 'trigger'::regtype
  ),
  'direct booking cascade remains a trigger function'
);
select ok(not has_function_privilege('anon', 'public.fn_direct_booking_cascade()', 'execute'), 'anon cannot call trigger function');
select ok(not has_function_privilege('authenticated', 'public.fn_direct_booking_cascade()', 'execute'), 'authenticated cannot call trigger function');
select ok(not has_function_privilege('service_role', 'public.fn_direct_booking_cascade()', 'execute'), 'service role cannot call trigger function');

select * from finish();

rollback;
