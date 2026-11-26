-- s138 payment rule: 20261208000000 (rate card deposit_pct 50 -> 100) and 20261208000100 (house_facts PIN wording). Synthetic rows only; everything rolls back.
-- The suite runs each migration's guarded statement against fixtures (a throwaway property with three versions, and throwaway house_facts topics), because the real rows differ per database.
begin;
select plan(11);

insert into auth.users (id, instance_id, aud, role, email) values ('e1380000-0000-4000-8000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 's138@example.invalid') on conflict do nothing;
insert into public.properties (id, name) values ('e1380000-0000-4000-8000-0000000000b1', 's138 fixture') on conflict do nothing;
insert into public.booking_rate_policy_versions (property_id, effective_from, effective_to, nightly_rate, terms, approved_by, idempotency_key) values
 ('e1380000-0000-4000-8000-0000000000b1', date '2020-01-01', date '2020-12-31', 1000, '{"tiers":[],"deposit_pct":50}', 'e1380000-0000-4000-8000-0000000000a1', 's138-test-key-past-00001'),
 ('e1380000-0000-4000-8000-0000000000b1', date '2021-01-01', date '2999-12-30', 1780, '{"tiers":[],"deposit_pct":50}', 'e1380000-0000-4000-8000-0000000000a1', 's138-test-key-live-00001'),
 ('e1380000-0000-4000-8000-0000000000b1', date '2999-12-31', null,              1900, '{"tiers":[],"deposit_pct":50}', 'e1380000-0000-4000-8000-0000000000a1', 's138-test-key-next-00001');

select is((select count(*)::int from public.booking_rate_policy_versions where property_id = 'e1380000-0000-4000-8000-0000000000b1' and terms ->> 'deposit_pct' = '50'), 3, 'fixture: three versions at 50');

-- the migration's update, pointed at the fixture property
update public.booking_rate_policy_versions
   set terms = jsonb_set(terms, '{deposit_pct}', '100'::jsonb, true)
 where property_id = 'e1380000-0000-4000-8000-0000000000b1'
   and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
   and coalesce(terms ->> 'deposit_pct', '50')::numeric = 50;

select is((select (terms ->> 'deposit_pct')::int from public.booking_rate_policy_versions where idempotency_key = 's138-test-key-live-00001'), 100, 'the live version now reads 100');
select is((select (terms ->> 'deposit_pct')::int from public.booking_rate_policy_versions where idempotency_key = 's138-test-key-next-00001'), 100, 'the scheduled version now reads 100');
select is((select (terms ->> 'deposit_pct')::int from public.booking_rate_policy_versions where idempotency_key = 's138-test-key-past-00001'), 50, 'the past version keeps 50');
select is((select terms -> 'tiers' from public.booking_rate_policy_versions where idempotency_key = 's138-test-key-live-00001'), '[]'::jsonb, 'tiers untouched');
select is((select nightly_rate from public.booking_rate_policy_versions where idempotency_key = 's138-test-key-live-00001'), 1780.00, 'rate untouched');

-- the rollback statement puts the live and scheduled versions back
update public.booking_rate_policy_versions
   set terms = jsonb_set(terms, '{deposit_pct}', '50'::jsonb, true)
 where property_id = 'e1380000-0000-4000-8000-0000000000b1'
   and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
   and coalesce(terms ->> 'deposit_pct', '50')::numeric = 100;
select is((select count(*)::int from public.booking_rate_policy_versions where property_id = 'e1380000-0000-4000-8000-0000000000b1' and terms ->> 'deposit_pct' = '50'), 3, 'rollback restores 50 on all three');

-- house_facts: the guard comparison and the replacement wording
insert into public.house_facts (topic, title, body, tier) values
 ('zz-s138-prospect', 't', $b$Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you.$b$, 'public'),
 ('zz-s138-edited',   't', $b$Edited since the seed.$b$, 'public');
select ok((select body is not distinct from $b$Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you.$b$ from public.house_facts where topic = 'zz-s138-prospect'), 'guard comparison: the seeded text matches');
select ok((select body is distinct from $b$Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you.$b$ from public.house_facts where topic = 'zz-s138-edited'), 'guard comparison: an edited row does not match, so the migration would stop');
update public.house_facts set body = replace(body, 'once IDs and the balance are in', 'once your payment, your IDs and the PHP 800 refundable security deposit are in') where topic = 'zz-s138-prospect';
select ok((select body like '%PHP 800 refundable security deposit are in%' and body not like '%the balance%' from public.house_facts where topic = 'zz-s138-prospect'), 'new wording names payment, IDs and the PHP 800 deposit and no balance');
select ok(not exists (select 1 from public.house_facts where topic in ('smart-lock-prospect', 'smart-lock-staff') and body like '%PHP 800%' and body like '%the balance%'), 'no live row mixes the two wordings');

select * from finish();
rollback;
