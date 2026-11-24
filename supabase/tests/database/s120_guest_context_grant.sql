-- Session 120 (lane S3, part B): release s120_guest_context_grant_20261120. public.guest_context_v1(uuid, uuid, text) is for service_role only.
-- Refusals are tested by calling as the refused role. Synthetic fixture only (property e1200003-...). Everything rolls back.
begin;
select plan(7);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;

insert into public.properties(id, name, is_active) values ('e1200003-0000-4000-8000-0000000000b0', 'Synthetic S120 GCtx', true);

select ok((select prosecdef from pg_proc where oid = 'public.guest_context_v1(uuid,uuid,text)'::regprocedure), 'the function is still security definer (only the grants changed)');
select ok(not has_function_privilege('anon', 'public.guest_context_v1(uuid,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.guest_context_v1(uuid,uuid,text)', 'execute')
      and has_function_privilege('service_role', 'public.guest_context_v1(uuid,uuid,text)', 'execute'), 'only service_role holds execute');
select ok((select p.proacl is not null from pg_proc p where p.oid = 'public.guest_context_v1(uuid,uuid,text)'::regprocedure)
      and not exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
                       where p.oid = 'public.guest_context_v1(uuid,uuid,text)'::regprocedure
                         and a.grantee <> p.proowner and a.grantee <> (select r.oid from pg_roles r where r.rolname = 'service_role')),
  'the ACL names only the owner and service_role: PUBLIC holds nothing, whatever the restore left');

set local role authenticated;
set local request.jwt.claims = '{"sub":"e1200003-0000-4000-8000-000000000001"}';
select throws_ok($$select public.guest_context_v1('e1200003-0000-4000-8000-0000000000b0', null, 'zz-no-such-guest-zz')$$, '42501', null, 'a signed-in user is refused (42501)');
reset role;

set local role anon;
select throws_ok($$select public.guest_context_v1('e1200003-0000-4000-8000-0000000000b0', null, 'zz-no-such-guest-zz')$$, '42501', null, 'anon is refused (42501)');
reset role;

set local role service_role;
select is((select (public.guest_context_v1('e1200003-0000-4000-8000-0000000000b0', null, 'zz-no-such-guest-zz') ->> 'found')::boolean), false, 'service_role can call it: an unknown guest is found = false');
select ok(public.guest_context_v1('e1200003-0000-4000-8000-0000000000b0', null, 'zz-no-such-guest-zz') ? 'found', 'service_role gets the usual shape back');
reset role;

select * from finish();
rollback;
