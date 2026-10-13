-- Session 82, lane S: release s82_staff_31_20261015. notices_v1 url, staff_home_v1 arrival_ready (owner/admin only), cleaning progress, staff pay admin side
-- (unrequested list, staff_pay_admin_create_v1), the web-settle ledger label, and the weekly sweep helpers. Synthetic fixtures only (uuids d8200000-...);
-- every lookup is scoped to them. Grant assertions need ACLs, so they live in the release's forward checks. Everything rolls back.
begin;
select plan(101);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant select on public.cleaning_expense_claims, public.cleaning_sessions to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;

-- fixtures: Honey and Other (cleaners), Admin, Finance, Owner. All have property access.
insert into auth.users(id, email) values
  ('d8200000-0000-4000-8000-0000000000a1', 'zz-honey@example.com'), ('d8200000-0000-4000-8000-0000000000a2', 'zz-other@example.com'),
  ('d8200000-0000-4000-8000-0000000000a3', 'zz-admin@example.com'), ('d8200000-0000-4000-8000-0000000000a4', 'zz-finance@example.com'),
  ('d8200000-0000-4000-8000-0000000000a5', 'zz-owner@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('d8200000-0000-4000-8000-0000000000a1', 'cleaner'), ('d8200000-0000-4000-8000-0000000000a2', 'cleaner'),
  ('d8200000-0000-4000-8000-0000000000a3', 'admin'), ('d8200000-0000-4000-8000-0000000000a4', 'finance'), ('d8200000-0000-4000-8000-0000000000a5', 'owner');
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) select u, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
  from unnest(array['d8200000-0000-4000-8000-0000000000a1', 'd8200000-0000-4000-8000-0000000000a2', 'd8200000-0000-4000-8000-0000000000a3', 'd8200000-0000-4000-8000-0000000000a4', 'd8200000-0000-4000-8000-0000000000a5']::uuid[]) u;
-- notices and the home payload use a property of their own: a restored production copy has real stays and notices on the real property
insert into public.properties(id, name, is_active) values ('d8200000-0000-4000-8000-0000000000b0', 'Zz S82 fixture property', true);
insert into public.staff_property_access(user_id, property_id) select u, 'd8200000-0000-4000-8000-0000000000b0'
  from unnest(array['d8200000-0000-4000-8000-0000000000a1', 'd8200000-0000-4000-8000-0000000000a3', 'd8200000-0000-4000-8000-0000000000a4', 'd8200000-0000-4000-8000-0000000000a5']::uuid[]) u;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
-- Honey: a turnover, a deep clean, a mid-stay (all open), one clean already paid. Other: one turnover. 2026-09-20 is on the 250 era (no transport rate).
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id, last_guest_name, fee_paid_at) values
  ('d8200000-0000-4000-8000-0000000000b1', 'zz-s82-a', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-10-02', 'turnover', 'd8200000-0000-4000-8000-0000000000a1', 'Zzguest One', null),
  ('d8200000-0000-4000-8000-0000000000b2', 'zz-s82-b', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-10-03', 'deep_clean', 'd8200000-0000-4000-8000-0000000000a1', null, null),
  ('d8200000-0000-4000-8000-0000000000b3', 'zz-s82-c', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-09-20', 'mid_stay', 'd8200000-0000-4000-8000-0000000000a1', null, null),
  ('d8200000-0000-4000-8000-0000000000b4', 'zz-s82-d', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-09-25', 'turnover', 'd8200000-0000-4000-8000-0000000000a1', null, now()),
  ('d8200000-0000-4000-8000-0000000000b5', 'zz-s82-e', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzother', date '2026-10-04', 'turnover', 'd8200000-0000-4000-8000-0000000000a2', null, null);
insert into public.cleaning_expense_claims(id, property_id, cleaning_session_id, submitted_by_user_id, expense_date, description, amount, status) values
  ('d8200000-0000-4000-8000-0000000000c1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'd8200000-0000-4000-8000-0000000000b1', 'd8200000-0000-4000-8000-0000000000a1', date '2026-10-02', 'zz soap', 120.50, 'pending_review'),
  ('d8200000-0000-4000-8000-0000000000c2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'd8200000-0000-4000-8000-0000000000b1', 'd8200000-0000-4000-8000-0000000000a1', date '2026-10-03', 'zz bulbs', 80, 'approved'),
  ('d8200000-0000-4000-8000-0000000000c3', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'd8200000-0000-4000-8000-0000000000b1', 'd8200000-0000-4000-8000-0000000000a1', date '2026-10-03', 'zz rejected', 999, 'rejected'),
  ('d8200000-0000-4000-8000-0000000000c4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'd8200000-0000-4000-8000-0000000000b5', 'd8200000-0000-4000-8000-0000000000a2', date '2026-10-04', 'zz other claim', 40, 'pending_review');

-- =============================================================================================================================================
-- Part 1: notices_v1 url
-- =============================================================================================================================================
insert into public.ops_notices(id, property_id, notice_type, title, effective_date, effective_time, duration_hours, source, source_url, is_active) values
  ('d8200000-0000-4000-8000-0000000000d1', 'd8200000-0000-4000-8000-0000000000b0', 'brownout', 'Zz brownout', (now() at time zone 'Asia/Manila')::date + 3, '13:00', 3, 'socoteco', 'https://www.facebook.com/socoteco2.EC/posts/1', true),
  ('d8200000-0000-4000-8000-0000000000d2', 'd8200000-0000-4000-8000-0000000000b0', 'water', 'Zz water', (now() at time zone 'Asia/Manila')::date + 4, '08:00', 9, 'manual', null, true);
select throws_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source_url) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'note', 'zz bad', current_date, 'javascript:alert(1)')$$,
  '23514', null, 'a notice link must be http or https');
select throws_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source_url) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'note', 'zz bad', current_date, 'https://user:pw@example.com/x')$$,
  '23514', null, 'a notice link may not carry credentials');
select throws_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source_url) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'note', 'zz bad', current_date, 'https://example.com/a b')$$,
  '23514', null, 'a notice link may not hold whitespace');
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a1');
insert into _t select 'n_cl', public.notices_v1('d8200000-0000-4000-8000-0000000000b0');
reset role;
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'n_ad', public.notices_v1('d8200000-0000-4000-8000-0000000000b0');
reset role;
select is((select n->>'url' from _t, jsonb_array_elements(v->'notices') n where k = 'n_cl' and n->>'id' = 'd8200000-0000-4000-8000-0000000000d1'),
  'https://www.facebook.com/socoteco2.EC/posts/1', 'a cleaner sees the original post link on a notice that has one');
select ok((select n ? 'url' and n->'url' = 'null'::jsonb from _t, jsonb_array_elements(v->'notices') n where k = 'n_cl' and n->>'id' = 'd8200000-0000-4000-8000-0000000000d2'),
  'a notice with no link carries url: null (the key is always there)');
select is((select array_agg(x order by x) from _t, jsonb_array_elements(v->'notices') n, jsonb_object_keys(n) x where k = 'n_cl' and n->>'id' = 'd8200000-0000-4000-8000-0000000000d1'),
  array['date','detail','duration_hours','end_time','id','source','start_time','title','type','url'], 'each notice has exactly the contract keys');
select ok((select (v - 'generated_at' - 'role' - 'house_times' - 'sources' - 'weather' - 'notices' - 'house' - 'inbox_open') = '{}'::jsonb from _t where k = 'n_cl'), 'the cleaner payload has no top-level key beyond the contract');
select ok((select v::text !~* '(payout|price|gross|amount|phone|e-?mail|psid|messenger|balance|deposit)' from _t where k = 'n_cl'), 'the cleaner payload carries no contact or money key');
select ok((select v->'house' = '[]'::jsonb and v->'inbox_open' = 'null'::jsonb from _t where k = 'n_cl'), 'a cleaner gets no house items and no inbox count');
select ok((select jsonb_array_length(v->'notices') >= 2 and n->>'url' is not null from _t, jsonb_array_elements(v->'notices') n where k = 'n_ad' and n->>'id' = 'd8200000-0000-4000-8000-0000000000d1'), 'an admin sees the same link');

-- =============================================================================================================================================
-- Part 2: staff_home_v1 arrival_ready
-- =============================================================================================================================================
insert into public.guests(id, property_id, name) values
  ('d8200000-0000-4000-8000-0000000000e1', 'd8200000-0000-4000-8000-0000000000b0', 'Zz Home Current'),
  ('d8200000-0000-4000-8000-0000000000e2', 'd8200000-0000-4000-8000-0000000000b0', 'Zz Home Next'),
  ('d8200000-0000-4000-8000-0000000000e3', 'd8200000-0000-4000-8000-0000000000b0', 'Zz Home Airbnb'),
  ('d8200000-0000-4000-8000-0000000000e4', 'd8200000-0000-4000-8000-0000000000b0', 'Zz Home Past');
insert into public.guest_profile_details(guest_id, property_id, id_on_file) values ('d8200000-0000-4000-8000-0000000000e1', 'd8200000-0000-4000-8000-0000000000b0', true);
insert into public.guest_companions(guest_id, property_id, name, id_type, id_photo_path) values
  ('d8200000-0000-4000-8000-0000000000e3', 'd8200000-0000-4000-8000-0000000000b0', 'Zz Airbnb Mate', 'passport', 'd8200000-0000-4000-8000-0000000000e3/zz.jpg');
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, checkin_date, checkout_date, pax, status, source) values
  ('d8200000-0000-4000-8000-0000000000f1', 'd8200000-0000-4000-8000-0000000000b0', 'd8200000-0000-4000-8000-0000000000e1', 'Zz Home Current', 'zzh1@example.com', (now() at time zone 'Asia/Manila')::date - 1, (now() at time zone 'Asia/Manila')::date + 2, 2, 'confirmed', 'direct'),
  ('d8200000-0000-4000-8000-0000000000f2', 'd8200000-0000-4000-8000-0000000000b0', 'd8200000-0000-4000-8000-0000000000e2', 'Zz Home Next', 'zzh2@example.com', (now() at time zone 'Asia/Manila')::date + 5, (now() at time zone 'Asia/Manila')::date + 7, 2, 'confirmed', 'direct');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date, guest_id) values
  ('d8200000-0000-4000-8000-0000000000f3', 'd8200000-0000-4000-8000-0000000000b0', 'ZZHOME82', 'confirmed', 'Zz Home Airbnb', (now() at time zone 'Asia/Manila')::date + 10, (now() at time zone 'Asia/Manila')::date + 12, 'd8200000-0000-4000-8000-0000000000e3');
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id) values
  ('d8200000-0000-4000-8000-0000000000b0', 'cascade-direct-d8200000-0000-4000-8000-0000000000f1', 'direct', 'confirmed', 'Zz Home Current', (now() at time zone 'Asia/Manila')::date - 1, (now() at time zone 'Asia/Manila')::date + 2, null),
  ('d8200000-0000-4000-8000-0000000000b0', 'cascade-direct-d8200000-0000-4000-8000-0000000000f2', 'direct', 'confirmed', 'Zz Home Next', (now() at time zone 'Asia/Manila')::date + 5, (now() at time zone 'Asia/Manila')::date + 7, null),
  ('d8200000-0000-4000-8000-0000000000b0', 'zz-airbnb-82', 'airbnb', 'confirmed', 'Zz Home Airbnb', (now() at time zone 'Asia/Manila')::date + 10, (now() at time zone 'Asia/Manila')::date + 12, 'd8200000-0000-4000-8000-0000000000f3'),
  ('d8200000-0000-4000-8000-0000000000b0', 'zz-past-82', 'airbnb', 'confirmed', 'Zz Home Past', (now() at time zone 'Asia/Manila')::date - 5, (now() at time zone 'Asia/Manila')::date - 3, null),
  ('d8200000-0000-4000-8000-0000000000b0', 'zz-block-82', 'manual', 'blocked', null, (now() at time zone 'Asia/Manila')::date + 20, (now() at time zone 'Asia/Manila')::date + 21, null);

select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3'); -- admin
insert into _t select 'h_ad', public.staff_home_v1('d8200000-0000-4000-8000-0000000000b0');
reset role;
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a5'); -- owner
insert into _t select 'h_ow', public.staff_home_v1('d8200000-0000-4000-8000-0000000000b0');
reset role;
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a1'); -- cleaner
insert into _t select 'h_cl', public.staff_home_v1('d8200000-0000-4000-8000-0000000000b0');
reset role;
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a4'); -- finance
insert into _t select 'h_fi', public.staff_home_v1('d8200000-0000-4000-8000-0000000000b0');
reset role;
select is((select v->'current_guest'->'arrival_ready' from _t where k = 'h_ad'), '{"id": true, "paid": null, "door_code": null}'::jsonb,
  'admin: the in-house direct stay has its ID on file; paid and door_code have no source, so null (not invented)');
select is((select v->'next_guest'->'arrival_ready' from _t where k = 'h_ad'), '{"id": false, "paid": null, "door_code": null}'::jsonb, 'admin: the next direct stay has no ID on file');
select is((select v->'next_guest'->'arrival_ready' from _t where k = 'h_ow'), '{"id": false, "paid": null, "door_code": null}'::jsonb, 'owner: the same');
select is((select c->'arrival_ready' from _t, jsonb_array_elements(v->'calendar') c where k = 'h_ad' and c->>'uid' = 'zz-airbnb-82'), '{"id": true, "paid": true, "door_code": null}'::jsonb,
  'admin: an Airbnb stay counts as paid, and a companion photo counts as an ID on file');
select ok((select c ? 'arrival_ready' from _t, jsonb_array_elements(v->'calendar') c where k = 'h_ad' and c->>'uid' = 'cascade-direct-d8200000-0000-4000-8000-0000000000f2'), 'admin: a future direct stay in calendar[] carries arrival_ready');
select ok((select not (c ? 'arrival_ready') from _t, jsonb_array_elements(v->'calendar') c where k = 'h_ad' and c->>'uid' = 'zz-past-82'), 'admin: a stay that has checked out carries none');
select ok((select not (c ? 'arrival_ready') from _t, jsonb_array_elements(v->'calendar') c where k = 'h_ad' and c->>'uid' = 'zz-block-82'), 'admin: a block carries none');
select ok((select not bool_or(v::text ~ 'arrival_ready' or v::text ~ 'door_code') from _t where k in ('h_cl', 'h_fi')), 'cleaner and finance payloads hold no arrival_ready and no door_code, anywhere');
select ok((select v::text !~* '("paid"|amount|price|payout|balance|deposit|total)' from _t where k = 'h_cl'), 'the cleaner home payload has no money key');
select is((select array_agg(x order by x) from _t, jsonb_array_elements(v->'calendar') c, jsonb_object_keys(c) x where k = 'h_cl' and c->>'uid' = 'cascade-direct-d8200000-0000-4000-8000-0000000000f2'),
  array['block_label','block_reason','checkin_date','checkin_time','checkout_date','checkout_time','guest_name','nights','source','status','uid'], 'a cleaner calendar row keeps exactly its old keys');
select is((select array_agg(x order by x) from _t, jsonb_object_keys(v->'next_guest') x where k = 'h_cl'),
  array['checkin_date','checkin_time','checkout_date','checkout_time','earlier_stays','guest_name','id_photo_path','nights','notes','repeat','source','stay_count','uid'],
  'a cleaner next_guest keeps exactly its old keys (no contact, companions or arrival_ready)');
select is((select (v->'current_guest') - 'x' from _t where k = 'h_cl'), (select (v->'current_guest') - 'x' from _t where k = 'h_fi'), 'cleaner and finance see the same current-guest shape');

-- the helper itself: Airbnb paid, unknown guest, source with no payment source
select is(public.s_arrival_ready_v1(null, 'airbnb'), '{"id": false, "paid": true, "door_code": null}'::jsonb, 'helper: no guest means id false; airbnb means paid true');
select is(public.s_arrival_ready_v1('d8200000-0000-4000-8000-0000000000e1', 'manual'), '{"id": true, "paid": null, "door_code": null}'::jsonb, 'helper: a manual stay has no payment source');

-- =============================================================================================================================================
-- Part 3: cleaning progress
-- =============================================================================================================================================
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a1');
insert into _t select 'p_set1', public.cleaning_progress_set_v1(3, 12, 'Kitchen');
insert into _t select 'p_bad1', public.cleaning_progress_set_v1(13, 12, 'x');
insert into _t select 'p_bad2', public.cleaning_progress_set_v1(1, 0, 'x');
insert into _t select 'p_bad3', public.cleaning_progress_set_v1(-1, 12, 'x');
insert into _t select 'p_cl_read', public.cleaning_progress_v1();
reset role;
select is((select v from _t where k = 'p_set1'), '{"ok": true}'::jsonb, 'a cleaner records her step');
select ok((select bool_and(v->>'reason' = 'bad_request') from _t where k in ('p_bad1', 'p_bad2', 'p_bad3')), 'a step past the total, a zero total and a negative step are refused');
select is((select v->>'reason' from _t where k = 'p_cl_read'), 'not_authorized', 'cleaning_progress_v1 refuses a cleaner (even for her own row)');
select is((select count(*)::int from public.cleaning_progress where user_id = 'd8200000-0000-4000-8000-0000000000a1'), 1, 'one row per cleaner per day');
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a1');
insert into _t select 'p_set2', public.cleaning_progress_set_v1(5, 12, 'Bathroom 1');
reset role;
select is((select count(*)::int from public.cleaning_progress where user_id = 'd8200000-0000-4000-8000-0000000000a1'), 1, 'a second write the same day updates that row');
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'p_ad', public.cleaning_progress_v1();
reset role;
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a5');
insert into _t select 'p_ow', public.cleaning_progress_v1();
reset role;
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a4');
insert into _t select 'p_fi', public.cleaning_progress_v1();
reset role;
select is((select v->'active'->>'step' from _t where k = 'p_ad'), '5', 'an admin reads the latest step');
select is((select array_agg(x order by x) from _t, jsonb_object_keys(v->'active') x where k = 'p_ad'), array['cleaner_name','label','of','started_at','step','updated_at'], 'and exactly the contract keys');
select is((select v->'active'->>'cleaner_name' from _t where k = 'p_ad'), 'Zzhoney', 'with the cleaner''s first name only');
select is((select v->'active'->>'label' from _t where k = 'p_ad'), 'Bathroom 1', 'and the section name');
select is((select v->'active'->>'of' from _t where k = 'p_ow'), '12', 'the owner reads it too');
select is((select v->>'reason' from _t where k = 'p_fi'), 'not_authorized', 'finance is refused');
update public.cleaning_progress set updated_at = now() - interval '2 days', day = day - 2 where user_id = 'd8200000-0000-4000-8000-0000000000a1';
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'p_old', public.cleaning_progress_v1();
reset role;
select ok((select v->'active' = 'null'::jsonb and v->>'ok' = 'true' from _t where k = 'p_old'), 'a row last touched before today is not active');
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a1');
select public.cleaning_progress_set_v1(12, 12, 'Done');
select public.cleaning_progress_set_v1(1, 12, 'Again');
reset role;
select ok((select started_at > now() - interval '1 minute' from public.cleaning_progress where user_id = 'd8200000-0000-4000-8000-0000000000a1' and day = (now() at time zone 'Asia/Manila')::date),
  'a finished clean followed by a new one the same day starts a new run');

-- =============================================================================================================================================
-- Part 4: staff pay, admin side (money)
-- =============================================================================================================================================
-- 4a who may call
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a1');
insert into _t select 'c_cl', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-cl01');
insert into _t select 'l_cl', public.staff_pay_admin_list_v1();
insert into _t select 'cand', public.staff_pay_candidates_v1();
reset role;
select is((select v->>'reason' from _t where k = 'c_cl'), 'not_authorized', 'a cleaner cannot create a request for herself through the admin door');
select is((select v->>'reason' from _t where k = 'l_cl'), 'not_authorized', 'a cleaner cannot read the admin list (so never sees unrequested)');
select is((select count(*)::int from public.staff_pay_requests where payee_user_id = 'd8200000-0000-4000-8000-0000000000a1'), 0, 'and nothing was written');
-- 4b unrequested, same rule as the candidates
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'l_ad', public.staff_pay_admin_list_v1();
reset role;
select ok((select v ? 'unrequested' and jsonb_typeof(v->'unrequested') = 'array' and v ? 'requests' from _t where k = 'l_ad'), 'the admin list keeps requests and gains unrequested');
select is((select count(*)::int from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_ad' and e->>'payee_user_id' in ('d8200000-0000-4000-8000-0000000000a1', 'd8200000-0000-4000-8000-0000000000a2')), 2, 'both fixture staff members have unpaid work in no request (real staff may be listed too)');
select is((select e->'sessions' from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_ad' and e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1'),
  (select v->'sessions' from _t where k = 'cand'), 'Honey: the sessions equal staff_pay_candidates_v1 for the same rows (ids, dates, types, bases, transport)');
select is((select e->'claims' from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_ad' and e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1'),
  (select v->'claims' from _t where k = 'cand'), 'Honey: the claims equal staff_pay_candidates_v1 (the rejected claim is not there)');
select is((select (e->>'total')::numeric from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_ad' and e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1'),
  (select coalesce(sum((s->>'base')::numeric), 0) from _t, jsonb_array_elements(v->'sessions') s where k = 'cand')
  + (select coalesce(sum((c->>'amount')::numeric), 0) from _t, jsonb_array_elements(v->'claims') c where k = 'cand'),
  'Honey: total = bases + claims, summed from the candidates payload');
select is((select (e->>'total')::numeric from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_ad' and e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1'), (select regular from public.staff_pay_rate_v1(date '2026-10-02')) + (select general from public.staff_pay_rate_v1(date '2026-10-03')) + (select regular from public.staff_pay_rate_v1(date '2026-09-20')) + 120.50 + 80,
  'Honey: turnover + deep clean + mid-stay (each at the rate in force on its day: a restored production copy has the 650 era) + 200.50 of claims');
select is((select e->>'payee_name' from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_ad' and e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1'), 'Zzhoney Reyes', 'the name she signs with');
select ok((select not bool_or(e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1' and s->>'id' = 'd8200000-0000-4000-8000-0000000000b4') from _t, jsonb_array_elements(v->'unrequested') e, jsonb_array_elements(e->'sessions') s where k = 'l_ad'), 'a clean already paid is not unrequested');
select ok((select (e->>'has_qr')::boolean = false from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_ad' and e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1'), 'has_qr is a boolean (no payout payload in the list)');
select ok((select v::text !~ 'payout_qrph' and (select coalesce(jsonb_agg(e), '[]'::jsonb)::text from jsonb_array_elements(v->'unrequested') e where e->>'payee_user_id' in ('d8200000-0000-4000-8000-0000000000a1', 'd8200000-0000-4000-8000-0000000000a2')) !~* '(payout|payment_|booking|income|guest)' from _t where k = 'l_ad'), 'the admin list names no payout payload, and the fixture entries no booking income and no guest (real staff entries are free text they typed)');
-- 4c create
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'c_bad_key', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'short');
insert into _t select 'c_nopayee', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000ee', '[{"id":"d8200000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0002');
insert into _t select 'c_notheirs', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b5"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0003');
insert into _t select 'c_paidsess', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b4"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0004');
insert into _t select 'c_theirclaim', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[]'::jsonb, array['d8200000-0000-4000-8000-0000000000c4']::uuid[], 'zz-s82-key-0005');
insert into _t select 'c_rejclaim', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[]'::jsonb, array['d8200000-0000-4000-8000-0000000000c3']::uuid[], 'zz-s82-key-0006');
insert into _t select 'c_empty', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[]'::jsonb, '{}'::uuid[], 'zz-s82-key-0007');
insert into _t select 'c_trans_old', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b3","transport":true}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0008');
insert into _t select 'c_dupid', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b1"},{"id":"d8200000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0009');
insert into _t select 'c_badtr', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b1","transport":"yes"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0010');
reset role;
select is((select v->>'reason' from _t where k = 'c_bad_key'), 'bad_request', 'a short key is refused');
select is((select v->>'reason' from _t where k = 'c_nopayee'), 'payee_not_found', 'an unknown payee is refused');
select is((select v->>'reason' from _t where k = 'c_notheirs'), 'session_not_yours', 'another person''s clean cannot be put in her request');
select is((select v->>'reason' from _t where k = 'c_paidsess'), 'session_taken', 'a clean already paid is refused');
select is((select v->>'reason' from _t where k = 'c_theirclaim'), 'claim_taken', 'another person''s claim is refused');
select is((select v->>'reason' from _t where k = 'c_rejclaim'), 'claim_taken', 'a rejected claim is refused');
select is((select v->>'reason' from _t where k = 'c_empty'), 'no_lines', 'an empty request is refused');
select is((select v->>'reason' from _t where k = 'c_trans_old'), 'transport_not_allowed', 'transport on the old 250 rate is refused (the double-pay trap)');
select is((select v->>'reason' from _t where k = 'c_dupid'), 'bad_request', 'the same clean twice is refused');
select is((select v->>'reason' from _t where k = 'c_badtr'), 'bad_request', 'a non-boolean transport is refused');
select is((select count(*)::int from public.staff_pay_requests where payee_user_id = 'd8200000-0000-4000-8000-0000000000a1'), 0, 'no refusal left a request behind');
select is((select count(*)::int from public.cleaning_sessions where pay_request_id is not null and id::text like 'd8200000%'), 0, 'and no clean was locked by a refusal');

select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'c_ok', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1',
  '[{"id":"d8200000-0000-4000-8000-0000000000b1","transport":true},{"id":"d8200000-0000-4000-8000-0000000000b2"}]'::jsonb,
  array['d8200000-0000-4000-8000-0000000000c1', 'd8200000-0000-4000-8000-0000000000c2']::uuid[], 'zz-s82-key-0100');
insert into _t select 'c_again', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1',
  '[{"id":"d8200000-0000-4000-8000-0000000000b1","transport":true},{"id":"d8200000-0000-4000-8000-0000000000b2"}]'::jsonb,
  array['d8200000-0000-4000-8000-0000000000c1', 'd8200000-0000-4000-8000-0000000000c2']::uuid[], 'zz-s82-key-0100');
insert into _t select 'c_double', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1',
  '[{"id":"d8200000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0101');
insert into _t select 'c_double_claim', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[]'::jsonb, array['d8200000-0000-4000-8000-0000000000c1']::uuid[], 'zz-s82-key-0102');
reset role;
select is((select v->>'ok' from _t where k = 'c_ok'), 'true', 'the admin makes a request for Honey');
select ok((select v ? 'id' and v ? 'ref' and v->>'id' = v->>'request_id' from _t where k = 'c_ok'), 'the answer carries id and ref (and request_id, the staff create''s name)');
select is((select (v->>'total')::numeric from _t where k = 'c_ok'), 500 + 150 + 1000 + 120.50 + 80, 'total = turnover + chosen transport + deep clean + both claims');
select is((select status from public.staff_pay_requests where id = (select (v->>'id')::uuid from _t where k = 'c_ok')), 'requested', 'it is a normal requested row');
select is((select payee_user_id from public.staff_pay_requests where id = (select (v->>'id')::uuid from _t where k = 'c_ok')), 'd8200000-0000-4000-8000-0000000000a1'::uuid, 'for Honey');
select is((select created_by_user_id from public.staff_pay_requests where id = (select (v->>'id')::uuid from _t where k = 'c_ok')), 'd8200000-0000-4000-8000-0000000000a3'::uuid, 'marked as made by the admin');
select is((select count(*)::int from public.cleaning_sessions where pay_request_id = (select (v->>'id')::uuid from _t where k = 'c_ok')), 2, 'both cleans carry the lock');
select is((select count(*)::int from public.cleaning_expense_claims where pay_request_id = (select (v->>'id')::uuid from _t where k = 'c_ok')), 2, 'both claims carry the lock');
select is((select jsonb_array_length(lines) from public.staff_pay_requests where id = (select (v->>'id')::uuid from _t where k = 'c_ok')), 4, 'four lines');
select is((select (l->>'amount')::numeric from public.staff_pay_requests r, jsonb_array_elements(r.lines) l where r.id = (select (v->>'id')::uuid from _t where k = 'c_ok') and l->>'session_id' = 'd8200000-0000-4000-8000-0000000000b1'), 650::numeric, 'the transport rides on the line (650 = 500 + 150)');
select is((select (l->>'guest') from public.staff_pay_requests r, jsonb_array_elements(r.lines) l where r.id = (select (v->>'id')::uuid from _t where k = 'c_ok') and l->>'session_id' = 'd8200000-0000-4000-8000-0000000000b1'), 'Zzguest', 'the line carries the guest''s first name only, as the staff create does');
select is((select v->>'id' from _t where k = 'c_again'), (select v->>'id' from _t where k = 'c_ok'), 'the same key again answers the same request');
select ok((select (v->>'replay')::boolean from _t where k = 'c_again'), 'and says it is a replay');
select is((select count(*)::int from public.staff_pay_requests where payee_user_id = 'd8200000-0000-4000-8000-0000000000a1'), 1, 'exactly one request exists after the replay');
select is((select v->>'reason' from _t where k = 'c_double'), 'session_taken', 'a double-create (new key, same clean) is refused');
select is((select v->>'reason' from _t where k = 'c_double_claim'), 'claim_taken', 'and so is the same claim under a new key');
select ok((select exists (select 1 from public.admin_audit_log a where a.entity_table = 'staff_pay_requests' and a.entity_id = (select (v->>'id')::uuid from _t where k = 'c_ok')
                            and a.actor_user_id = 'd8200000-0000-4000-8000-0000000000a3' and a.reason like 'staff pay request made by%')), 'the audit trail names the admin and says the request was made for the staff member');
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'l_after', public.staff_pay_admin_list_v1();
reset role;
select ok((select not exists (select 1 from jsonb_array_elements(v->'unrequested') e where e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1' and jsonb_array_length(e->'sessions') > 1) from _t where k = 'l_after'), 'after the create, Honey''s unrequested list holds only the mid-stay');
select is((select (e->>'total')::numeric from _t, jsonb_array_elements(v->'unrequested') e where k = 'l_after' and e->>'payee_user_id' = 'd8200000-0000-4000-8000-0000000000a1'), (select regular from public.staff_pay_rate_v1(date '2026-09-20')), 'and its total is the mid-stay base in force on its day');
select ok((select exists (select 1 from jsonb_array_elements(v->'requests') r where r->>'id' = (select v->>'id' from _t where k = 'c_ok') and r ? 'paid_by_name') from _t where k = 'l_after'), 'every request row carries paid_by_name (null until paid)');
-- the key is shared with the staff member's own create: her tap with the same key sees the admin's row
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a1');
insert into _t select 'staff_same_key', public.staff_pay_request_create_v1('[{"id":"d8200000-0000-4000-8000-0000000000b3"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s82-key-0100');
reset role;
select is((select v->>'request_id' from _t where k = 'staff_same_key'), (select v->>'id' from _t where k = 'c_ok'), 'the staff member''s own create with that key replays the admin''s row (one key, one request)');
-- cancelling frees the work and the key stays cancelled
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'cancel', public.staff_pay_admin_step_v1((select (v->>'id')::uuid from _t where k = 'c_ok'), 'cancel');
insert into _t select 'c_cancelled_key', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0100');
insert into _t select 'c_after_cancel', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], 'zz-s82-key-0103');
reset role;
select is((select v->>'reason' from _t where k = 'c_cancelled_key'), 'key_cancelled', 'a cancelled request keeps its key');
select is((select v->>'ok' from _t where k = 'c_after_cancel'), 'true', 'and the freed clean can be requested again under a new key');

-- =============================================================================================================================================
-- Part 5: the web settle label, the weekly sweep
-- =============================================================================================================================================
-- Telegram settle (unchanged label) on Other's request; web settle (new label) on Honey's second request.
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a2');
insert into _t select 'tg_req', public.staff_pay_request_create_v1('[{"id":"d8200000-0000-4000-8000-0000000000b5"}]'::jsonb, array['d8200000-0000-4000-8000-0000000000c4']::uuid[], '[]'::jsonb, 'zz-s82-key-tg01');
reset role;
select public.telegram_staff_pay_step_v1((select (v->>'request_id')::uuid from _t where k = 'tg_req'), 'pay', 777, 'Marifel', null);
select public.telegram_staff_pay_step_v1((select (v->>'request_id')::uuid from _t where k = 'tg_req'), 'sent', 777, 'Marifel', null);
insert into _t select 'tg_proof', public.telegram_staff_pay_step_v1((select (v->>'request_id')::uuid from _t where k = 'tg_req'), 'proof', 777, 'Marifel',
  jsonb_build_object('file_unique_id', 'zz-s82-tg-file', 'file_id', 'zz-f', 'sha256', repeat('b', 64), 'amount', 540, 'reference', 'ZZS82TG01', 'verdict', 'match'));
select is((select v->>'status' from _t where k = 'tg_proof'), 'paid', 'fixture: the Telegram settle completed');
select is((select logged_by from public.transactions where external_ref = 'cleanfee:d8200000-0000-4000-8000-0000000000b5'), 'Telegram: Marifel', 'a Telegram settle is still logged "Telegram: <name>"');
select ok((select review_note like '%confirmed by Marifel in Telegram' from public.cleaning_expense_claims where id = 'd8200000-0000-4000-8000-0000000000c4'), 'and its claim note still says in Telegram');

insert into storage.buckets(id, name) values ('cleaning-photos', 'cleaning-photos') on conflict do nothing;
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'w_req', public.staff_pay_admin_create_v1('d8200000-0000-4000-8000-0000000000a1', '[{"id":"d8200000-0000-4000-8000-0000000000b2"}]'::jsonb, array['d8200000-0000-4000-8000-0000000000c1']::uuid[], 'zz-s82-key-web1');
insert into _t select 'w_pay', public.staff_pay_admin_step_v1((select (v->>'id')::uuid from _t where k = 'w_req'), 'pay');
reset role;
insert into storage.objects(bucket_id, name) values ('cleaning-photos', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/d8200000-0000-4000-8000-0000000000a3/d8200000-0000-4000-8000-0000000000f9/zz-proof.jpg');
insert into public.staff_upload_hashes(path, sha256) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/d8200000-0000-4000-8000-0000000000a3/d8200000-0000-4000-8000-0000000000f9/zz-proof.jpg', repeat('c', 64));
select pg_temp.as_user('d8200000-0000-4000-8000-0000000000a3');
insert into _t select 'w_settle', public.staff_pay_admin_settle_v1((select (v->>'id')::uuid from _t where k = 'w_req'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/d8200000-0000-4000-8000-0000000000a3/d8200000-0000-4000-8000-0000000000f9/zz-proof.jpg', 'amount', 1120.50, 'reference', 'ZZS82WEB01'));
reset role;
select is((select v->>'status' from _t where k = 'w_settle'), 'paid', 'fixture: the web settle completed');
select is((select logged_by from public.transactions where external_ref = 'cleanfee:d8200000-0000-4000-8000-0000000000b2'), 'Zz-Admin via Staff app', 'a web settle is logged "<name> via Staff app", not "Telegram: ..."');
select ok((select logged_by !~ 'Telegram' from public.transactions where external_ref = 'claim:d8200000-0000-4000-8000-0000000000c1'), 'the claim row is not prefixed Telegram either');
select ok((select review_note not like '%Telegram%' and review_note like '%via Staff app' from public.cleaning_expense_claims where id = 'd8200000-0000-4000-8000-0000000000c1'), 'and the claim note does not say Telegram');
select ok((select notes like 'Cleaning fee - Zzhoney Reyes, 2026-10-03, Deep Clean. Pay request %' from public.transactions where external_ref = 'cleanfee:d8200000-0000-4000-8000-0000000000b2'), 'the ledger notes are unchanged');
select is((select paid_by_name from public.staff_pay_requests where id = (select (v->>'id')::uuid from _t where k = 'w_req')), 'Zz-Admin via Staff app', 'paid_by_name records the settling actor (what the list returns)');

-- the weekly sweep: which paid requests are re-asked, and what it purges
select is((select array_agg(x order by x) from public.s_paid_unnotified_v1() x where x in ((select (v->>'id')::uuid from _t where k = 'w_req'), (select (v->>'request_id')::uuid from _t where k = 'tg_req'))),
  (select array_agg(x order by x) from unnest(array[(select (v->>'id')::uuid from _t where k = 'w_req'), (select (v->>'request_id')::uuid from _t where k = 'tg_req')]) x),
  'both paid-and-never-told requests are due for the weekly ask');
update public.staff_pay_requests set paid_notified_at = now() where id = (select (v->>'request_id')::uuid from _t where k = 'tg_req');
update public.staff_pay_requests set paid_at = now() - interval '8 days' where id = (select (v->>'id')::uuid from _t where k = 'w_req');
select is((select count(*)::int from public.s_paid_unnotified_v1() x where x in ((select (v->>'id')::uuid from _t where k = 'w_req'), (select (v->>'request_id')::uuid from _t where k = 'tg_req'))), 0,
  'one already told and one paid more than 7 days ago are left alone');
insert into public.staff_upload_hashes(path, sha256, created_at) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/zz82/old/zz-old.jpg', repeat('d', 64), now() - interval '100 days'),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/zz82/new/zz-new.jpg', repeat('e', 64), now() - interval '10 days');
insert into public.cleaning_progress(property_id, user_id, day, step, of_steps) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'd8200000-0000-4000-8000-0000000000a2', (now() at time zone 'Asia/Manila')::date - 30, 1, 5);
insert into _t select 'sweep', public.s_weekly_sweep_v1();
select is((select count(*)::int from public.staff_upload_hashes where path like '%/zz82/%'), 1, 'the sweep deletes an upload hash older than 90 days and keeps a newer one');
select is((select count(*)::int from public.cleaning_progress where user_id = 'd8200000-0000-4000-8000-0000000000a2'), 0, 'and a progress row older than 14 days');
select ok((select (v->>'purged_upload_hashes')::int >= 1 from _t where k = 'sweep'), 'it reports what it purged');
select ok((select last_succeeded_at > now() - interval '1 minute' from public.job_heartbeats where job_name = 'pay-weekly-sweep'), 'and records its heartbeat');
create function pg_temp.cron_ok() returns boolean language plpgsql as $f$
begin
  if to_regclass('cron.job') is null then return true; end if;
  return (select count(*) from cron.job where jobname = 's82-pay-weekly-sweep' and schedule = '30 22 * * 0' and command like '%s_weekly_sweep_v1%') = 1;
end $f$;
select ok(pg_temp.cron_ok(), 'the cron job is scheduled weekly (skipped where pg_cron is absent)');

select * from finish();
rollback;
