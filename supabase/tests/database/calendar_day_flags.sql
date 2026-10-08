-- Session 77 lane L2: calendar_day_flags, calendar_day_flag_set_v1 / _clear_v1 and the staff_home_v1 calendar contract
-- (block_reason, block_label, day_flags). Synthetic property e7700000-...-b0; everything rolls back. Fixtures insert as the owner
-- (service_role has no BYPASSRLS); roles are impersonated with request.jwt.claims as staff_home_v1.sql does.
begin;
select plan(48);

select ok((select count(*) = 2 and bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('calendar_day_flag_set_v1', 'calendar_day_flag_clear_v1')),
  'both flag RPCs are security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.calendar_day_flag_set_v1(uuid,date,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.calendar_day_flag_clear_v1(uuid,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.calendar_day_flag_set_v1(uuid,date,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.calendar_day_flag_clear_v1(uuid,uuid)', 'execute'),
  'anon has no execute on the flag RPCs; authenticated has');
select ok((select relrowsecurity from pg_class where oid = 'public.calendar_day_flags'::regclass), 'calendar_day_flags has RLS on');
select ok(not has_table_privilege('anon', 'public.calendar_day_flags', 'select')
      and not has_table_privilege('authenticated', 'public.calendar_day_flags', 'select')
      and not has_table_privilege('authenticated', 'public.calendar_day_flags', 'insert')
      and not has_table_privilege('authenticated', 'public.calendar_day_flags', 'update'),
  'no API role has a direct grant on calendar_day_flags');
select ok(exists (select 1 from pg_trigger where tgrelid = 'public.calendar_day_flags'::regclass and tgname = 'admin_audit_row' and not tgisinternal),
  'calendar_day_flags is audited by admin_audit_row_v1');

-- fixtures ---------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e7700000-0000-4000-8000-0000000000b0', 'Synthetic Calendar Flags', true);
insert into auth.users(id) values ('e7700000-0000-4000-8000-000000000001'), ('e7700000-0000-4000-8000-000000000002'),
  ('e7700000-0000-4000-8000-000000000003'), ('e7700000-0000-4000-8000-000000000004');
insert into public.staff_access_profiles(user_id, role) values
  ('e7700000-0000-4000-8000-000000000001', 'cleaner'), ('e7700000-0000-4000-8000-000000000002', 'admin'),
  ('e7700000-0000-4000-8000-000000000003', 'owner'), ('e7700000-0000-4000-8000-000000000004', 'maintenance');
insert into public.staff_property_access(user_id, property_id) values
  ('e7700000-0000-4000-8000-000000000001', 'e7700000-0000-4000-8000-0000000000b0'),
  ('e7700000-0000-4000-8000-000000000002', 'e7700000-0000-4000-8000-0000000000b0'),
  ('e7700000-0000-4000-8000-000000000004', 'e7700000-0000-4000-8000-0000000000b0');
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, block_reason, block_note) values
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-conf',  'airbnb', 'confirmed', 'Zz Cf Guest', current_date + 1,  current_date + 3,  null, null),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-dir',   'airbnb', 'blocked',   null,          current_date + 4,  current_date + 6,  'direct', 'DIR bd296460 confirmed, guest 0917 123 4567 paid P500'),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-dir2',  'airbnb', 'blocked',   null,          current_date + 7,  current_date + 8,  'direct', 'direct booking, ref unknown'),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-brown', 'airbnb', 'blocked',   null,          current_date + 10, current_date + 12, 'brownout', 'SOCOTECO II feeder 14-3 Oct 15 06:00 for 11h'),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-maint', 'airbnb', 'blocked',   null,          current_date + 14, current_date + 15, 'maintenance', 'aircon service by Mang Tony 0918 555 1234'),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-owner', 'airbnb', 'blocked',   null,          current_date + 17, current_date + 18, 'owner_use', 'family'),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-none',  'airbnb', 'blocked',   null,          current_date + 20, current_date + 21, null, null),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-far',   'airbnb', 'blocked',   null,          current_date + 150, current_date + 151, 'brownout', null),
  ('e7700000-0000-4000-8000-0000000000b0', 'zz-cf-old',   'airbnb', 'blocked',   null,          current_date - 80, current_date - 79, 'maintenance', null);
insert into public.verifier_findings(key, check_id, severity, title, status, detail) values
  ('zz-cf-v6', 'V6', 'yellow', 'zz-cf ops finding', 'open',
   '{"booking":"bd296460-0fd2-434f-aa3a-7e89dc90c14e","guest":"Zz Cf Guest","arrives":"2026-10-08","phone":"0917 123 4567","amount":650,"email":"a@b.com"}'),
  ('zz-cf-v6ack', 'V6', 'yellow', 'zz-cf acked finding', 'acknowledged', '{"booking":"bd296460-0fd2-434f-aa3a-7e89dc90c14e"}'),
  ('zz-cf-v1', 'V1', 'red', 'zz-cf finance finding', 'open', '{}');
-- A notice on the same night as the brownout block (de-duplicated: the notice label wins), one on its own night, one inactive.
insert into public.ops_notices(property_id, notice_type, title, effective_date, is_active, audience, source) values
  ('e7700000-0000-4000-8000-0000000000b0', 'brownout', 'zz-cf notice same night', current_date + 10, true, 'all', 'socoteco'),
  ('e7700000-0000-4000-8000-0000000000b0', 'brownout', 'zz-cf notice own night',  current_date + 25, true, 'staff', 'ngcp'),
  ('e7700000-0000-4000-8000-0000000000b0', 'brownout', 'zz-cf notice inactive',   current_date + 30, false, 'staff', 'staff');

-- staff_verifier_facts_v1 (internal helper, called as the owner): the allow-list only
select is(public.staff_verifier_facts_v1('V10', '{"check":"ledger_duplicates","n":2,"d":[{"n":3,"payee":"Honey","amount":650}],"label":"x","note":"y"}'::jsonb),
  '{"check":"ledger_duplicates","n":2}'::jsonb, 'V10 facts: the check name and n only, never the rows (payee, amount)');
select is(public.staff_verifier_facts_v1('V1m', '{"guest":"Ana Maria Cruz","booking":"92f94d0e-008c-4439-9c94-6d48684629da","from":"2026-10-08","to":"2026-10-11","block_from":"2026-10-08","block_to":"2026-10-12","payee":"Honey"}'::jsonb),
  '{"ref":"92F94D0E","guest_first":"Ana","from":"2026-10-08","to":"2026-10-11","block_from":"2026-10-08","block_to":"2026-10-12"}'::jsonb,
  'V1m facts: ref, first name, stay dates and block dates');

-- the cleaner: sees labels and the auto flags, cannot write -------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub','e7700000-0000-4000-8000-000000000001','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);

select is((select x->>'block_label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-dir'),
  'Direct booking BD296460', 'direct: the label carries the upper-cased 8-character ref from block_note');
select is((select x->>'block_label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-dir2'),
  'Direct booking', 'direct without a ref: the label has no ref');
select is((select x->>'block_label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-brown'),
  'Brownout', 'brownout label');
select is((select x->>'block_label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-maint'),
  'Maintenance', 'maintenance label');
select is((select x->>'block_label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-owner'),
  'Owner use', 'owner label');
select is((select x->>'block_label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-none'),
  'Blocked', 'a block with no reason is labelled Blocked');
select is((select x->>'block_reason' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-owner'),
  'owner', 'the stored owner_use is sent as owner');
select ok((select x->'block_reason' = 'null'::jsonb and x->'block_label' = 'null'::jsonb
             from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar') x where x->>'uid' = 'zz-cf-conf'),
  'a confirmed stay has null block_reason and block_label');
select ok(not (public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')::text ~* '(0917|0918|Mang Tony|aircon|feeder 14-3|family)'),
  'no raw block_note text beyond the ref reaches the payload');

select is((select w->>'key' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'kind' = 'verifier' and w->>'title' = 'zz-cf ops finding'), 'zz-cf-v6',
  'a system-check warning carries the verifier_findings key as w.key (the key ack_verifier_finding_v1 and the Tasks list use); the finance finding stays hidden from a cleaner');
select ok((select bool_and((w ? 'key') and (w->>'kind' = 'verifier' or w->'key' = 'null'::jsonb)) from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'warnings') w) and (select w->'detail'->>'check_id' = 'V6' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'kind' = 'verifier' and w->>'title' = 'zz-cf ops finding'),
  'every warning has a key (null unless it is a verifier warning) and detail is unchanged);
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'key' = 'zz-cf-v6ack'), 0,
  'an acknowledged finding is not in warnings');
select ok((select w->'facts' = '{"ref":"BD296460","from":"2026-10-08","guest_first":"Zz"}'::jsonb and w->'acknowledged' = 'false'::jsonb
             from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'key' = 'zz-cf-v6'),
  'an open system-check warning carries acknowledged false and facts: ref, first name and date, with no phone, e-mail or amount');
select ok((select bool_and(w->'facts' = 'null'::jsonb and w->'acknowledged' = 'false'::jsonb)
             from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'kind' <> 'verifier'),
  'warnings that are not system checks have facts null');

-- day_flags shape and content (no manual flag yet) ---------------------------------------------------------------------
select is(jsonb_typeof(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags'), 'array', 'day_flags is an array');
select ok((select bool_and(x ? 'date' and x ? 'kind' and x ? 'label' and x ? 'source' and x ? 'id'
                           and x->>'kind' in ('brownout','maintenance','deep_clean','other') and x->>'source' in ('auto','manual')
                           and x->>'date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
             from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x),
  'every day flag has date, kind, label, source and id in the contract shape');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'kind' = 'brownout'), 3,
  'brownout: two nights of the block (one shared with a notice) plus the other notice night; the far block and the inactive notice are out');
select is((select x->>'label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'kind' = 'brownout' and x->>'date' = (current_date + 10)::text), 'Brownout (SOCOTECO)',
  'a notice and a block on the same night give one flag, and the notice label wins');
select is((select x->>'label' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'kind' = 'brownout' and x->>'date' = (current_date + 11)::text), 'Brownout', 'the second night of the block is an auto flag');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'kind' = 'maintenance'), 1, 'maintenance: one night from the block; the block 80 days ago is outside the window');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'source' = 'manual'), 0, 'no manual flag before one is set');

-- the cleaner cannot write ---------------------------------------------------------------------------------------------
select throws_ok($$select public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 2, 'other', 'x')$$, '42501', null,
  'a cleaner cannot set a flag');
select throws_ok($$select public.calendar_day_flag_clear_v1('e7700000-0000-4000-8000-0000000000b0', gen_random_uuid())$$, '42501', null,
  'a cleaner cannot clear a flag');

-- maintenance staff cannot write either --------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub','e7700000-0000-4000-8000-000000000004','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select throws_ok($$select public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 2, 'other', 'x')$$, '42501', null,
  'a maintenance user cannot set a flag');

-- anon -------------------------------------------------------------------------------------------------------------------
select set_config('role', 'anon', true);
select throws_ok($$select public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 2, 'other', 'x')$$, '42501', null,
  'anon cannot set a flag');
select throws_ok($$select public.calendar_day_flag_clear_v1('e7700000-0000-4000-8000-0000000000b0', gen_random_uuid())$$, '42501', null,
  'anon cannot clear a flag');
select throws_ok($$select count(*) from public.calendar_day_flags$$, '42501', null, 'anon cannot read the flag table');

-- the admin: set, idempotent set, validation, clear ------------------------------------------------------------------------
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', json_build_object('sub','e7700000-0000-4000-8000-000000000002','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);

select ok((public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 2, 'deep_clean', 'Deep clean after long stay'))->>'ok' = 'true',
  'an admin sets a flag');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'source' = 'manual' and x->>'kind' = 'deep_clean' and x->>'label' = 'Deep clean after long stay'
              and x->>'date' = (current_date + 2)::text and x->>'id' is not null), 1, 'the manual flag shows in day_flags with its id');
select is((public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 2, 'deep_clean', 'Deep clean, 2 cleaners')->>'id'),
  (select x->>'id' from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x where x->>'kind' = 'deep_clean'),
  'setting the same date and kind again updates the one flag and returns its id');
select throws_ok($$select public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 2, 'party', 'x')$$, '22023', null,
  'an unknown kind is refused');
select throws_ok($$select public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 2, 'other', repeat('x', 81))$$, '22023', null,
  'a label over 80 characters is refused');
-- a manual flag beats the auto flag on the same night and kind
select public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 11, 'brownout', 'Generator on');
select is((select x->>'label' || '/' || (x->>'source') from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'kind' = 'brownout' and x->>'date' = (current_date + 11)::text), 'Generator on/manual',
  'a manual flag replaces the auto flag of the same date and kind');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x
            where x->>'kind' = 'brownout' and x->>'date' = (current_date + 11)::text), 1, 'one flag per date and kind');
select is((select count(*)::int from public.admin_audit_log where entity_table = 'calendar_day_flags'), 3, 'two inserts and one label update are in the audit log');

select ok((public.calendar_day_flag_clear_v1('e7700000-0000-4000-8000-0000000000b0',
            (select (x->>'id')::uuid from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x where x->>'kind' = 'deep_clean')))->>'ok' = 'true',
  'an admin clears a flag');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'day_flags') x where x->>'kind' = 'deep_clean'), 0,
  'a cleared flag is gone from day_flags');
select throws_ok($$select public.calendar_day_flag_clear_v1('e7700000-0000-4000-8000-0000000000b0', gen_random_uuid())$$, 'P0002', null, 'clearing an unknown flag is refused');

-- the owner (no property row: owner is not scoped) can write too -------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub','e7700000-0000-4000-8000-000000000003','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select ok((public.calendar_day_flag_set_v1('e7700000-0000-4000-8000-0000000000b0', current_date + 40, 'other', ''))->>'ok' = 'true', 'an owner sets a flag');

-- existing payload keys unchanged --------------------------------------------------------------------------------------
select is((select array_agg(k order by k) from jsonb_object_keys(public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')) k),
  array['calendar','current_guest','day_flags','generated_at','next_guest','property_id','role','today','warnings','weather'],
  'the payload keeps every existing top-level key and adds day_flags');
select is((select array_agg(k order by k) from jsonb_object_keys((public.staff_home_v1('e7700000-0000-4000-8000-0000000000b0')->'calendar')->0) k),
  array['block_label','block_reason','checkin_date','checkin_time','checkout_date','checkout_time','guest_name','nights','source','status','uid'],
  'a calendar row keeps its existing keys and adds block_reason and block_label');

reset role;
select * from finish();
rollback;
