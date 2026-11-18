-- Session 119 (lane Q): release s119_staying_20261119. stay_staying, set_stay_staying_v1, confirm_stay_staying_suggestion_v1,
-- set_stay_staying_suggestion_v1 (Cassy, service_role) and the `staying` object in staff_home_v1 current_guest / next_guest.
-- Synthetic fixtures only (uuids e9190000-..., property ...b0 and ...b1); every lookup is scoped to them because a real backup holds real rows.
-- Refusals are tested by calling as the refused role. Grants are not asserted beyond "no direct table access" and the refused callers (a --no-acl rehearsal carries
-- none, the migration revokes explicitly); the release forward checks prove the function grants.
-- Everything rolls back.
begin;
select plan(86);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  ('e9190000-0000-4000-8000-0000000000b0', 'Synthetic S119 A', true),
  ('e9190000-0000-4000-8000-0000000000b1', 'Synthetic S119 B', true);
insert into auth.users(id) values
  ('e9190000-0000-4000-8000-000000000001'), ('e9190000-0000-4000-8000-000000000002'),
  ('e9190000-0000-4000-8000-000000000003'), ('e9190000-0000-4000-8000-000000000004');
insert into public.staff_access_profiles(user_id, role) values
  ('e9190000-0000-4000-8000-000000000001', 'cleaner'),
  ('e9190000-0000-4000-8000-000000000002', 'admin'),
  ('e9190000-0000-4000-8000-000000000003', 'finance');
-- 04 has no staff profile at all; finance (03) reads operations but is not a submit_cleaning role.
insert into public.staff_property_access(user_id, property_id) values
  ('e9190000-0000-4000-8000-000000000001', 'e9190000-0000-4000-8000-0000000000b0'),
  ('e9190000-0000-4000-8000-000000000002', 'e9190000-0000-4000-8000-0000000000b0'),
  ('e9190000-0000-4000-8000-000000000003', 'e9190000-0000-4000-8000-0000000000b0');
-- cur is in the house now, nxt is the next arrival, far is a later arrival, blk is a block (not a stay), other belongs to property B.
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'airbnb', 'confirmed', 'Zz S119 Current', current_date - 1, current_date + 2),
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'airbnb', 'confirmed', 'Zz S119 Next', current_date + 3, current_date + 5),
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-far', 'airbnb', 'confirmed', 'Zz S119 Far', current_date + 9, current_date + 11),
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-blk', 'airbnb', 'blocked', null, current_date + 20, current_date + 22),
  ('e9190000-0000-4000-8000-0000000000b1', 'zz-s119-other', 'airbnb', 'confirmed', 'Zz S119 Other', current_date + 3, current_date + 5);

-- 1-3. tables are closed ------------------------------------------------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.stay_staying'::regclass, 'public.stay_staying_history'::regclass)), 'RLS is on for both tables');
select ok(not has_table_privilege('authenticated', 'public.stay_staying', 'select, insert, update, delete')
      and not has_table_privilege('anon', 'public.stay_staying', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.stay_staying', 'select, insert, update, delete'), 'stay_staying has no direct grant for any API role');
select ok(not has_table_privilege('authenticated', 'public.stay_staying_history', 'select, insert, update, delete')
      and not has_table_privilege('anon', 'public.stay_staying_history', 'select, insert, update, delete')
      and not has_table_privilege('service_role', 'public.stay_staying_history', 'select, insert, update, delete'), 'stay_staying_history has no direct grant for any API role');

-- 4-8. the gate -------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000004"}';
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana', 'staff', 0, null, 'gate-1')$$,
  '42501', 'forbidden', 'a user with no staff profile cannot set names');
select throws_ok($$select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', true, 1, null)$$,
  '42501', 'forbidden', 'a user with no staff profile cannot confirm');
reset role;
set local role authenticated;
set local request.jwt.claims = '{}';
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana', 'staff', 0, null, 'gate-2')$$,
  '42501', 'forbidden', 'no session cannot set names');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000003"}';
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana', 'staff', 0, null, 'gate-3')$$,
  '42501', 'forbidden', 'finance reads operations but cannot type names');
select throws_ok($$select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', true, 1, null)$$,
  '42501', 'forbidden', 'finance cannot confirm a suggestion');
reset role;

-- 9-16. cleaner: scope and validation ---------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b1', 'zz-s119-other', 'Ana', 'staff', 0, null, 'val-0')$$,
  '42501', 'forbidden', 'cleaner: another property is refused');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana', 'admin', 0, null, 'val-1')$$,
  '42501', 'forbidden', 'cleaner cannot claim source admin');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana', 'cassy', 0, null, 'val-2')$$,
  '22023', 'source_invalid', 'source must be admin or staff');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana', 'staff', 0, null, null)$$,
  '22023', 'idempotency_key_invalid', 'an idempotency key is required');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', ' ', 'Ana', 'staff', 0, null, 'val-3')$$,
  '22023', 'uid_required', 'a blank stay uid is refused');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', repeat('x', 301), 'staff', 0, null, 'val-4')$$,
  '22023', 'names_too_long', '301 characters are refused');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nope', 'Ana', 'staff', 0, null, 'val-5')$$,
  'P0002', 'stay_not_found', 'an unknown stay is refused');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-blk', 'Ana', 'staff', 0, null, 'val-6')$$,
  'P0002', 'stay_not_found', 'a calendar block is not a stay');
reset role;
select is((select count(*)::int from public.stay_staying where property_id = 'e9190000-0000-4000-8000-0000000000b0'), 0, 'every refused call wrote nothing');

-- 17-18. staff_home_v1 before any write: version 0, nothing typed -------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'current_guest' -> 'staying'),
  '{"names": null, "source": null, "version": 0, "suggestion": null}'::jsonb, 'cleaner: a stay nobody typed yet reads version 0 with no names');
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' ->> 'uid'), 'zz-s119-nxt', 'the next guest is the fixture arrival');

-- 19-27. cleaner types names: lock, idempotency ---------------------------------------------------------------------------------------------------
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', '  Ana and Ben  ', 'staff', 0, 'arrived', 'k1')),
  '{"ok": true, "replay": false, "version": 1, "names": "Ana and Ben", "source": "staff"}'::jsonb, 'cleaner: first write trims the names and starts at version 1');
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana and Ben', 'staff', 0, 'arrived', 'k1')),
  '{"ok": true, "replay": true, "version": 1, "names": "Ana and Ben", "source": "staff"}'::jsonb, 'the same key with the same names replays the first result (even with a now-stale expected version)');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Someone Else', 'staff', 1, null, 'k1')$$,
  '22023', 'idempotency_key_reused', 'the same key with other names is refused');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana, Ben and Cy', 'staff', 0, null, 'k2')$$,
  '40001', null, 'a stale expected version (0 after the first write) is 40001');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana, Ben and Cy', 'staff', null, null, 'k2')$$,
  '40001', null, 'a null expected version on an existing row is 40001');
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana, Ben and Cy', 'staff', 1, null, 'k3')),
  '{"ok": true, "replay": false, "version": 2, "names": "Ana, Ben and Cy", "source": "staff"}'::jsonb, 'cleaner: the right expected version moves it to 2');
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'current_guest' -> 'staying'),
  '{"names": "Ana, Ben and Cy", "source": "staff", "version": 2, "suggestion": null}'::jsonb, 'cleaner: staff_home_v1 current_guest.staying carries the typed names');
reset role;
select is((select count(*)::int from public.stay_staying_history where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-cur'), 2,
  'two writes, two history rows (the replay and the refusals added none)');
select is((select before_state is null and after_state ->> 'names' = 'Ana and Ben' and changed_by = 'e9190000-0000-4000-8000-000000000001' and reason = 'arrived' and idempotency_key = 'k1'
  from public.stay_staying_history where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-cur' and idempotency_key = 'k1'), true,
  'the first history row has no before, the after, the actor, the reason and the key');

-- 28-31. admin: source admin, clearing -------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000002"}';
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Ana, Ben, Cy and Dan', 'admin', 2, null, 'k4')),
  '{"ok": true, "replay": false, "version": 3, "names": "Ana, Ben, Cy and Dan", "source": "admin"}'::jsonb, 'admin: may write with source admin');
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-far', '   ', 'staff', 0, null, 'k5')),
  '{"ok": true, "replay": false, "version": 1, "names": null, "source": null}'::jsonb, 'admin: blank names make a row with no names and no source');
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-far', 'Eli', 'staff', 1, null, 'k6') ->> 'source'), 'staff', 'admin may still write source staff');
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-far', null, 'staff', 2, 'typed by mistake', 'k7')),
  '{"ok": true, "replay": false, "version": 3, "names": null, "source": null}'::jsonb, 'admin: clearing the names empties the source too');
reset role;

-- 32-37. Cassy: suggestions only --------------------------------------------------------------------------------------------------------------------
set local role service_role;
set local request.jwt.claims = '{}';
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', 'Someone Else')),
  '{"ok": false, "error": "names_set"}'::jsonb, 'Cassy: refused while names are set');
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nope', 'Dee and Eli')),
  '{"ok": false, "error": "stay_not_found"}'::jsonb, 'Cassy: an unknown stay is reported, nothing is written');
select throws_ok($$select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', '   ')$$, '22023', 'suggestion_invalid', 'Cassy: a blank suggestion is refused');
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', ' Dee and Eli ')),
  '{"ok": true, "unchanged": false, "version": 1}'::jsonb, 'Cassy: first suggestion creates the row at version 1');
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'Dee and Eli')),
  '{"ok": true, "unchanged": true, "version": 1}'::jsonb, 'Cassy: the same pending text changes nothing');
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'Dee, Eli and Flo')),
  '{"ok": true, "unchanged": false, "version": 2}'::jsonb, 'Cassy: a newer suggestion replaces the pending one (still one row)');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'Dee', 'staff', 2, null, 'cassy-1')$$,
  '42501', null, 'service_role cannot call the person RPC');
reset role;
select is((select names is null and source is null and suggestion = 'Dee, Eli and Flo' and suggestion_status = 'pending' and count(*) over () = 1
  from public.stay_staying where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-nxt'), true,
  'Cassy wrote only the suggestion fields: names and source are still null');

-- 39-40. who can call the Cassy RPC ---------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000002"}';
select throws_ok($$select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'Admin typed')$$, '42501', null, 'even an admin session cannot call the Cassy RPC');
reset role;
set local role anon;
select throws_ok($$select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'Anon typed')$$, '42501', null, 'anon cannot call the Cassy RPC');
reset role;

-- 41-43. staff_home_v1: the suggestion shows to the roles that can act on it only ------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying'),
  '{"names": null, "source": null, "version": 2, "suggestion": "Dee, Eli and Flo"}'::jsonb, 'cleaner: next_guest.staying shows the pending suggestion');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000003"}';
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying'),
  '{"names": null, "source": null, "version": 2}'::jsonb, 'finance: next_guest.staying has no suggestion key at all');
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'current_guest' -> 'staying' ->> 'names'), 'Ana, Ben, Cy and Dan', 'finance still reads the typed names');
reset role;

-- 44-53. confirm / reject ---------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select throws_ok($$select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', true, 1, null)$$,
  '40001', null, 'confirm with a stale version is 40001');
select is((select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-cur', true, 3, null)),
  '{"ok": false, "error": "no_pending_suggestion", "names": "Ana, Ben, Cy and Dan", "version": 3}'::jsonb, 'confirm on a stay with no pending suggestion says so');
select is((select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', false, 2, 'not them')),
  '{"ok": true, "accepted": false, "version": 3, "names": null, "source": null}'::jsonb, 'cleaner: reject keeps names empty and moves the version');
reset role;
select is((select suggestion_status from public.stay_staying where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-nxt'), 'dismissed', 'the rejected suggestion is dismissed');
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying' -> 'suggestion'), 'null'::jsonb, 'a dismissed suggestion is not shown');
reset role;
set local role service_role;
set local request.jwt.claims = '{}';
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'DEE, ELI AND FLO')),
  '{"ok": false, "error": "dismissed"}'::jsonb, 'Cassy: the text a person dismissed is not offered again (any case)');
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', 'Dee and Gus')),
  '{"ok": true, "unchanged": false, "version": 4}'::jsonb, 'Cassy: different text after a dismissal is pending again');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select is((select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', true, 4, 'looks right')),
  '{"ok": true, "accepted": true, "version": 5, "names": "Dee and Gus", "source": "staff"}'::jsonb, 'cleaner: accept copies the suggestion to names with source staff');
select is((select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-nxt', true, 5, null)),
  '{"ok": false, "error": "no_pending_suggestion", "names": "Dee and Gus", "version": 5}'::jsonb, 'the suggestion is spent after an accept');
reset role;
select is((select suggestion is null and suggestion_at is null and suggestion_status is null from public.stay_staying where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-nxt'), true,
  'accept clears the suggestion fields');

-- 54-57. admin accepts (source admin); typing names clears a pending suggestion -----------------------------------------------------------------
set local role service_role;
set local request.jwt.claims = '{}';
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-far', 'Hal and Ida')), '{"ok": true, "unchanged": false, "version": 4}'::jsonb,
  'Cassy: a suggestion on a stay whose names were cleared is allowed');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000002"}';
select is((select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-far', true, 4, null) ->> 'source'), 'admin', 'admin: accept records source admin');
reset role;
set local role service_role;
set local request.jwt.claims = '{}';
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-far', 'Zed')), '{"ok": false, "error": "names_set"}'::jsonb, 'Cassy: the accepted names are not touched afterwards');
reset role;
-- a pending suggestion on a fresh stay, then a person types names over it
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-new', 'airbnb', 'confirmed', 'Zz S119 New', current_date + 30, current_date + 32);
set local role service_role;
set local request.jwt.claims = '{}';
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-new', 'Jo and Kim') ->> 'version'), '1', 'Cassy: a suggestion on a new stay');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-new', 'Jo, Kim and Lee', 'staff', 1, null, 'k8')),
  '{"ok": true, "replay": false, "version": 2, "names": "Jo, Kim and Lee", "source": "staff"}'::jsonb, 'cleaner: typing names over a pending suggestion works');
reset role;
select is((select suggestion is null and suggestion_status is null and names = 'Jo, Kim and Lee' from public.stay_staying where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-new'), true,
  'typing names cleared the pending suggestion');

-- 58-61. history and the re-cut body -----------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from public.stay_staying_history where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-nxt'), 5,
  'next stay history: suggest, suggest, reject, suggest, accept');
select is((select count(*)::int from public.stay_staying_history where property_id = 'e9190000-0000-4000-8000-0000000000b0' and action = 'suggest' and changed_by is null), 5,
  'Cassy history rows carry no actor (five suggestions across the suite)');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure), '18f5723d01ce20788d6fb2f114129ed8', 'staff_home_v1 is the s119 body');
select ok((select prosecdef and provolatile = 's' and proconfig = array['search_path=""'] from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure), 'staff_home_v1 is still stable, security definer, empty search_path');

-- 66-78. D-289 contact refusal, blank save, whitespace, no_pending_suggestion state, redacted reads ---------------------------------------------------
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-con', 'airbnb', 'confirmed', 'Zz S119 Con', current_date + 40, current_date + 42),
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-ws',  'airbnb', 'confirmed', 'Zz S119 Ws',  current_date + 50, current_date + 52),
  ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-bl',  'airbnb', 'confirmed', 'Zz S119 Bl',  current_date + 60, current_date + 62);
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-con', 'Ana 0917 123 4567', 'staff', 0, null, 'con-1')$$,
  '22023', 'names_contact', 'a phone number in the names is refused');
select throws_ok($$select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-con', 'Ana ana@example.com', 'staff', 0, null, 'con-2')$$,
  '22023', 'names_contact', 'an e-mail in the names is refused');
-- no row at all: confirm hands back the empty state to reconcile against
select is((select public.confirm_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-con', true, 0, null)),
  '{"ok": false, "error": "no_pending_suggestion", "names": null, "version": 0}'::jsonb, 'confirm with no row returns no_pending_suggestion with names null and version 0');
-- whitespace: a newline-only name is a blank save, tabs/CR/LF around a name are trimmed
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-ws', E'\n\t \r', 'staff', 0, null, 'ws-1')),
  '{"ok": true, "replay": false, "version": 1, "names": null, "source": null}'::jsonb, 'a newline-only name is a blank save, not a name');
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-ws', E'\r\n Ana\t\n', 'staff', 1, null, 'ws-2')),
  '{"ok": true, "replay": false, "version": 2, "names": "Ana", "source": "staff"}'::jsonb, 'tabs, CR and LF around the names are trimmed');
reset role;
select throws_ok($$insert into public.stay_staying(property_id, stay_uid, names, source) values ('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-chk', E'\n', 'staff')$$,
  '23514', null, 'the table refuses a newline-only name');
-- Cassy: contact text is refused, nothing is stored
set local role service_role;
set local request.jwt.claims = '{}';
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-con', 'Dee dee@example.com')),
  '{"ok": false, "error": "contact"}'::jsonb, 'Cassy: a suggestion with an e-mail returns ok false, error contact');
reset role;
select is((select count(*)::int from public.stay_staying where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-con'), 0, 'the refused suggestion and names stored nothing');
-- blank save keeps a pending suggestion
set local role service_role;
set local request.jwt.claims = '{}';
select is((select public.set_stay_staying_suggestion_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-bl', 'Mo and Ned') ->> 'version'), '1', 'Cassy: a suggestion on the stay used for the blank-save case');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select is((select public.set_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', 'zz-s119-bl', '  ', 'staff', 1, null, 'bl-1') ->> 'version'), '2', 'a blank save on a row with a pending suggestion succeeds');
reset role;
select is((select suggestion = 'Mo and Ned' and suggestion_status = 'pending' and suggestion_at is not null and names is null
  from public.stay_staying where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-bl'), true, 'the blank save did not drop the pending suggestion');
-- reads redact: rows written before this fix (direct update) with a phone and an e-mail show the redacted form
update public.stay_staying set names = 'Dee 0917 123 4567', suggestion = 'Mail dee@example.com', suggestion_status = 'pending', suggestion_at = now()
  where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-nxt';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying' ->> 'names' like '%[hidden]%'
  and public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying' ->> 'names' not like '%4567%'), true, 'staff_home_v1 redacts a phone number in stored names');
select is((select public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying' ->> 'suggestion' like '%[hidden]%'
  and public.staff_home_v1('e9190000-0000-4000-8000-0000000000b0') -> 'next_guest' -> 'staying' ->> 'suggestion' not like '%example.com%'), true, 'staff_home_v1 redacts an e-mail in a stored suggestion');
reset role;

-- 79-86. admin_stay_staying_v1: owner/admin read, unredacted, pending only, cap, gate ---------------------------------------------------------------
-- state here: zz-s119-bl pending 'Mo and Ned' (no names); zz-s119-nxt names with a phone + pending suggestion with an e-mail; zz-s119-ws names 'Ana'.
update public.stay_staying set suggestion = 'Old guess', suggestion_status = 'dismissed', suggestion_at = now()
  where property_id = 'e9190000-0000-4000-8000-0000000000b0' and stay_uid = 'zz-s119-ws';
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000002"}';
select is((select jsonb_array_length(public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', array['zz-s119-bl', 'zz-s119-ws', 'zz-s119-nope']))), 2,
  'admin reads only the stays that have a row (unknown and row-less uids are left out)');
select is((select public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', array['zz-s119-bl']) -> 0),
  '{"stay_uid": "zz-s119-bl", "names": null, "source": null, "suggestion": "Mo and Ned", "version": 2}'::jsonb, 'admin gets a pending suggestion and the version');
select is((select public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', array['zz-s119-ws']) -> 0 -> 'suggestion'), 'null'::jsonb, 'admin does not get a dismissed suggestion');
select is((select public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', array['zz-s119-ws']) -> 0 ->> 'names'), 'Ana', 'admin gets the names');
select is((select public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', array['zz-s119-nxt']) -> 0 ->> 'names'), 'Dee 0917 123 4567', 'admin names are not redacted (manage_operations is owner/admin only)');
select is((select public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', array[]::text[])), '[]'::jsonb, 'an empty uid list returns an empty array');
select throws_ok($$select public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', (select array_agg('u' || g) from generate_series(1, 201) g))$$, '22023', 'too_many_uids', 'more than 200 uids is refused');
set local request.jwt.claims = '{"sub":"e9190000-0000-4000-8000-000000000001"}';
select throws_ok($$select public.admin_stay_staying_v1('e9190000-0000-4000-8000-0000000000b0', array['zz-s119-bl'])$$, '42501', null, 'a cleaner cannot call the admin read');
reset role;

select * from finish();
rollback;
