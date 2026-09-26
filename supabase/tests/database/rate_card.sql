-- Session 55: release rate_card_20260926 (SPEC-34, D-259, D-261, D-262).
-- The seeded card and promotion, the public read, who may write, overlap refusal, publish closing the open version,
-- and the hold stamp. Publishing and holds use a synthetic property; promotions use 2027 dates (the no-overlap
-- constraint spans properties). Every fixture goes with the closing rollback.
begin;
select plan(23);

-- Seed (production property).
select is((public.get_rate_card_v1() ->> 'base')::numeric, 1780::numeric, 'the seeded base is PHP 1,780');
select is(public.get_rate_card_v1() -> 'tiers',
  '[{"min_nights":2,"pct":5},{"min_nights":5,"pct":10},{"min_nights":7,"pct":15},{"min_nights":14,"pct":20},{"min_nights":28,"pct":25}]'::jsonb,
  'the seeded tiers are 5/10/15/20/25% at 2/5/7/14/28 nights');
select is((public.get_rate_card_v1() ->> 'deposit_pct')::numeric, 50::numeric, 'the seeded fee is 50%');
select ok(exists (select 1 from jsonb_array_elements(public.get_rate_card_v1() -> 'promotions') p
                  where p ->> 'name' = 'Anniversary Promotion' and p ->> 'first_night' = '2026-10-11'
                    and p ->> 'last_night' = '2026-10-17' and (p ->> 'nightly_rate')::numeric = 1543)
          or (now() at time zone 'Asia/Manila')::date > date '2026-10-17',
  'the Anniversary Promotion is on the card: PHP 1,543, nights Oct 11-17 (until it is over)');
select ok(position('1929' in public.get_rate_card_v1()::text) = 0, 'PHP 1,929 is on the card nowhere');

-- Grants.
select ok(has_function_privilege('anon', 'public.get_rate_card_v1(uuid)', 'execute'), 'anyone may read the card');
select ok(not has_function_privilege('anon', 'public.publish_rate_card_v1(numeric,jsonb,date,text,text,numeric,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.save_rate_promotion_v1(uuid,text,date,date,numeric,text,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.end_rate_promotion_v1(uuid,text)', 'execute'),
  'anon writes nothing');
select ok((select relrowsecurity from pg_class where oid = 'public.rate_promotions'::regclass)
      and not has_table_privilege('anon', 'public.rate_promotions', 'select')
      and not has_table_privilege('authenticated', 'public.rate_promotions', 'insert')
      and not has_table_privilege('authenticated', 'public.rate_promotions', 'update'),
  'rate_promotions: RLS on, anon cannot read it, staff write only through the RPCs');

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000055', 'Synthetic Rate Card 55', true);
insert into auth.users(id) values ('e2000000-0000-4000-8000-000000000551'), ('e2000000-0000-4000-8000-000000000552');
insert into public.staff_access_profiles(user_id, role) values ('e2000000-0000-4000-8000-000000000551', 'owner'), ('e2000000-0000-4000-8000-000000000552', 'cleaner');
create temp table t55 (k text primary key, id uuid);
grant all on t55 to authenticated;

-- A cleaner is refused.
select set_config('request.jwt.claims', json_build_object('sub', 'e2000000-0000-4000-8000-000000000552', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select throws_ok($$select public.save_rate_promotion_v1(null, 'Cleaner promo', date '2027-03-01', date '2027-03-03', 1500, 'test', 'e1000000-0000-4000-8000-000000000055')$$,
  '42501', null, 'a cleaner cannot save a promotion');

-- The owner publishes a first card for the synthetic property, then a later one that closes it.
select set_config('request.jwt.claims', json_build_object('sub', 'e2000000-0000-4000-8000-000000000551', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
insert into t55 select 'v1', public.publish_rate_card_v1(1800, '[{"min_nights":3,"pct":10}]', (now() at time zone 'Asia/Manila')::date, 'pgTAP s55 v1', 'pgtap-s55-v1-0000000000', 50, 'e1000000-0000-4000-8000-000000000055');
select is((public.get_rate_card_v1('e1000000-0000-4000-8000-000000000055') ->> 'base')::numeric, 1800::numeric, 'a card published from today is read today');
insert into t55 select 'v2', public.publish_rate_card_v1(1900, '[{"min_nights":3,"pct":10}]', (now() at time zone 'Asia/Manila')::date + 10, 'pgTAP s55 v2', 'pgtap-s55-v2-0000000000', 50, 'e1000000-0000-4000-8000-000000000055');
select is((public.get_rate_card_v1('e1000000-0000-4000-8000-000000000055') ->> 'base')::numeric, 1800::numeric, 'the later card is not quoted before its day');
select is(public.publish_rate_card_v1(1950, '[{"min_nights":3,"pct":10}]', (now() at time zone 'Asia/Manila')::date + 10, 'pgTAP s55 fix', 'pgtap-s55-v2b-000000000', 50, 'e1000000-0000-4000-8000-000000000055'),
  (select id from t55 where k = 'v2'), 'the same start date corrects the open version in place');
select throws_ok($$select public.publish_rate_card_v1(1700, '[]', (now() at time zone 'Asia/Manila')::date + 5, 'pgTAP s55 early', 'pgtap-s55-v3-0000000000', 50, 'e1000000-0000-4000-8000-000000000055')$$,
  '22023', 'a later rate card is already scheduled', 'a date before the scheduled version is refused');
select throws_ok($$select public.publish_rate_card_v1(1700, '[{"min_nights":1,"pct":10}]', (now() at time zone 'Asia/Manila')::date + 20, 'pgTAP s55 bad', 'pgtap-s55-v4-0000000000', 50, 'e1000000-0000-4000-8000-000000000055')$$,
  '22023', 'invalid rate card', 'a tier from 1 night is refused');

-- Promotions.
insert into t55 select 'p1', public.save_rate_promotion_v1(null, 'Test Promo 55', date '2027-03-01', date '2027-03-03', 1500, 'pgTAP s55', 'e1000000-0000-4000-8000-000000000055');
select ok(exists (select 1 from jsonb_array_elements(public.get_rate_card_v1('e1000000-0000-4000-8000-000000000055') -> 'promotions') p
                  where p ->> 'name' = 'Test Promo 55' and (p ->> 'nightly_rate')::numeric = 1500),
  'the owner saves a promotion and the card shows it');
select throws_ok($$select public.save_rate_promotion_v1(null, 'Overlap 55', date '2027-03-03', date '2027-03-05', 1400, 'pgTAP s55', 'e1000000-0000-4000-8000-000000000055')$$,
  '23P01', null, 'an overlapping active promotion is refused');
select ok(public.end_rate_promotion_v1((select id from t55 where k = 'p1'), 'pgTAP s55 end'), 'the owner ends it');
select ok(not exists (select 1 from jsonb_array_elements(public.get_rate_card_v1('e1000000-0000-4000-8000-000000000055') -> 'promotions') p
                      where p ->> 'name' = 'Test Promo 55'),
  'an ended promotion leaves the card at once');
select lives_ok($$select public.save_rate_promotion_v1(null, 'After End 55', date '2027-03-03', date '2027-03-05', 1400, 'pgTAP s55', 'e1000000-0000-4000-8000-000000000055')$$,
  'an ended promotion no longer blocks the dates');

-- Table reads as the owner of the test, not as authenticated (a --no-acl restore has no table grants).
reset role;
select is((select effective_to from public.booking_rate_policy_versions where id = (select id from t55 where k = 'v1')), (now() at time zone 'Asia/Manila')::date + 9,
  'publishing from a later date closes the open version the day before');
select is((select count(*)::int from public.booking_lifecycle_events where property_id = 'e1000000-0000-4000-8000-000000000055'
           and event_type in ('rate_policy_published', 'rate_promotion_saved', 'rate_promotion_ended')), 6,
  'every write is audited: 3 publishes, 2 saves, 1 end');

-- A hold records the card it was opened under.
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, status, source, total_amount, deposit_amount)
values ('ea550000-0000-4000-8000-00000000000a', 'e1000000-0000-4000-8000-000000000055', 'Synthetic Hold 55', '09170000055', current_date + 40, current_date + 42, 'pending', 'direct', 3600, 1800);
select ok((public.open_booking_hold_v1('ea550000-0000-4000-8000-00000000000a', 24) ->> 'ok')::boolean, 'the hold opens');
select is((select rate_policy_version_id from public.booking_holds where booking_id = 'ea550000-0000-4000-8000-00000000000a'), (select id from t55 where k = 'v1'),
  'open_booking_hold_v1 stamps the card version in force');

select * from finish();
rollback;
