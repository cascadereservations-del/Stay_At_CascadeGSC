-- Session 99e (lane SQL): release s99e_missed_and_pay_20261102. get_missed_cleanings: a report that names another checkout (filed late) no longer hides this one;
-- only a report with NO checkout_date falls back to the Manila-date window (same or next day). Synthetic property, so restored production rows never interfere.
-- Offsets are from public.manila_today() (T). Checkouts and the report that decides each:
--   T-12  E4  report S4 has no checkout_date and was filed T-10 06:00 Manila (= UTC date T-11): the old UTC window said covered, the Manila date says two days late -> MISSED
--   T-9   E0  report S1 names checkout T-9 (filed late, T-6 22:36 Manila)                                                                 -> covered by the date match
--   T-6   E1  no report of its own. S1 was filed on T-6 Manila night for T-9: the old window hid E1                                       -> MISSED (the live bug, 21 Oct)
--   T-4   E2  report S2 has no checkout_date, filed T-4 10:00 Manila (same day)                                                            -> covered by the window
--   T-3   E3  report S3 has no checkout_date, filed T-2 23:00 Manila (next day)                                                            -> covered by the window
begin;
select plan(17);

create function pg_temp.at(n int, hm text) returns timestamptz language sql stable as
$$ select ((public.manila_today() + n) + hm::time) at time zone 'Asia/Manila' $$;

insert into public.properties(id, name, is_active) values ('e99e0000-0000-4000-8000-000000000001', 'Synthetic s99e missed cleanings', true);
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('e99e0000-0000-4000-8000-000000000001', 'zz-s99e-e4', 'airbnb', 'confirmed', 'Zzfour Uy',   public.manila_today() - 15, public.manila_today() - 12),
  ('e99e0000-0000-4000-8000-000000000001', 'zz-s99e-e0', 'airbnb', 'confirmed', 'Zzzero Tan',  public.manila_today() - 15, public.manila_today() - 9),
  ('e99e0000-0000-4000-8000-000000000001', 'zz-s99e-e1', 'airbnb', 'confirmed', 'Zzone Reyes', public.manila_today() - 10, public.manila_today() - 6),
  ('e99e0000-0000-4000-8000-000000000001', 'zz-s99e-e2', 'airbnb', 'confirmed', 'Zztwo Cruz',  public.manila_today() - 8,  public.manila_today() - 4),
  ('e99e0000-0000-4000-8000-000000000001', 'zz-s99e-e3', 'airbnb', 'confirmed', 'Zzthree Lim', public.manila_today() - 7,  public.manila_today() - 3);
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, cleaned_at) values
  ('e99e0000-0000-4000-8000-0000000000b1', 'zz-s99e-s1', 'e99e0000-0000-4000-8000-000000000001', 'Zzhoney', public.manila_today() - 9, 'turnover', pg_temp.at(-6, '22:36')),
  ('e99e0000-0000-4000-8000-0000000000b2', 'zz-s99e-s2', 'e99e0000-0000-4000-8000-000000000001', 'Zzhoney', null,                      'turnover', pg_temp.at(-4, '10:00')),
  ('e99e0000-0000-4000-8000-0000000000b3', 'zz-s99e-s3', 'e99e0000-0000-4000-8000-000000000001', 'Zzhoney', null,                      'turnover', pg_temp.at(-2, '23:00')),
  ('e99e0000-0000-4000-8000-0000000000b4', 'zz-s99e-s4', 'e99e0000-0000-4000-8000-000000000001', 'Zzhoney', null,                      'turnover', pg_temp.at(-10, '06:00'));

-- 1-4 the bug and the two rules that stay
select is((select array_agg(checkout_date order by checkout_date desc) from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14)),
  array[public.manila_today() - 6, public.manila_today() - 12], 'exactly two checkouts are missed: T-6 and T-12, newest first');
select ok(exists (select 1 from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14) where checkout_date = public.manila_today() - 6),
  'a late report filed on another checkout day (S1, named for T-9, filed on T-6) no longer hides the T-6 checkout');
select ok(not exists (select 1 from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14) where checkout_date = public.manila_today() - 9),
  'the checkout S1 names (T-9) is still covered by its checkout_date');
select ok(not exists (select 1 from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14) where checkout_date in (public.manila_today() - 4, public.manila_today() - 3)),
  'a report with no checkout_date filed the same (T-4) or the next (T-3 filed on T-2) Manila day still covers its checkout');

-- 5-6 the Manila date, not the UTC date; days_overdue unchanged
select ok(exists (select 1 from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14) where checkout_date = public.manila_today() - 12),
  'a no-date report filed at 06:00 Manila two days late (UTC date one day late) does not cover: the window uses the Manila date');
select is((select days_overdue from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14) where checkout_date = public.manila_today() - 6), 6,
  'days_overdue is unchanged (T minus checkout)');

-- 7 mid_stay never covers
update public.cleaning_sessions set cleaning_type = 'mid_stay' where id = 'e99e0000-0000-4000-8000-0000000000b2';
select ok(exists (select 1 from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14) where checkout_date = public.manila_today() - 4),
  'a mid_stay report covers nothing (unchanged)');
update public.cleaning_sessions set cleaning_type = 'turnover' where id = 'e99e0000-0000-4000-8000-0000000000b2';

-- 8 a report naming the missed checkout closes it
update public.cleaning_sessions set checkout_date = public.manila_today() - 6 where id = 'e99e0000-0000-4000-8000-0000000000b4';
select ok(not exists (select 1 from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000001', 14) where checkout_date = public.manila_today() - 6),
  'a report that names the T-6 checkout covers it');

-- 9-17 signature, security, volatility, language, grants, body
select is(pg_get_function_arguments('public.get_missed_cleanings(uuid,integer)'::regprocedure), 'p_property_id uuid DEFAULT NULL::uuid, p_lookback integer DEFAULT 14',
  'the signature and defaults are unchanged');
select is(pg_get_function_result('public.get_missed_cleanings(uuid,integer)'::regprocedure), 'TABLE(guest_name text, checkin_date date, checkout_date date, source text, days_overdue integer)',
  'the result columns are unchanged');
select ok(not (select prosecdef from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure), 'still SECURITY INVOKER');
select ok((select provolatile = 's' and proconfig = array['search_path=""'] and prolang = (select oid from pg_language where lanname = 'plpgsql') from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure),
  'still stable, plpgsql, search_path pinned to empty');
select ok(has_function_privilege('service_role', 'public.get_missed_cleanings(uuid,integer)', 'execute')
      and has_function_privilege('authenticated', 'public.get_missed_cleanings(uuid,integer)', 'execute'), 'service_role and authenticated can execute');
select ok(not has_function_privilege('anon', 'public.get_missed_cleanings(uuid,integer)', 'execute')
      and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure and a.grantee = 0), 'anon and PUBLIC cannot execute');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure), 'def6d3ea1ae7c3c05bc2ae178df2d0aa',
  'the live body is the s99e body');
select ok((select position('stay_same_guest_v1' in prosrc) > 0 and position('v_today   := public.manila_today();' in prosrc) > 0 and position('cs.cleaned_at::date' in prosrc) = 0
             from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure), 'the D-290 same-guest clause and the Manila today stay; the UTC date is gone');
select ok(not exists (select 1 from public.get_missed_cleanings('e99e0000-0000-4000-8000-000000000002', 14)), 'another property sees none of these rows');

select * from finish();
rollback;
