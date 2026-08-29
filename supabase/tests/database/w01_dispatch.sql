begin;
select plan(7);

select ok(
  to_regprocedure('public.dispatch_w01_booking_requested()') is not null,
  'W01 dispatcher trigger function exists'
);

select ok(
  not has_function_privilege('anon', 'public.dispatch_w01_booking_requested()', 'execute'),
  'anonymous clients cannot execute the trigger function as an RPC'
);

select ok(
  not has_function_privilege('authenticated', 'public.dispatch_w01_booking_requested()', 'execute'),
  'authenticated clients cannot execute the trigger function as an RPC'
);

select ok(
  not has_function_privilege('service_role', 'public.dispatch_w01_booking_requested()', 'execute'),
  'service role cannot bypass the outbox by executing the trigger function'
);

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.automation_outbox'::regclass
      and tgname = 'automation_outbox_dispatch_w01'
      and not tgisinternal
  ),
  'automation outbox has the W01 dispatcher trigger'
);

insert into public.automation_outbox (
  id,
  event_type,
  aggregate_type,
  aggregate_id,
  idempotency_key,
  payload
)
values (
  '22222222-2222-4222-8222-222222222222',
  'booking.requested',
  'booking_inquiry',
  '11111111-1111-4111-8111-111111111111',
  'booking.requested:dispatcher-synthetic',
  '{"schema_version": 1}'::jsonb
);

select ok(
  exists (
    select 1 from public.automation_outbox
    where id = '22222222-2222-4222-8222-222222222222'::uuid
      and status = 'pending'
  ),
  'dispatch attempt never prevents durable pending outbox storage'
);

select ok(
  position('X-Cascade-Webhook-Secret' in pg_get_functiondef('public.dispatch_w01_booking_requested()'::regprocedure)) > 0
  and position('CF-Access-Client-Secret' in pg_get_functiondef('public.dispatch_w01_booking_requested()'::regprocedure)) > 0,
  'dispatcher uses the required n8n and Cloudflare authentication headers'
);

select * from finish();
rollback;
