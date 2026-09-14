begin;
select plan(15);

select has_table('public','guest_companions','guest_companions table exists');
select has_table('public','guest_companion_history','guest_companion_history table exists');
select has_function('public','save_guest_companion_v1',array['uuid','uuid','jsonb','integer','text'],'save RPC exists');
select has_function('public','delete_guest_companion_v1',array['uuid','text'],'delete RPC exists');
select has_function('public','list_guest_companions_v1',array['uuid'],'list RPC exists');
select ok(not has_table_privilege('anon','public.guest_companions','select'), 'anon cannot read companions');
select ok(not has_function_privilege('anon','public.save_guest_companion_v1(uuid,uuid,jsonb,integer,text)','execute'), 'anon cannot save a companion');
select results_eq(
  $$select public from storage.buckets where id = 'guest-id-photos'$$,
  array[false], 'guest-id-photos bucket is private'
);

-- Synthetic fixtures: one property, an owner and a cleaner, one guest.
insert into public.properties(id,name,is_active) values('f3000000-0000-4000-8000-0000000000a1','Synthetic Companions',true);
insert into auth.users(id) values('f3000000-0000-4000-8000-0000000000a2'),('f3000000-0000-4000-8000-0000000000a3');
insert into public.staff_access_profiles(user_id,role) values('f3000000-0000-4000-8000-0000000000a2','owner'),('f3000000-0000-4000-8000-0000000000a3','cleaner');
insert into public.staff_property_access(user_id,property_id) values('f3000000-0000-4000-8000-0000000000a3','f3000000-0000-4000-8000-0000000000a1');
insert into public.guests(id,property_id,name) values('f3000000-0000-4000-8000-0000000000a4','f3000000-0000-4000-8000-0000000000a1','Synthetic Guest');

-- Cleaner (manage_operations denied) cannot add a companion.
select set_config('request.jwt.claims', json_build_object('sub','f3000000-0000-4000-8000-0000000000a3','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select throws_ok(
  $$select public.save_guest_companion_v1('f3000000-0000-4000-8000-0000000000a4'::uuid, null, '{"name":"Should not save"}'::jsonb, null, 'cleaner attempt')$$,
  '42501','manage_operations denied','cleaner cannot add a companion'
);

-- Owner (manage_operations allowed) adds, then edits, then lists, then deletes a companion.
-- The companion id is stashed via set_config from the RPC's own return value, never read
-- back from the table directly -- the rehearsal backup is --no-acl, so 'authenticated' has
-- no grants at all on public.guest_companions; only the security-definer RPCs may touch it.
select set_config('request.jwt.claims', json_build_object('sub','f3000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('cascade.companion_id',
  (public.save_guest_companion_v1('f3000000-0000-4000-8000-0000000000a4'::uuid, null,
    '{"name":"Jane Companion","contact_number":"09172223333"}'::jsonb, null, 'owner adds companion')->>'id'),
  true
);
select ok(current_setting('cascade.companion_id') is not null, 'owner add returns an id');
select is((select count(*) from public.list_guest_companions_v1('f3000000-0000-4000-8000-0000000000a4'::uuid))::int, 1, 'owner list sees the new companion');

-- the insert branch above still runs through the unconditional update at the
-- bottom of save_guest_companion_v1, so the freshly-added row is already at
-- version 2, not 1.
select is(
  (public.save_guest_companion_v1('f3000000-0000-4000-8000-0000000000a4'::uuid,
    current_setting('cascade.companion_id')::uuid,
    '{"notes":"met at check-in"}'::jsonb, 2, 'owner edits companion')->>'version')::int,
  3, 'edit increments the version'
);

select ok(
  (public.delete_guest_companion_v1(current_setting('cascade.companion_id')::uuid, 'no longer staying')->>'ok')::boolean,
  'owner delete returns ok'
);
select is((select count(*) from public.list_guest_companions_v1('f3000000-0000-4000-8000-0000000000a4'::uuid))::int, 0, 'companion is gone after delete');
reset role;
select is((select count(*) from public.guest_companion_history where guest_id='f3000000-0000-4000-8000-0000000000a4')::int, 3, 'add, edit and delete each left one history row');

select * from finish();
rollback;
