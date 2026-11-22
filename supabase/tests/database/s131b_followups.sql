-- Session 131b follow-up: release s131b_followups_20261201 (D-395). bill_pay_settle_v1 refuses (reading_date_invalid, key before) a meter bill whose reading_date is on or after the earliest reading_date of a PAID bill of the
-- same property and kind with a LATER period. Everything else of the s131 settle is unchanged (the s131 and s127 suites still run on the same copy).
-- Synthetic fixtures only (uuids e131b000-..., properties ...c1 to ...c6, names "Zz S131b ..."). Today is faked INSIDE this transaction by replacing public.manila_today() (rolled back with everything else).
-- Nothing in this file can run without a Postgres that holds the Cascade schema with s131 and s131b applied: it is run by the rehearsal (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>).
begin;
select plan(14);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant select on public.app_settings to anon, authenticated;
grant select on storage.objects to authenticated;

create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e131b000-0000-4000-8000-0000000000' || p)::uuid $$;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.c2(f text, a uuid, b jsonb) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute format('select public.%I(%L, %L::jsonb)', f, a, b) into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- Manila today, faked for the whole transaction
create or replace function public.manila_today() returns date language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('s131b.today', true), '')::date, (now() at time zone 'Asia/Manila')::date)
$$;
-- a bill row's id by property, kind and period
create function pg_temp.bid(k text, prop text, per text) returns uuid language sql stable as $$
  select id from public.utility_bills where property_id = pg_temp.id(prop) and kind = k and period = per
$$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
-- a stored screenshot: the object in the private bucket and the sha256 upload-photo recorded for it (md5(sha) || md5(sha || 'x')); returns the path
create function pg_temp.ph(prop text, usr text, nm text, sha text) returns text language plpgsql security definer as $f$
declare p text := pg_temp.id(prop)::text || '/' || pg_temp.id(usr)::text || '/' || nm;
begin
  insert into storage.objects(bucket_id, name) values ('cleaning-photos', p);
  insert into public.staff_upload_hashes(path, sha256) values (p, md5(sha) || md5(sha || 'x'));
  return p;
end $f$;
-- a settle proof for the property and the admin a2: amount amt, plus any extra keys (reading_date)
create function pg_temp.pf(prop text, nm text, sha text, amt numeric, extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('path', pg_temp.ph(prop, 'a2', nm, sha), 'amount', amt) || extra
$$;
-- settle bill k/period of property prop as the admin a2 with the reading date d; the result is stored in _t under key n
create function pg_temp.settle(n text, k text, prop text, per text, nm text, amt numeric, d text) returns void language plpgsql as $f$
declare v_id uuid := pg_temp.bid(k, prop, per); v_proof jsonb := pg_temp.pf(prop, nm, n, amt, jsonb_build_object('reading_date', d));
begin
  perform pg_temp.as_user(pg_temp.id('a2'));
  insert into _t select n, pg_temp.c2('bill_pay_settle_v1', v_id, v_proof);
  reset role;
end $f$;
-- the utility_billing setting the migration documents as the default, and the contract default of bill_schedule
delete from public.app_settings where key in ('utility_billing', 'bill_schedule');
insert into public.app_settings(key, value) values ('utility_billing', public.utility_billing_default_v1());
select set_config('s131b.today', '2026-11-22', true);

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  (pg_temp.id('c1'), 'Zz S131b later paid', true), (pg_temp.id('c2'), 'Zz S131b normal flow', true), (pg_temp.id('c3'), 'Zz S131b other kind', true),
  (pg_temp.id('c4'), 'Zz S131b other property', true), (pg_temp.id('c5'), 'Zz S131b s131 refusals', true);
insert into auth.users(id, email, raw_user_meta_data) values (pg_temp.id('a2'), 'zz131b-admin@example.com', '{"display_name":"Zz Admin"}'::jsonb);
insert into public.staff_access_profiles(user_id, role, disabled_at) values (pg_temp.id('a2'), 'admin', null);
insert into public.staff_property_access(user_id, property_id) select pg_temp.id('a2'), pg_temp.id(b) from unnest(array['c1', 'c2', 'c3', 'c4', 'c5']) b;
-- the ledger holds one row per bill ref across properties: clear the refs this suite settles (rolled back with the suite)
delete from public.transactions where source = 'bill' and external_ref in ('bill:electric:2026-09', 'bill:electric:2026-10', 'bill:electric:2026-11', 'bill:water:2026-10', 'bill:water:2026-11');

-- 1. a later-period paid bill blocks the reading date of an older bill ------------------------------------------------------------------------------------------------------------------------
-- Today 22 Nov 2026, open_from 21 Oct. c1 electric: 2026-11 is already PAID with reading date 5 Nov (a later bill paid before the older one), 2026-10 is due (reopened). Settling 2026-10 with 10 Nov, or with 5 Nov itself, would
-- move the cycle start of the later bill: both are refused with reading_date_invalid and before = 2026-11-05, nothing stored (status due, no reading_date, no ledger row). 4 Nov is before it and inside the window
-- (after 21 Oct, not before 1 Sep, not after today): the bill is paid and the date stored.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('c1'), 'electric', '2026-11', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2026-11-05');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('c1'), 'electric', '2026-10', 1000, 'due');
select pg_temp.settle('a1', 'electric', 'c1', '2026-10', 'zz131b-proof-0001-a.jpg', 1000, '2026-11-10');
select pg_temp.settle('a2', 'electric', 'c1', '2026-10', 'zz131b-proof-0002-a.jpg', 1000, '2026-11-05');
select ok((select v = '{"ok":false,"reason":"reading_date_invalid","before":"2026-11-05"}'::jsonb from _t where k = 'a1')
          and (select status = 'due' and reading_date is null and paying_by is null from public.utility_bills where id = pg_temp.bid('electric', 'c1', '2026-10'))
          and (select count(*) = 0 from public.transactions where source = 'bill' and property_id = pg_temp.id('c1')),
          'a reading date after the later paid bill''s (10 Nov vs 5 Nov) is refused with reading_date_invalid and before = 2026-11-05; nothing is stored');
select ok((select v = '{"ok":false,"reason":"reading_date_invalid","before":"2026-11-05"}'::jsonb from _t where k = 'a2')
          and (select status = 'due' and reading_date is null from public.utility_bills where id = pg_temp.bid('electric', 'c1', '2026-10')),
          'the same date as the later paid bill (5 Nov) is refused too: on or after');
select pg_temp.settle('a3', 'electric', 'c1', '2026-10', 'zz131b-proof-0003-a.jpg', 1000, '2026-11-04');
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2026-11-04' from _t where k = 'a3')
          and (select status = 'paid' and reading_date = date '2026-11-04' from public.utility_bills where id = pg_temp.bid('electric', 'c1', '2026-10'))
          and (select reading_date = date '2026-11-05' from public.utility_bills where id = pg_temp.bid('electric', 'c1', '2026-11')),
          'an earlier date (4 Nov) still settles: paid, reading date stored, the later bill keeps 5 Nov');

-- 2. the normal flow: N-1 paid, then N -------------------------------------------------------------------------------------------------------------------------------------------------------
-- c2 water: 2026-10, 2026-11 and 2026-12 due. 2026-10 is paid with 25 Oct (no later paid bill: 2026-12 is only due), then 2026-11 with 21 Nov (after 25 Oct, 2026-12 still unpaid, so no upper bound): both settle.
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values
  (pg_temp.id('c2'), 'water', '2026-10', 300, 'due'), (pg_temp.id('c2'), 'water', '2026-11', 300, 'due'), (pg_temp.id('c2'), 'water', '2026-12', 300, 'due');
select pg_temp.settle('b1', 'water', 'c2', '2026-10', 'zz131b-proof-0004-a.jpg', 300, '2026-10-25');
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2026-10-25' from _t where k = 'b1')
          and (select status = 'paid' and reading_date = date '2026-10-25' from public.utility_bills where id = pg_temp.bid('water', 'c2', '2026-10')),
          'normal flow: the older bill (2026-10) is paid with 25 Oct while a later bill is only due');
select pg_temp.settle('b2', 'water', 'c2', '2026-11', 'zz131b-proof-0005-a.jpg', 300, '2026-11-21');
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2026-11-21' from _t where k = 'b2')
          and (select status = 'paid' and reading_date = date '2026-11-21' from public.utility_bills where id = pg_temp.bid('water', 'c2', '2026-11'))
          and (select status = 'due' and reading_date is null from public.utility_bills where id = pg_temp.bid('water', 'c2', '2026-12')),
          'normal flow: 2026-11 is then paid with 21 Nov (after the previous paid reading); the unpaid 2026-12 bill is untouched');

-- 3. only the same meter of the same property counts --------------------------------------------------------------------------------------------------------------------------------------------
-- c3: electric 2026-11 is PAID with 5 Nov; the water bill 2026-10 is due and is settled with 10 Nov (after the electric reading date): the other kind does not bound it.
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, reading_date)
values (pg_temp.id('c3'), 'electric', '2026-11', 1000, 'paid', 1000, now(), 'Zz Admin', 'typed', date '2026-11-05');
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('c3'), 'water', '2026-10', 300, 'due');
select pg_temp.settle('c1', 'water', 'c3', '2026-10', 'zz131b-proof-0006-a.jpg', 300, '2026-11-10');
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2026-11-10' from _t where k = 'c1')
          and (select status = 'paid' and reading_date = date '2026-11-10' from public.utility_bills where id = pg_temp.bid('water', 'c3', '2026-10')),
          'a later paid bill of the OTHER kind (electric 5 Nov) does not bound the water bill: 10 Nov settles');
-- c4: electric 2026-09 is due; the later paid electric bill (2026-11, 5 Nov) belongs to ANOTHER property (c1): it does not bound c4. 10 Nov is after open_from and inside the window (1 Aug).
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('c4'), 'electric', '2026-09', 1000, 'due');
select pg_temp.settle('d1', 'electric', 'c4', '2026-09', 'zz131b-proof-0007-a.jpg', 1000, '2026-11-10');
select ok((select (v ->> 'ok')::boolean and v ->> 'reading_date' = '2026-11-10' from _t where k = 'd1')
          and (select status = 'paid' and reading_date = date '2026-11-10' from public.utility_bills where id = pg_temp.bid('electric', 'c4', '2026-09')),
          'a later paid bill of ANOTHER property (c1, 5 Nov) does not bound this property: 10 Nov settles');

-- 4. the s131 refusals are unchanged ----------------------------------------------------------------------------------------------------------------------------------------------------------
-- c5 electric 2026-11 is due, no later paid bill. No reading_date = reading_date_required; 20 Oct is not after open_from (21 Oct) = reading_date_invalid with the s131 key after = 2026-10-21 (and no before key).
insert into public.utility_bills(property_id, kind, period, estimate_php, status) values (pg_temp.id('c5'), 'electric', '2026-11', 1000, 'due');
select pg_temp.settle('e1', 'electric', 'c5', '2026-11', 'zz131b-proof-0008-a.jpg', 1000, null);
select pg_temp.settle('e2', 'electric', 'c5', '2026-11', 'zz131b-proof-0009-a.jpg', 1000, '2026-10-20');
select ok((select v = '{"ok":false,"reason":"reading_date_required"}'::jsonb from _t where k = 'e1')
          and (select v = '{"ok":false,"reason":"reading_date_invalid","after":"2026-10-21"}'::jsonb from _t where k = 'e2')
          and (select status = 'due' and reading_date is null from public.utility_bills where id = pg_temp.bid('electric', 'c5', '2026-11')),
          'the s131 refusals are unchanged: reading_date_required, and reading_date_invalid with after = 2026-10-21 for 20 Oct');

-- 5. grants and body ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute')
          and not has_function_privilege('anon', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') and not has_function_privilege('service_role', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute')
          and has_function_privilege('authenticated', 'public.today_bills_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.today_bills_v1(uuid)', 'execute'),
          'grants are present: bill_pay_settle_v1 authenticated only (not anon, not service_role); today_bills_v1 unchanged');
select ok((select p.prosecdef and p.provolatile = 'v' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.bill_pay_settle_v1(uuid,jsonb)'::regprocedure),
          'bill_pay_settle_v1 is still security definer, volatile, with the empty search_path');
select ok((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.bill_pay_settle_v1(uuid,jsonb)'::regprocedure) = '9784e8619b3aeb3d6b19c5fd7f679c79'
          and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)'::regprocedure) = '64e749cf8ed30afc9c4475bcd398685a'
          and (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.today_bills_v1(uuid)'::regprocedure) = '7fca3fd12b7e372010f8f20b12c491a4',
          'bill_pay_settle_v1 is the s131b body; the other s131 bodies (bill_entry_v1, today_bills_v1) are untouched');

-- 6. the md5 guard of the migration (last: it breaks the function on purpose) --------------------------------------------------------------------------------------------------------------------
-- The guard block below is a verbatim copy of the one in 20261201000000_s131b_followups.sql (the rehearsal's database role cannot read the mounted file, so it cannot be cut out of it; keep the two identical).
create function pg_temp.run_do(p text) returns jsonb language plpgsql as $f$
begin
  execute p;
  return 'null'::jsonb;
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.guard_sql() returns text language sql as $gq$
select $dq$do $g$
declare v text; r record;
begin
  for r in select * from (values
    ('public.bill_pay_settle_v1(uuid,jsonb)', 'ede3c0432079186f73b7db56900e6671', '9784e8619b3aeb3d6b19c5fd7f679c79')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 's131b: ' || r.sig || ' is neither the s131 body nor this release (md5 ' || coalesce(v, 'null') || '): re-cut it from the live body';
    end if;
  end loop;
end $g$;$dq$::text
$gq$;
select ok(pg_temp.guard_sql() like 'do $g$%' and (select count(*) = 1 from regexp_matches(pg_temp.guard_sql(), '\(''public\.', 'g')), 'the guard block lists the one replaced function');
select ok(pg_temp.run_do(pg_temp.guard_sql()) = 'null'::jsonb, 'the guard passes on the s131b body');
create or replace function public.bill_pay_settle_v1(p_bill_id uuid, p_proof jsonb) returns jsonb language sql set search_path = '' as $$ select '{"unknown":true}'::jsonb $$;
select ok(pg_temp.run_do(pg_temp.guard_sql()) ->> 'err' = '55000' and pg_temp.run_do(pg_temp.guard_sql()) ->> 'msg' like 's131b: public.bill_pay_settle_v1(uuid,jsonb)%neither the s131 body nor this release%',
          'the guard refuses with 55000 when bill_pay_settle_v1 is an unknown body');

select * from finish();
rollback;
