-- Session 117 (lane S): release s117_self_closing_warnings_20261116. docs/s117/CONTRACT.md (addressed or expired, QUIET_HOURS = 6).
--   run_system_verifier_v1 V22 only while the provider still has a non-probe call in the last 6 hours; api_usage_last_calls_v1; system_tasks_expire_v1 (power_poster_unread, low_stock)
--   called from apply_verifier_run_v1; the Heater (Heatek) -> Kettle / Water Heater rename.
-- Synthetic fixtures only (uuids a1170000-...). llm_usage is emptied inside this transaction (a restore holds real rows); everything rolls back.
begin;
select plan(36);

grant usage on schema public, auth to anon, authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
create temp table _sink(v text);
grant all on _sink to public;
grant all on _t to public;
-- the finding for a key prefix, from a verifier run held in _t
create function pg_temp.f(p_run text, p_like text) returns jsonb language sql as $$
  select coalesce((select jsonb_agg(x) from _t, jsonb_array_elements(_t.v -> 'found') x where _t.k = p_run and x ->> 'key' like p_like), '[]'::jsonb);
$$;

insert into public.properties(id, name, is_active) values ('a1170000-0000-4000-8000-0000000000b0', 'Synthetic S117', true);

-- ===== V22: addressed when nothing calls the provider any more =====
delete from public.llm_usage;
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values
  (now() - interval '20 hours', 'Cascade Meter', 'gemini', 'g', false, 'gemini_402', false),
  (now() - interval '10 hours', 'Cascade Power Watch', 'gemini', 'g', false, 'gemini_402', false);
insert into _t select 'v1', public.run_system_verifier_v1('a1170000-0000-4000-8000-0000000000b0', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('v1', 'V22:%')), 0, 'V22 is not raised when the last call to the provider was more than 6 hours ago');

insert into public.llm_usage(at, title, provider, model, ok, error, probe) values (now() - interval '1 hour', 'Cascade Meter', 'gemini', 'g', false, 'gemini_402', false);
insert into _t select 'v2', public.run_system_verifier_v1('a1170000-0000-4000-8000-0000000000b0', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('v2', 'V22:%')), 1, 'V22 is raised when calls continue and fail (a call 1 hour ago)');
select is(pg_temp.f('v2', 'V22:%') -> 0 ->> 'key', 'V22:credit_gone:gemini', 'keyed by provider as before');
select is(pg_temp.f('v2', 'V22:%') -> 0 ->> 'severity', 'red', 'still red');
select ok((pg_temp.f('v2', 'V22:%') -> 0 -> 'detail' ->> 'since')::timestamptz = now() - interval '20 hours', 'since is still the first refusal after the last good call');
select ok((pg_temp.f('v2', 'V22:%') -> 0 -> 'detail' -> 'features') @> '["Power Watch", "meter readings"]'::jsonb and '["Power Watch", "meter readings"]'::jsonb @> (pg_temp.f('v2', 'V22:%') -> 0 -> 'detail' -> 'features'), 'features unchanged: the human strings of the refused titles');

insert into public.llm_usage(at, title, provider, model, ok, error, probe) values (now() - interval '30 minutes', 'Cascade Meter', 'gemini', 'g', true, null, false);
insert into _t select 'v3', public.run_system_verifier_v1('a1170000-0000-4000-8000-0000000000b0', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('v3', 'V22:%')), 0, 'one good call since the first refusal clears V22 (unchanged)');

-- a probe inside the 6 hours is not a call; another provider answering is not this provider being called
delete from public.llm_usage;
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values
  (now() - interval '10 hours', 'Cascade Meter', 'gemini', 'g', false, 'gemini_402', false),
  (now() - interval '1 hour',   'Cascade Meter', 'gemini', 'g', false, 'gemini_402', true),
  (now() - interval '1 hour',   'Cascade Meter', 'openrouter', 'o', true, null, false);
insert into _t select 'v4', public.run_system_verifier_v1('a1170000-0000-4000-8000-0000000000b0', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('v4', 'V22:%')), 0, 'a probe, or a call to another provider, inside 6 hours does not keep V22 alive');

-- exactly at the edge: a call 5 h 59 min ago still counts, 6 h 1 min ago does not
delete from public.llm_usage;
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values (now() - interval '5 hours 59 minutes', 'Cascade Meter', 'gemini', 'g', false, 'gemini_402', false);
insert into _t select 'v5', public.run_system_verifier_v1('a1170000-0000-4000-8000-0000000000b0', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('v5', 'V22:%')), 1, 'a refused call 5 h 59 min ago still raises V22');
delete from public.llm_usage;
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values (now() - interval '6 hours 1 minute', 'Cascade Meter', 'gemini', 'g', false, 'gemini_402', false);
insert into _t select 'v6', public.run_system_verifier_v1('a1170000-0000-4000-8000-0000000000b0', 'hourly', now());
select is(jsonb_array_length(pg_temp.f('v6', 'V22:%')), 0, 'a refused call 6 h 1 min ago does not');

-- ===== api_usage_last_calls_v1 =====
delete from public.llm_usage;
insert into public.llm_usage(at, title, provider, model, ok, error, probe) values
  (now() - interval '3 hours',  'Cascade Meter',       'openrouter', 'o', true,  null,         false),
  (now() - interval '1 hour',   'Cascade Meter',       'openrouter', 'o', false, 'openrouter_500', false),
  (now() - interval '10 minutes', 'Cascade Meter',     'openrouter', 'o', false, 'openrouter_402', true),   -- a probe: left out
  (now() - interval '60 hours', 'Cascade Meter',       'openrouter', 'o', true,  null,         false),      -- outside 48 h: left out
  (now() - interval '5 hours',  'Cascade Power Watch', 'gemini',     'g', false, 'gemini_402', false),
  (now() - interval '50 hours', 'Cascade Old Thing',   'gemini',     'g', true,  null,         false);      -- outside 48 h: no row
select is((select count(*)::int from public.api_usage_last_calls_v1()), 2, 'one row per (provider, title) with a non-probe call in the last 48 h');
select is((select last_call_at from public.api_usage_last_calls_v1() where title = 'Cascade Meter' and provider = 'openrouter'), now() - interval '1 hour', 'Meter: last_call_at ignores the probe and the 60 h row');
select is((select last_ok_at from public.api_usage_last_calls_v1() where title = 'Cascade Meter'), now() - interval '3 hours', 'Meter: last_ok_at is the good call');
select is((select last_fail_at from public.api_usage_last_calls_v1() where title = 'Cascade Meter'), now() - interval '1 hour', 'Meter: last_fail_at is the failed call');
select is((select last_ok_at from public.api_usage_last_calls_v1() where title = 'Cascade Power Watch'), null, 'Power Watch: never answered, last_ok_at is null (unknown stays null)');
select is((select last_fail_at from public.api_usage_last_calls_v1() where title = 'Cascade Power Watch'), now() - interval '5 hours', 'Power Watch: last_fail_at');
select is((select pg_get_function_result(p.oid) from pg_proc p where p.oid = 'public.api_usage_last_calls_v1()'::regprocedure),
  'TABLE(provider text, title text, last_call_at timestamp with time zone, last_ok_at timestamp with time zone, last_fail_at timestamp with time zone)', 'shape: provider, title, last_call_at, last_ok_at, last_fail_at');
select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.api_usage_last_calls_v1()'::regprocedure), 'security definer with an empty search_path');
select ok(has_function_privilege('service_role', 'public.api_usage_last_calls_v1()', 'execute')
      and not has_function_privilege('anon', 'public.api_usage_last_calls_v1()', 'execute')
      and not has_function_privilege('authenticated', 'public.api_usage_last_calls_v1()', 'execute')
      and exists (select 1 from pg_proc p where p.oid = 'public.api_usage_last_calls_v1()'::regprocedure and p.proacl is not null)
      and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.api_usage_last_calls_v1()'::regprocedure and a.grantee = 0),
  'grants: service_role only (nothing for public, anon or authenticated)');
set local role anon;
select throws_ok($$select * from public.api_usage_last_calls_v1()$$, '42501', null, 'anon cannot call it');
reset role;
set local role authenticated;
select throws_ok($$select * from public.api_usage_last_calls_v1()$$, '42501', null, 'authenticated cannot call it');
reset role;

-- ===== system_tasks_expire_v1: power_poster_unread =====
insert into public.app_settings(key, value) values ('power_watch_state', jsonb_build_object('done', '[]'::jsonb, 'images', jsonb_build_array('https://fb.test/posters/zz117%20poster%20decided.jpg', 'https://fb.test/posters/other.jpg')))
on conflict (key) do update set value = excluded.value;
insert into _sink select public.system_task_open_v1('a1170000-0000-4000-8000-0000000000b0', 'power_poster_unread', 'zz117 poster decided.jpg', 'Poster cannot be read (decided)', 'x', 'normal');
insert into _sink select public.system_task_open_v1('a1170000-0000-4000-8000-0000000000b0', 'power_poster_unread', 'zz117-poster-young.jpg',  'Poster cannot be read (young)',   'x', 'normal');
insert into _sink select public.system_task_open_v1('a1170000-0000-4000-8000-0000000000b0', 'power_poster_unread', 'zz117-poster-old.jpg',    'Poster cannot be read (old)',     'x', 'normal');
insert into _sink select public.system_task_open_v1('a1170000-0000-4000-8000-0000000000b0', 'guest_details',       'zz117-other-old',          'Some other old system task',      'x', 'normal');
update public.follow_up_tasks set created_at = now() - interval '3 days' where source_ref in ('zz117-poster-old.jpg', 'zz117-other-old');
update public.follow_up_tasks set created_at = now() - interval '47 hours' where source_ref = 'zz117-poster-young.jpg';
insert into _sink select public.system_tasks_expire_v1(now());
select is((select status from public.follow_up_tasks where source_ref = 'zz117 poster decided.jpg'), 'done', 'a poster Power watch has read since closes its task');
select is((select completion_note from public.follow_up_tasks where source_ref = 'zz117 poster decided.jpg'), 'Closed automatically: Power watch has read this poster since.', 'with a plain-sentence note');
select is((select status from public.follow_up_tasks where source_ref = 'zz117-poster-young.jpg'), 'open', 'an undecided poster 47 hours old stays open');
select is((select status from public.follow_up_tasks where source_ref = 'zz117-poster-old.jpg'), 'done', 'an undecided poster older than 48 hours closes');
select is((select completion_note from public.follow_up_tasks where source_ref = 'zz117-poster-old.jpg'), 'Closed automatically: this notice is older than 48 hours.', 'with the age note');
select is((select status from public.follow_up_tasks where source_ref = 'zz117-other-old'), 'open', 'a system task of another kind is never touched');

-- wired into the verifier run: apply_verifier_run_v1 (hourly) closes an old poster task
insert into _sink select public.system_task_open_v1('a1170000-0000-4000-8000-0000000000b0', 'power_poster_unread', 'zz117-poster-old2.jpg', 'Poster cannot be read (old 2)', 'x', 'normal');
update public.follow_up_tasks set created_at = now() - interval '3 days' where source_ref = 'zz117-poster-old2.jpg';
insert into _sink select public.apply_verifier_run_v1('hourly', '[]'::jsonb, now());
select is((select status from public.follow_up_tasks where source_ref = 'zz117-poster-old2.jpg'), 'done', 'apply_verifier_run_v1 runs the expiry, so it happens every hour');

-- ===== system_tasks_expire_v1: low_stock =====
-- the s84 trigger would close and reopen these itself; it is switched off so only the sweep is under test
alter table public.inventory_items disable trigger s_inventory_low_task;
insert into public.inventory_items(id, property_id, name, category, qty_on_hand, reorder_below, is_active)
values ('a1170000-0000-4000-8000-0000000000c1', 'a1170000-0000-4000-8000-0000000000b0', 'Zz S117 Soap', 'Supplies', 1, 3, true);
insert into _sink select public.system_task_open_v1('a1170000-0000-4000-8000-0000000000b0', 'low_stock', '2026-W46:a1170000-0000-4000-8000-0000000000b0', 'Restock: 1 item is low', 'x', 'normal');
insert into _sink select public.system_tasks_expire_v1(now());
select is((select status from public.follow_up_tasks where source_kind = 'low_stock' and property_id = 'a1170000-0000-4000-8000-0000000000b0'), 'open', 'a low item keeps the low-stock task open');
update public.inventory_items set qty_on_hand = 3 where id = 'a1170000-0000-4000-8000-0000000000c1';
insert into _sink select public.system_tasks_expire_v1(now());
select is((select status from public.follow_up_tasks where source_kind = 'low_stock' and property_id = 'a1170000-0000-4000-8000-0000000000b0'), 'open', 'an item exactly at its reorder level is still low (the s84 trigger rule), so the task stays open');
update public.inventory_items set qty_on_hand = 4 where id = 'a1170000-0000-4000-8000-0000000000c1';
insert into _sink select public.system_tasks_expire_v1(now());
select is((select status from public.follow_up_tasks where source_kind = 'low_stock' and property_id = 'a1170000-0000-4000-8000-0000000000b0'), 'done', 'restocked above the reorder level: the task closes');
select is((select completion_note from public.follow_up_tasks where source_kind = 'low_stock' and property_id = 'a1170000-0000-4000-8000-0000000000b0'), 'Closed automatically: nothing is low now.', 'with the note');
select ok(has_function_privilege('service_role', 'public.system_tasks_expire_v1(timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.system_tasks_expire_v1(timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.system_tasks_expire_v1(timestamptz)', 'execute'), 'system_tasks_expire_v1 is service_role only');
select ok(has_function_privilege('service_role', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and has_function_privilege('service_role', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute'), 'the two replaced verifier functions keep service_role only');

-- ===== the rename (the migration ran before this file) =====
select ok(not exists (select 1 from public.inventory_items where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and name = 'Heater (Heatek)'),
  'no stock item is called Heater (Heatek) any more');
select ok(not exists (select 1 from public.properties where id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
       or (select count(*) from public.inventory_items where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and is_active and name = 'Kettle / Water Heater') = 1,
  'exactly one active Kettle / Water Heater (a rebuild without the Cascade property skips the data step)');

select * from finish();
rollback;
