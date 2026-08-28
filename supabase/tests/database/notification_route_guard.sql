begin;
select plan(8);

select has_column('public', 'automation_outbox', 'route_class', 'outbox declares a route class');
select has_column('public', 'automation_outbox', 'template_key', 'outbox declares a template key');
select has_check('public', 'automation_outbox', 'automation_outbox_ops_payload_guard', 'outbox OPS payload guard exists');

select lives_ok(
  $$insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, route_class, template_key, payload)
    values ('booking.confirmed', 'booking_inquiry', '11111111-1111-4111-8111-111111111111', 'ops-safe', 'ops', 'ops.arrival_advisory', '{"booking_ref":"ABC12345","checkin_date":"2026-09-01"}')$$,
  'safe OPS payload enters the outbox'
);

select throws_ok(
  $$insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, route_class, template_key, payload)
    values ('booking.confirmed', 'booking_inquiry', '11111111-1111-4111-8111-111111111112', 'ops-nested-amount', 'ops', 'ops.arrival_advisory', '{"metadata":{"payment":{"amount":1780,"currency":"PHP"}}}')$$,
  '23514',
  null,
  'nested amount and currency are rejected from OPS'
);

select throws_ok(
  $$insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, route_class, template_key, payload)
    values ('booking.confirmed', 'booking_inquiry', '11111111-1111-4111-8111-111111111113', 'ops-free-text', 'ops', 'ops.arrival_advisory', '{"notes":"guest paid PHP 1780 through the bank"}')$$,
  '23514',
  null,
  'financial free text is rejected from OPS'
);

select lives_ok(
  $$insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, route_class, template_key, payload)
    values ('booking.receipt_uploaded', 'booking_inquiry', '11111111-1111-4111-8111-111111111114', 'finance-payment', 'finance', 'finance.payment_review', '{"amount":1780,"currency":"PHP","receipt_url":"private/path"}')$$,
  'Finance payload may contain reviewed payment fields'
);

select throws_ok(
  $$insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, route_class, template_key, payload)
    values ('booking.confirmed', 'booking_inquiry', '11111111-1111-4111-8111-111111111115', 'invalid-route', 'public', 'ops.arrival_advisory', '{}')$$,
  '23514',
  null,
  'unknown route classes are rejected'
);

select * from finish();
rollback;
