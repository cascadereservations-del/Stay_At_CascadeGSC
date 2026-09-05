begin;
select plan(18);

select has_column('public', 'automation_delivery_log', 'callback_id', 'delivery callbacks have a stable id');
select has_function(
  'public', 'record_automation_delivery_callback',
  array['text','uuid','text','text','text','text','text','text'],
  'idempotent delivery callback RPC exists'
);
select ok(has_function_privilege('service_role', 'public.record_automation_delivery_callback(text,uuid,text,text,text,text,text,text)', 'execute'), 'service delivery adapter may record callback');
select ok(not has_function_privilege('authenticated', 'public.record_automation_delivery_callback(text,uuid,text,text,text,text,text,text)', 'execute'), 'clients cannot record delivery callback');

insert into public.properties (id, name, is_active)
values ('71000000-0000-4000-8000-000000000001', 'Synthetic Delivery Property', true)
on conflict (id) do nothing;
insert into public.booking_inquiries (
  id, property_id, guest_name, guest_email, guest_phone, checkin_date,
  checkout_date, source, status, total_amount, deposit_amount
) values (
  '73000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000001',
  'Synthetic Delivery Guest', 'delivery@example.invalid', '000-DELIVERY',
  current_date + 90, current_date + 92, 'direct', 'pending', 5000, 2500
);

select set_config('cascade.d_outbox', (
  select id::text from public.automation_outbox
  where idempotency_key = 'booking.requested:73000000-0000-4000-8000-000000000001'
), true);
select is((select route_class from public.automation_outbox where id = current_setting('cascade.d_outbox')::uuid), 'finance', 'booking request routes to Finance');
select is((select template_key from public.automation_outbox where id = current_setting('cascade.d_outbox')::uuid), 'finance.booking_requested', 'Finance template is closed');
select ok((select payload ? 'total_amount' from public.automation_outbox where id = current_setting('cascade.d_outbox')::uuid), 'Finance payload may contain amount');
select ok(not (select payload ? 'guest_email' or payload ? 'guest_phone' from public.automation_outbox where id = current_setting('cascade.d_outbox')::uuid), 'outbox does not copy guest contact');

update public.booking_inquiries set status = 'confirmed'
where id = '73000000-0000-4000-8000-000000000001';
select is((select route_class from public.automation_outbox where idempotency_key = 'booking.confirmed:73000000-0000-4000-8000-000000000001'), 'guest', 'confirmation routes to guest delivery');
select ok(not (select payload ? 'total_amount' or payload ? 'deposit_amount' from public.automation_outbox where idempotency_key = 'booking.confirmed:73000000-0000-4000-8000-000000000001'), 'guest payload excludes Finance fields');

set local role service_role;
select is(
  public.record_automation_delivery_callback(
    'CH-W01:email:synthetic-0001', current_setting('cascade.d_outbox')::uuid,
    'CH-W01','email','sent','recipient_hash','provider-1',null
  )->>'duplicate',
  'false',
  'first callback records delivery'
);
select is(
  public.record_automation_delivery_callback(
    'CH-W01:email:synthetic-0001', current_setting('cascade.d_outbox')::uuid,
    'CH-W01','email','sent','recipient_hash','provider-1',null
  )->>'duplicate',
  'true',
  'callback retry is idempotent'
);
reset role;

select is((select count(*) from public.automation_delivery_log where callback_id = 'CH-W01:email:synthetic-0001'), 1::bigint, 'callback has one delivery row');
select is((select attempt_count from public.automation_outbox where id = current_setting('cascade.d_outbox')::uuid), 1, 'callback retry does not increment attempt twice');
select is((select status from public.automation_outbox where id = current_setting('cascade.d_outbox')::uuid), 'dispatched', 'provider callback leaves workflow dispatchable');
select is((select status from public.booking_inquiries where id = '73000000-0000-4000-8000-000000000001'), 'confirmed', 'delivery callback does not alter booking state');
select is((select count(*) from public.payment_finance_reviews where booking_id = '73000000-0000-4000-8000-000000000001'), 0::bigint, 'delivery callback cannot fabricate Finance review');
select throws_ok(
  $$select public.record_automation_delivery_callback(
    'invalid-workflow-callback-1', current_setting('cascade.d_outbox')::uuid,
    'CH-W99','email','sent',null,null,null
  )$$,
  '22023', null, 'unknown workflow fails closed'
);

select * from finish();
rollback;
