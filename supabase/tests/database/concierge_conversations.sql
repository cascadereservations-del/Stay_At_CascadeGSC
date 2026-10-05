-- Session 72, lane L6: release concierge_conversations_20261006 (SPEC-42 section 7).
-- Who may read Cassy threads from the dashboard, the shape and order of the list, and that the tables themselves stay closed.
-- Synthetic rows only (psid zz-conv-*, users e7200000-*), every assertion about rows filters on them, so a restored production copy
-- never interferes. Everything goes with the closing rollback.
begin;
select plan(22);

select has_function('public', 'concierge_conversations_v1', array['integer'], 'concierge_conversations_v1(int) exists');
select has_function('public', 'concierge_thread_v1', array['text'], 'concierge_thread_v1(text) exists');
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.oid in ('public.concierge_conversations_v1(int)'::regprocedure, 'public.concierge_thread_v1(text)'::regprocedure)),
  'both RPCs are security definer with an empty search_path');
select ok(has_function_privilege('authenticated', 'public.concierge_conversations_v1(int)', 'execute')
      and has_function_privilege('authenticated', 'public.concierge_thread_v1(text)', 'execute'),
  'signed-in staff may call both');
select ok(not has_function_privilege('anon', 'public.concierge_conversations_v1(int)', 'execute')
      and not has_function_privilege('anon', 'public.concierge_thread_v1(text)', 'execute')
      and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid in ('public.concierge_conversations_v1(int)'::regprocedure, 'public.concierge_thread_v1(text)'::regprocedure) and a.grantee = 0),
  'anon and PUBLIC cannot call either');

-- Fixtures: A owner, B admin, C cleaner, D disabled admin.
insert into auth.users(id) values
  ('e7200000-0000-4000-8000-0000000006a1'), ('e7200000-0000-4000-8000-0000000006a2'),
  ('e7200000-0000-4000-8000-0000000006a3'), ('e7200000-0000-4000-8000-0000000006a4') on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  ('e7200000-0000-4000-8000-0000000006a1', 'owner', null),
  ('e7200000-0000-4000-8000-0000000006a2', 'admin', null),
  ('e7200000-0000-4000-8000-0000000006a3', 'cleaner', null),
  ('e7200000-0000-4000-8000-0000000006a4', 'admin', now())
on conflict(user_id) do update set role = excluded.role, disabled_at = excluded.disabled_at, sessions_revoked_after = null;

insert into public.concierge_threads(psid, guest_name, history, last_risk, updated_at) values
  -- older, has an open handoff: must sort first
  ('zz-conv-old-open', 'Zz Old', '[{"role":"guest","text":"is there parking","at":"2026-09-01T01:00:00Z"},{"role":"bot","text":"Yes, one slot.","at":"2026-09-01T01:00:05Z"}]', 'priority', '2026-09-01T01:00:05Z'),
  -- newer, no open handoff; two guest turns, the last guest turn is the later one
  ('zz-conv-new', 'Zz New', jsonb_build_array(
      jsonb_build_object('role','guest','text','hello','at','2026-10-01T01:00:00Z'),
      jsonb_build_object('role','bot','text','hi','at','2026-10-01T01:00:05Z'),
      jsonb_build_object('role','guest','text','later question','at','2026-10-02T03:04:05Z','route', jsonb_build_object('re','none')),
      jsonb_build_object('role','bot','text',repeat('x', 300),'at','2026-10-02T03:04:09Z')), null, '2026-10-02T03:04:09Z'),
  -- a guest turn with a malformed timestamp must not break the list
  ('zz-conv-bad-at', 'Zz Bad', '[{"role":"guest","text":"odd","at":"not-a-date"},{"role":"bot","text":"ok","at":"2026-10-03T00:00:00Z"}]', null, '2026-10-03T00:00:00Z');
insert into public.concierge_handoffs(psid, guest_name, guest_text, risk, status, created_at) values
  ('zz-conv-old-open', 'Zz Old', 'is there parking', 'priority', 'open', '2026-09-01T01:00:01Z'),
  ('zz-conv-old-open', 'Zz Old', 'earlier ask', 'priority', 'sent', '2026-08-31T01:00:01Z'),
  ('zz-conv-new', 'Zz New', 'later question', 'low', 'dismissed', '2026-10-02T03:04:06Z');

-- Not an owner or admin: refused.
set local role authenticated;
set local request.jwt.claims = '{"sub":"e7200000-0000-4000-8000-0000000006a3","aal":"aal1"}';
select throws_ok($$select * from public.concierge_conversations_v1(100)$$, '42501', null, 'a cleaner cannot list conversations');
select throws_ok($$select public.concierge_thread_v1('zz-conv-new')$$, '42501', null, 'a cleaner cannot read a thread');
select throws_ok($$select * from public.concierge_threads$$, '42501', null, 'the threads table is still closed to a signed-in user');
set local request.jwt.claims = '{"sub":"e7200000-0000-4000-8000-0000000006a4","aal":"aal1"}';
select throws_ok($$select * from public.concierge_conversations_v1(100)$$, '42501', null, 'a disabled admin is refused');

-- The owner reads.
set local request.jwt.claims = '{"sub":"e7200000-0000-4000-8000-0000000006a1","aal":"aal1"}';
select is((select count(*)::int from public.concierge_conversations_v1(100) where psid like 'zz-conv-%'), 3, 'the owner sees the three synthetic threads');
select is((select array_agg(t.psid order by t.n) from public.concierge_conversations_v1(100) with ordinality as t(psid, psid_short, guest_name, updated_at, last_role, last_text, last_guest_at, open_handoffs, human_until, last_risk, n) where t.psid like 'zz-conv-%'),
  array['zz-conv-old-open', 'zz-conv-bad-at', 'zz-conv-new'], 'a thread with an open handoff sorts first, then newest first');
select is((select open_handoffs from public.concierge_conversations_v1(100) where psid = 'zz-conv-old-open'), 1, 'only the open handoff is counted');
select is((select open_handoffs from public.concierge_conversations_v1(100) where psid = 'zz-conv-new'), 0, 'a dismissed handoff is not counted');
select is((select last_guest_at from public.concierge_conversations_v1(100) where psid = 'zz-conv-new'), '2026-10-02T03:04:05Z'::timestamptz, 'last_guest_at is the latest guest turn');
select is((select last_guest_at from public.concierge_conversations_v1(100) where psid = 'zz-conv-bad-at'), null, 'a malformed guest timestamp is ignored, not an error');
select is((select last_role || ':' || length(last_text) from public.concierge_conversations_v1(100) where psid = 'zz-conv-new'), 'bot:160', 'the excerpt is the last turn cut to 160 characters');
select is((select psid_short from public.concierge_conversations_v1(100) where psid = 'zz-conv-new'), left(md5('zz-conv-new'), 8), 'the display handle is 8 characters of the md5');
select is((select count(*)::int from public.concierge_conversations_v1(1)), 1, 'p_limit caps the list');

-- One thread, as the admin.
set local request.jwt.claims = '{"sub":"e7200000-0000-4000-8000-0000000006a2","aal":"aal1"}';
select is((select jsonb_array_length(public.concierge_thread_v1('zz-conv-new') -> 'history')), 4, 'the admin gets the whole history');
select is((select array_agg(h ->> 'status') from jsonb_array_elements(public.concierge_thread_v1('zz-conv-old-open') -> 'handoffs') h), array['sent', 'open'], 'the thread carries its handoffs, oldest first');
select is(public.concierge_thread_v1('zz-conv-no-such-thread'), null, 'an unknown thread is null, not an error');
reset role;

-- The rollback body removes both functions.
drop function public.concierge_conversations_v1(int);
drop function public.concierge_thread_v1(text);
select is((select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace and proname in ('concierge_conversations_v1', 'concierge_thread_v1')), 0, 'the rollback drops both functions');

select * from finish();
rollback;
