-- Session 72, SPEC-42 9a: payer columns on booking_inquiries and the refund_confirm pending kind.
-- Synthetic property and booking only (public repo); inside begin/rollback.
begin;
select plan(14);

select is((select count(*)::int from information_schema.columns where table_schema = 'public' and table_name = 'booking_inquiries'
            and column_name in ('paid_from_name', 'paid_from_channel') and data_type = 'text' and is_nullable = 'YES' and column_default is null), 2,
  'both payer columns exist, text, nullable, no default');

insert into public.properties(id, name, is_active) values ('e7a00000-0000-4000-8000-0000000000a1', 'Synthetic Refund Destination', true);
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status) values
  ('e7a10000-0000-4000-8000-0000000000a1', 'e7a00000-0000-4000-8000-0000000000a1', 'Synthetic Guest A', '0000000000', current_date + 10, current_date + 12, 'direct', 'confirmed'),
  ('e7a10000-0000-4000-8000-0000000000a2', 'e7a00000-0000-4000-8000-0000000000a1', 'Synthetic Guest B', '0000000000', current_date + 20, current_date + 22, 'direct', 'confirmed');

select is((select paid_from_name from public.booking_inquiries where id = 'e7a10000-0000-4000-8000-0000000000a1'), null, 'a booking starts with no payer on record');

select lives_ok($$update public.booking_inquiries set paid_from_name = 'Synthetic Payer', paid_from_channel = 'GCash' where id = 'e7a10000-0000-4000-8000-0000000000a1'$$,
  'the payer can be stored');
select is((select paid_from_name || ' / ' || paid_from_channel from public.booking_inquiries where id = 'e7a10000-0000-4000-8000-0000000000a1'), 'Synthetic Payer / GCash', 'the payer reads back');

-- The Edge function writes with ".is(paid_from_name, null)": the second receipt does not change the first payer.
select lives_ok($$update public.booking_inquiries set paid_from_name = 'Someone Else', paid_from_channel = 'Maya'
                   where id = 'e7a10000-0000-4000-8000-0000000000a1' and paid_from_name is null$$, 'the guarded write for a second receipt runs');
select is((select paid_from_name || ' / ' || paid_from_channel from public.booking_inquiries where id = 'e7a10000-0000-4000-8000-0000000000a1'), 'Synthetic Payer / GCash',
  'the first payer is still there: the guarded write found no row');
select lives_ok($$update public.booking_inquiries set paid_from_name = 'Synthetic Second', paid_from_channel = null
                   where id = 'e7a10000-0000-4000-8000-0000000000a2' and paid_from_name is null$$, 'the guarded write for a first receipt runs');
select is((select paid_from_name || ' / ' || coalesce(paid_from_channel, 'none') from public.booking_inquiries where id = 'e7a10000-0000-4000-8000-0000000000a2'), 'Synthetic Second / none',
  'the guarded write landed on the booking with no payer yet, with a null channel');

select throws_ok($$update public.booking_inquiries set paid_from_name = '' where id = 'e7a10000-0000-4000-8000-0000000000a2'$$, '23514', null, 'an empty payer name is refused');
select throws_ok($$update public.booking_inquiries set paid_from_name = repeat('x', 81) where id = 'e7a10000-0000-4000-8000-0000000000a2'$$, '23514', null, 'a payer name over 80 characters is refused');
select throws_ok($$update public.booking_inquiries set paid_from_channel = repeat('x', 41) where id = 'e7a10000-0000-4000-8000-0000000000a2'$$, '23514', null, 'a channel over 40 characters is refused');

-- F1: /refund saves a refund_confirm row before it shows Confirm; the kind CHECK must accept it.
select lives_ok($$insert into public.telegram_pending(chat_id, kind, payload) values (-900000072, 'refund_confirm', '{"synthetic":true}'::jsonb)$$,
  'pending: refund_confirm is accepted by the kind CHECK');

-- The rollback body runs cleanly and removes the columns.
select lives_ok($$
  alter table public.booking_inquiries drop constraint if exists booking_inquiries_paid_from_name_len_check;
  alter table public.booking_inquiries drop constraint if exists booking_inquiries_paid_from_channel_len_check;
  alter table public.booking_inquiries drop column if exists paid_from_name, drop column if exists paid_from_channel;
$$, 'the rollback body runs cleanly');
select is((select count(*)::int from information_schema.columns where table_schema = 'public' and table_name = 'booking_inquiries' and column_name like 'paid_from%'), 0, 'rollback dropped both columns');

select * from finish();
rollback;
