-- Session 70 lane L3, SPEC-36 + D-299.7/.9: staff_home_v1 and the staff ID-photo storage policy.
-- Everything is synthetic and lives on a synthetic property (e3600000-...-b0), so restored production rows never interfere; the
-- suite is inside begin/rollback. Fixtures insert as the owner (service_role has no BYPASSRLS); the roles are impersonated with
-- request.jwt.claims as staff_decide_direct_booking.sql does.
begin;
select plan(65);

select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('staff_home_v1','staff_guest_card_v1','staff_current_next_stays_v1','staff_stay_guest_id_v1',
                                'staff_primary_id_path_v1','staff_may_see_guest_id_v1','staff_can_view_guest_id_object_v1')),
  'the RPC and its helpers are security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.staff_home_v1(uuid)', 'execute'), 'anon cannot call staff_home_v1');
select ok(has_function_privilege('authenticated', 'public.staff_home_v1(uuid)', 'execute'), 'authenticated can call staff_home_v1');
select ok(not has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute')
      and not has_function_privilege('authenticated', 'public.staff_current_next_stays_v1(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.staff_primary_id_path_v1(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.staff_redact_v1(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.staff_hide_money_v1(text)', 'execute'),
  'the internal helpers are not callable by a staff session');
select ok(not has_function_privilege('anon', 'public.staff_can_view_guest_id_object_v1(text)', 'execute')
      and has_function_privilege('authenticated', 'public.staff_can_view_guest_id_object_v1(text)', 'execute'),
  'only authenticated reaches the storage-policy helper');

-- Fixtures: a synthetic property, a cleaner, an admin, a maintenance user, one user with no staff profile.
insert into public.properties(id, name, is_active) values ('e3600000-0000-4000-8000-0000000000b0', 'Synthetic Staff Home L3', true);
insert into auth.users(id) values ('e3600000-0000-4000-8000-000000000001'), ('e3600000-0000-4000-8000-000000000002'), ('e3600000-0000-4000-8000-000000000003');
insert into public.staff_access_profiles(user_id, role) values
  ('e3600000-0000-4000-8000-000000000001', 'cleaner'), ('e3600000-0000-4000-8000-000000000002', 'admin'), ('e3600000-0000-4000-8000-000000000003', 'maintenance');
insert into public.staff_property_access(user_id, property_id) values
  ('e3600000-0000-4000-8000-000000000001', 'e3600000-0000-4000-8000-0000000000b0'),
  ('e3600000-0000-4000-8000-000000000002', 'e3600000-0000-4000-8000-0000000000b0'),
  ('e3600000-0000-4000-8000-000000000003', 'e3600000-0000-4000-8000-0000000000b0');

-- G1 is the guest in the house (returning: one earlier stay), G2 arrives next (first stay), G3 is neither.
insert into public.guests(id, property_id, name, notes) values
  ('e3600000-0000-4000-8000-0000000000c1', 'e3600000-0000-4000-8000-0000000000b0', 'Zz L3 Current', 'ring 09171234567 or write a.b@c.org'),
  ('e3600000-0000-4000-8000-0000000000c2', 'e3600000-0000-4000-8000-0000000000b0', 'Zz L3 Next', null),
  ('e3600000-0000-4000-8000-0000000000c3', 'e3600000-0000-4000-8000-0000000000b0', 'Zz L3 Other', null);
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('e3600000-0000-4000-8000-0000000000d1', 'e3600000-0000-4000-8000-0000000000b0', 'ZZL3OLD', 'completed', 'e3600000-0000-4000-8000-0000000000c1', 'Zz L3 Current', current_date - 60, current_date - 57),
  ('e3600000-0000-4000-8000-0000000000d2', 'e3600000-0000-4000-8000-0000000000b0', 'ZZL3CUR', 'confirmed', 'e3600000-0000-4000-8000-0000000000c1', 'Zz L3 Current', current_date - 1, current_date + 2),
  ('e3600000-0000-4000-8000-0000000000d3', 'e3600000-0000-4000-8000-0000000000b0', 'ZZL3NXT', 'confirmed', 'e3600000-0000-4000-8000-0000000000c2', 'Zz L3 Next', current_date + 3, current_date + 5);
insert into public.calendar_events(property_id, uid, source, status, guest_name, guest_phone, checkin_date, checkout_date, linked_reservation_id) values
  ('e3600000-0000-4000-8000-0000000000b0', 'zz-l3-cur', 'airbnb', 'confirmed', 'Zz L3 Current', '+639000000000', current_date - 1, current_date + 2, 'e3600000-0000-4000-8000-0000000000d2'),
  ('e3600000-0000-4000-8000-0000000000b0', 'zz-l3-nxt', 'airbnb', 'confirmed', 'Zz L3 Next', null, current_date + 3, current_date + 5, null),
  ('e3600000-0000-4000-8000-0000000000b0', 'zz-l3-blk', 'airbnb', 'blocked', 'Owner note', null, current_date + 8, current_date + 10, null),
  ('e3600000-0000-4000-8000-0000000000b0', 'zz-l3-can', 'airbnb', 'cancelled', 'Gone Guest', null, current_date + 12, current_date + 13, null);
-- Free text with money and contact shapes on purpose (D-289): the bare and P-shorthand amounts, three PH mobile spellings, an e-mail.
insert into public.guest_profile_details(guest_id, property_id, stay_preferences, vip_reason) values
  ('e3600000-0000-4000-8000-0000000000c1', 'e3600000-0000-4000-8000-0000000000b0',
   '2026-08-01: Likes extra towels | Was given a refund of PHP 500 last time | paid P500 then P 1,000 then P1,000.00 | reach 0917 123 4567 or +63 917-123-4567 or x@y.com',
   'cousin of the owner, 0918-555-1234');
-- Companions and ID photos: G1 has its own row (named like the guest) and a second companion; G2 and G3 have one each.
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path) values
  ('e3600000-0000-4000-8000-0000000000e1', 'e3600000-0000-4000-8000-0000000000c1', 'e3600000-0000-4000-8000-0000000000b0', 'Zz L3 Current', 'e3600000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg'),
  ('e3600000-0000-4000-8000-0000000000e2', 'e3600000-0000-4000-8000-0000000000c1', 'e3600000-0000-4000-8000-0000000000b0', 'Zz L3 Companion', 'e3600000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-000000000002.jpg'),
  ('e3600000-0000-4000-8000-0000000000e3', 'e3600000-0000-4000-8000-0000000000c2', 'e3600000-0000-4000-8000-0000000000b0', 'Zz L3 Next', 'e3600000-0000-4000-8000-0000000000e3/11111111-0000-4000-8000-000000000003.jpg'),
  ('e3600000-0000-4000-8000-0000000000e4', 'e3600000-0000-4000-8000-0000000000c3', 'e3600000-0000-4000-8000-0000000000b0', 'Zz L3 Other', 'e3600000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg');
insert into storage.objects(bucket_id, name) values
  ('guest-id-photos', 'e3600000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg'),
  ('guest-id-photos', 'e3600000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-000000000002.jpg'),
  ('guest-id-photos', 'e3600000-0000-4000-8000-0000000000e3/11111111-0000-4000-8000-000000000003.jpg'),
  ('guest-id-photos', 'e3600000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg');
insert into public.ops_notices(property_id, notice_type, title, effective_date, is_active, audience, feeder, posted_by_name)
  values ('e3600000-0000-4000-8000-0000000000b0', 'brownout', 'zz-l3 brownout', current_date + 3, true, 'staff', 'Feeder (0917) 123 4567', 'Ana x@y.com');
insert into public.inventory_items(property_id, name, category, qty_on_hand, reorder_below, is_active)
  values ('e3600000-0000-4000-8000-0000000000b0', 'zz-l3 Low Item', 'zz', 1, 6, true);
insert into public.verifier_findings(key, check_id, severity, title, status) values
  ('zz-l3-v6', 'V6', 'yellow', 'zz-l3 ops finding', 'open'), ('zz-l3-v1', 'V1', 'red', 'zz-l3 finance finding', 'open');

-- The redactors and the unresolved-guest card, called as the owner (the helpers are not granted to a staff session).
select is(public.staff_hide_money_v1('paid P500, P 1,000 and P1,000.00 ok'), 'paid [hidden], [hidden] and [hidden] ok',
  'the money filter hides PH shorthand P500, P 1,000 and P1,000.00');
-- Phone layouts, e-mail and full-width digits: the whole string goes.
select is(public.staff_redact_v1(t), '[hidden]', 'hidden: ' || t) from unnest(array[
  '(0917) 123 4567', '+63 (917) 123 4567', '63 917 123 4567', '917 123 4567', '0917/123/4567', '0917_123_4567',
  '(083) 552 1234', '083-552-1234', '+1 (415) 555-0100', '0 9 1 7 1 2 3 4 5 6 7',
  '０９１７１２３４５６７８', '０９１７-１２３-４５６７', '09181234567', 'x@y.com', '0917–123–4567', 'x＠y.com']) t;
-- Dates, times and small numbers stay as written.
select is(public.staff_redact_v1(t), t, 'kept: ' || t) from unnest(array[
  'Check-in 2026-08-01 room 12, 2 pax', 'Oct 20 to 22', '3 nights, 2 guests', 'Check-in 14:00, out 11:00-12:00',
  '2026-08-01 - 2026-08-05', 'room 12, 2 pax']) t;
select is(public.staff_redact_v1('call 0917 123 4567 ok'), 'call [hidden] ok', 'a 09 mobile with spaces is hidden');
select is(public.staff_redact_v1('or +63 917-123-4567.'), 'or [hidden].', 'a +63 mobile with dashes is hidden');
select is(public.staff_redact_v1('mail x@y.com now'), 'mail [hidden] now', 'an e-mail address is hidden');
select is(public.staff_redact_v1('2026-08-01 0917 123 4567'), '2026-08-01 [hidden]', 'a date is kept and the phone after it is hidden');
-- Money: words, k, lowercase p and a euro sign.
select is(public.staff_hide_money_v1(t), '[hidden]', 'money hidden: ' || t) from unnest(array['2k pesos', '500 peso', 'p500', '1.5k', '€50']) t;
select is(public.staff_guest_card_v1('e3600000-0000-4000-8000-0000000000b0', null, current_date)->'earlier_stays', 'null'::jsonb,
  'earlier_stays is null, not [], when the guest is unresolved');

-- The cleaner.
select set_config('request.jwt.claims', json_build_object('sub','e3600000-0000-4000-8000-000000000001','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);

select is(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'guest_name', 'Zz L3 Current', 'the current guest is found');
select is(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'uid', 'zz-l3-cur', 'the current guest is the linked stay');
select is((public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'repeat')::boolean, true, 'a guest with an earlier stay is returning');
select is((public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'stay_count')::int, 2, 'this is the second stay');
select is(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->'earlier_stays'->0->>'month',
          to_char(current_date - 57, 'YYYY-MM'), 'the earlier stay is listed by the month it ended');
select is((public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'next_guest'->>'repeat')::boolean, false, 'the next guest, matched by dates, is a first stay');
select is((public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'next_guest'->>'stay_count')::int, 1, 'the next guest has stay count 1');
select ok(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'notes' like '%Likes extra towels%'
      and public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'notes' like '%[hidden]%'
      and public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'notes' not like '%PHP%',
  'notes from earlier stays reach staff with the amount replaced');
-- uid, property_id and id_photo_path are identifiers, not free text (an Airbnb uid is shaped like an e-mail address), so they are cut out first.
select ok(not (regexp_replace(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')::text, '"(uid|property_id|id_photo_path)": "[^"]*"', '', 'g') ~* '(amount|deposit|total|phone|email|\+639|[0-9]{10}|(\+?63|0)9([ .-]*[0-9]){9}|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}|\mP\s*[0-9]|php|pesos|piso)'),
  'no money, no phone shape, no e-mail shape anywhere in the payload (a phone column, notes, vip_reason and guests.notes are seeded on the current guest on purpose)');
select ok(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'notes' like '%Likes extra towels%[hidden]%',
  'the notes keep the harmless text and show [hidden] where a number or address was');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'calendar')), 3,
  'the confirmed, confirmed and blocked rows are sent and the cancelled one is not');
select is((select x->>'guest_name' from jsonb_array_elements(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-l3-blk'), null,
  'blocked rows carry no name');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'warnings') w
            where w->>'kind' = 'verifier' and w->>'title' like 'zz-l3%'), 1, 'a cleaner sees the OPS finding (V6) and not the finance one (V1)');
select ok(exists (select 1 from jsonb_array_elements(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'warnings') w
                   where w->>'kind' = 'brownout' and w->>'title' = 'zz-l3 brownout')
      and exists (select 1 from jsonb_array_elements(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'warnings') w
                   where w->>'kind' = 'inventory' and w->>'title' = 'Low stock: zz-l3 Low Item'),
  'the brownout notice and the low-stock item are warnings');
select ok((select w->'detail'->>'grid_line' = 'Feeder [hidden]' and w->'detail'->>'posted_by' = 'Ana [hidden]'
             from jsonb_array_elements(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'kind' = 'brownout'),
  'the brownout feeder and poster name are redacted');
select is((select count(*)::int from jsonb_object_keys(coalesce(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'weather'->'current', '{}'::jsonb)) k
            where k not in ('temp','emoji','description','rain_prob','today_high','today_low','humidity','uv_label')), 0,
  'the weather block holds the eight display fields and nothing else');
select is(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'id_photo_path',
          'e3600000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 'the current guest card carries the guest''s own ID photo path');
select is((select count(*)::int from storage.objects where bucket_id = 'guest-id-photos'
            and name = 'e3600000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg'), 1, 'a cleaner can read the current guest''s ID photo');
select is((select count(*)::int from storage.objects where bucket_id = 'guest-id-photos'
            and name = 'e3600000-0000-4000-8000-0000000000e3/11111111-0000-4000-8000-000000000003.jpg'), 1, 'a cleaner can read the next guest''s ID photo');
select is((select count(*)::int from storage.objects where bucket_id = 'guest-id-photos'
            and name in ('e3600000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-000000000002.jpg',
                         'e3600000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg')), 0,
  'a companion''s photo and another guest''s photo stay closed to a cleaner');

-- Maintenance is staff too (D-302.1): the current and next guest's ID photos, and still nothing else.
select set_config('request.jwt.claims', json_build_object('sub','e3600000-0000-4000-8000-000000000003','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'current_guest'->>'id_photo_path',
          'e3600000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 'maintenance gets the current guest''s ID photo path (D-302.1)');
select is((select count(*)::int from storage.objects where bucket_id = 'guest-id-photos'), 2, 'maintenance reads only the current and next guest''s ID photos');

-- The admin sees every open finding.
select set_config('request.jwt.claims', json_build_object('sub','e3600000-0000-4000-8000-000000000002','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->'warnings') w
            where w->>'kind' = 'verifier' and w->>'title' like 'zz-l3%'), 2, 'an admin sees both findings');
select is(public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')->>'role', 'admin', 'the payload names the caller''s role');

-- A disabled staff account: forbidden, and no ID photo.
reset role;
update public.staff_access_profiles set disabled_at = now() where user_id = 'e3600000-0000-4000-8000-000000000003';
select set_config('request.jwt.claims', json_build_object('sub','e3600000-0000-4000-8000-000000000003','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select throws_ok($$select public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')$$, '42501', 'forbidden', 'a disabled account is forbidden');

-- A user with no staff profile.
select set_config('request.jwt.claims', json_build_object('sub','e3600000-0000-4000-8000-0000000000ff','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select throws_ok($$select public.staff_home_v1('e3600000-0000-4000-8000-0000000000b0')$$, '42501', 'forbidden', 'no staff profile means forbidden');
select is((select count(*)::int from storage.objects where bucket_id = 'guest-id-photos'), 0, 'no staff profile reads no ID photo');

reset role;
select * from finish();
rollback;
