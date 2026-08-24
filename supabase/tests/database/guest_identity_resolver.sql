begin;
select plan(4);

insert into public.guests (id, property_id, name, phone_e164, source)
values ('22222222-2222-4222-8222-222222222222', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Synthetic One', '+639171234567', 'direct');
insert into public.guests (id, property_id, name, email_normalized, source)
values ('33333333-3333-4333-8333-333333333333', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Synthetic Two', 'synthetic@example.test', 'direct');
insert into public.booking_inquiries (id, guest_name, checkin_date, checkout_date, source, status)
values ('44444444-4444-4444-8444-444444444444', 'Same Name Is Not Identity', current_date + 20, current_date + 22, 'direct', 'pending');

select is((select guest_id from public.upsert_guest_for_booking('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd','44444444-4444-4444-8444-444444444444','Same Name Is Not Identity','+639171234567',null,'direct')), '22222222-2222-4222-8222-222222222222'::uuid, 'phone resolves the existing guest');
select is((select match_basis from public.upsert_guest_for_booking('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd','44444444-4444-4444-8444-444444444444','Same Name Is Not Identity','+639171234567','synthetic@example.test','direct')), 'conflict', 'cross-match returns conflict instead of merge');
select is((select count(*) from public.guest_identity_conflicts where booking_key='44444444-4444-4444-8444-444444444444'), 1::bigint, 'cross-match creates one open conflict');
select is((select count(*) from public.guests where name='Same Name Is Not Identity'), 0::bigint, 'same name does not create or merge a guest');

select * from finish();
rollback;
