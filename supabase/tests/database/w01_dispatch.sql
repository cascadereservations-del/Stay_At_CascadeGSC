begin;
select plan(4);

-- s78 (TASKS #19): the W01 dispatcher was dropped by 20261009010000_drop_w01_dispatch.sql; nothing consumes n8n W01.
select ok(
  to_regprocedure('public.dispatch_w01_booking_requested()') is null,
  'W01 dispatcher function is gone'
);

select ok(
  not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.automation_outbox'::regclass
      and tgname = 'automation_outbox_dispatch_w01'
      and not tgisinternal
  ),
  'automation outbox has no W01 dispatcher trigger'
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
  'a booking.requested outbox insert still succeeds and stays pending'
);

select ok(
  not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.automation_outbox'::regclass and not tgisinternal
      and tgfoid::regproc::text like '%w01%'
  ),
  'no remaining outbox trigger calls a W01 function'
);

select * from finish();
rollback;
