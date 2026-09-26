-- Session 55: release rate_card_upcoming_20260926 (SPEC-34 review finding 1). A card published to start later is listed
-- in `upcoming`, today's card is unchanged, and a hold stamps the version in force on its CHECK-IN date.
begin;
select plan(8);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000056', 'Synthetic Rate Card 56', true);
insert into auth.users(id) values ('e2000000-0000-4000-8000-000000000561');
insert into public.staff_access_profiles(user_id, role) values ('e2000000-0000-4000-8000-000000000561', 'owner');
create temp table t56 (k text primary key, id uuid);
grant all on t56 to authenticated;

select set_config('request.jwt.claims', json_build_object('sub', 'e2000000-0000-4000-8000-000000000561', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into t56 select 'v1', public.publish_rate_card_v1(1800, '[{"min_nights":3,"pct":10}]', (now() at time zone 'Asia/Manila')::date, 'pgTAP s56 v1', 'pgtap-s56-v1-0000000000', 50, 'e1000000-0000-4000-8000-000000000056');
insert into t56 select 'v2', public.publish_rate_card_v1(1900, '[{"min_nights":4,"pct":12}]', (now() at time zone 'Asia/Manila')::date + 10, 'pgTAP s56 v2', 'pgtap-s56-v2-0000000000', 40, 'e1000000-0000-4000-8000-000000000056');

select is((public.get_rate_card_v1('e1000000-0000-4000-8000-000000000056') ->> 'base')::numeric, 1800::numeric, 'today''s card is still the one in force today');
select is(jsonb_array_length(public.get_rate_card_v1('e1000000-0000-4000-8000-000000000056') -> 'upcoming'), 1, 'the card scheduled later is listed as upcoming');
select is(public.get_rate_card_v1('e1000000-0000-4000-8000-000000000056') -> 'upcoming' -> 0,
  jsonb_build_object('effective_from', (now() at time zone 'Asia/Manila')::date + 10, 'base', 1900, 'deposit_pct', 40,
    'tiers', '[{"min_nights":4,"pct":12}]'::jsonb, 'version_id', (select id from t56 where k = 'v2')),
  'upcoming carries its start, base, fee and tiers');
select is(jsonb_array_length(public.get_rate_card_v1() -> 'upcoming'), 0, 'the production card has nothing scheduled');
select ok(has_function_privilege('anon', 'public.get_rate_card_v1(uuid)', 'execute'), 'anyone may still read the card');

reset role;
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, status, source, total_amount, deposit_amount)
values ('ea560000-0000-4000-8000-00000000000a', 'e1000000-0000-4000-8000-000000000056', 'Synthetic Early 56', '09170000056', current_date + 3, current_date + 5, 'pending', 'direct', 3600, 3600),
       ('ea560000-0000-4000-8000-00000000000b', 'e1000000-0000-4000-8000-000000000056', 'Synthetic Late 56', '09170000057', current_date + 40, current_date + 42, 'pending', 'direct', 3800, 1520);
select ok((public.open_booking_hold_v1('ea560000-0000-4000-8000-00000000000a', 24) ->> 'ok')::boolean
      and (public.open_booking_hold_v1('ea560000-0000-4000-8000-00000000000b', 24) ->> 'ok')::boolean, 'both holds open');
select is((select rate_policy_version_id from public.booking_holds where booking_id = 'ea560000-0000-4000-8000-00000000000a'), (select id from t56 where k = 'v1'),
  'a hold before the new card starts stamps today''s card');
select is((select rate_policy_version_id from public.booking_holds where booking_id = 'ea560000-0000-4000-8000-00000000000b'), (select id from t56 where k = 'v2'),
  'a hold after the new card starts stamps the new card');

select * from finish();
rollback;
