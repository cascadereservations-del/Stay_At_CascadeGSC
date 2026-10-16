-- Session 89, lane L1: release s89_admin_hub_20261023.
-- admin_save_transaction_v1 (receipt), admin_review_queue_v1, admin_review_transaction_v1, expense_categories_v1, get_hospitality_series_v1.
-- Synthetic fixtures on a property private to this suite, inside begin/rollback. Fixtures are inserted as the test owner; the RPCs are called as authenticated.
--   O owner  F finance  C cleaner  A admin of ANOTHER property  N signed in, no staff profile
-- storage.objects is stubbed when the schema is absent (a rehearsal copy); the stub goes with the rollback.
begin;
select plan(60);

do $$
begin
  if to_regclass('storage.objects') is null then
    create schema if not exists storage;
    create table storage.objects(bucket_id text, name text);
  else
    insert into storage.buckets(id, name) values ('expense-receipts', 'expense-receipts') on conflict (id) do nothing;
  end if;
end $$;

insert into public.properties(id, name, is_active) values ('e8900000-0000-4000-8000-0000000000a1', 'Synthetic Admin Hub', true), ('e8900000-0000-4000-8000-0000000000a2', 'Synthetic Other', true);
insert into auth.users(id) values ('e8a00000-0000-4000-8000-0000000000a1'), ('e8a00000-0000-4000-8000-0000000000a2'), ('e8a00000-0000-4000-8000-0000000000a3'),
                                  ('e8a00000-0000-4000-8000-0000000000a4'), ('e8a00000-0000-4000-8000-0000000000a5');
insert into public.staff_access_profiles(user_id, role) values ('e8a00000-0000-4000-8000-0000000000a1', 'owner'), ('e8a00000-0000-4000-8000-0000000000a2', 'finance'),
  ('e8a00000-0000-4000-8000-0000000000a3', 'cleaner'), ('e8a00000-0000-4000-8000-0000000000a4', 'admin');
insert into public.staff_property_access(user_id, property_id) values ('e8a00000-0000-4000-8000-0000000000a2', 'e8900000-0000-4000-8000-0000000000a1'),
  ('e8a00000-0000-4000-8000-0000000000a3', 'e8900000-0000-4000-8000-0000000000a1'), ('e8a00000-0000-4000-8000-0000000000a4', 'e8900000-0000-4000-8000-0000000000a2');
insert into storage.objects(bucket_id, name) values
  ('expense-receipts', 'e8900000-0000-4000-8000-0000000000a1/u1/r1.jpg'), ('expense-receipts', 'e8900000-0000-4000-8000-0000000000a1/u1/r2.jpg'),
  ('expense-receipts', 'e8900000-0000-4000-8000-0000000000a1/u1/r3.jpg'), ('expense-receipts', 'receipts/-100/legacy.jpg'),
  ('expense-receipts', 'e8900000-0000-4000-8000-0000000000a2/u1/other.jpg');
insert into public.expense_categories(property_id, slug, label, keywords, sort_order, is_active) values
  ('e8900000-0000-4000-8000-0000000000a1', 'supplies', 'Supplies', '{}', 10, true), ('e8900000-0000-4000-8000-0000000000a1', 'loan', 'Loan', '{}', 130, true),
  ('e8900000-0000-4000-8000-0000000000a1', 'repairs', 'Repairs', '{}', 50, true), ('e8900000-0000-4000-8000-0000000000a1', 'retired', 'Retired', '{}', 5, false),
  ('e8900000-0000-4000-8000-0000000000a2', 'othercat', 'Other property', '{}', 1, true);
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status)
  values ('e8b00000-0000-4000-8000-0000000000a1', 'e8900000-0000-4000-8000-0000000000a1', 'Synthetic Guest', '0000000000', current_date + 10, current_date + 12, 'direct', 'confirmed');
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, payee_name, booking_id) values
  ('e8c00000-0000-4000-8000-0000000000a1', 'e8900000-0000-4000-8000-0000000000a1', 'expense', 'other',  'pending_review', 'ocr',           current_date - 1, 100, 'Zz ocr',      null),
  ('e8c00000-0000-4000-8000-0000000000a2', 'e8900000-0000-4000-8000-0000000000a1', 'income',  'airbnb_income', 'pending_review', 'airbnb_email', current_date - 2, 500, 'Zz payout',   null),
  ('e8c00000-0000-4000-8000-0000000000a3', 'e8900000-0000-4000-8000-0000000000a1', 'income',  'direct_income', 'pending_review', 'direct_booking', current_date - 3, 400, 'Zz direct',  'e8b00000-0000-4000-8000-0000000000a1'),
  ('e8c00000-0000-4000-8000-0000000000a4', 'e8900000-0000-4000-8000-0000000000a1', 'expense', 'supplies', 'confirmed',      'manual',        current_date - 4, 70,  'Zz confirmed', null),
  ('e8c00000-0000-4000-8000-0000000000a5', 'e8900000-0000-4000-8000-0000000000a1', 'expense', 'other',  'pending_review', 'ocr',           current_date - 5, 0,   'Zz no amount', null);

grant select on public.transactions, public.admin_audit_log, public.expense_categories to authenticated;
create function pg_temp.mo(p_off integer) returns date language sql as $$ select (date_trunc('month', (now() at time zone 'Asia/Manila')::date) + make_interval(months => p_off))::date $$;

-- Shape: security definer, empty search_path, authenticated only.
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""']) from pg_proc p where p.oid in (
  'public.admin_save_transaction_v1(uuid,jsonb,text)'::regprocedure, 'public.admin_review_queue_v1(uuid)'::regprocedure,
  'public.admin_review_transaction_v1(uuid,uuid,text,jsonb,text)'::regprocedure, 'public.expense_categories_v1(uuid)'::regprocedure,
  'public.get_hospitality_series_v1(uuid,integer)'::regprocedure)), 'all five are security definer with an empty search_path');
select ok(not exists (select 1 from pg_proc p where p.oid in (
  'public.admin_save_transaction_v1(uuid,jsonb,text)'::regprocedure, 'public.admin_review_queue_v1(uuid)'::regprocedure,
  'public.admin_review_transaction_v1(uuid,uuid,text,jsonb,text)'::regprocedure, 'public.expense_categories_v1(uuid)'::regprocedure,
  'public.get_hospitality_series_v1(uuid,integer)'::regprocedure)
  and (has_function_privilege('anon', p.oid, 'execute') or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0))), 'anon and PUBLIC cannot execute any of them');
select ok((select bool_and(has_function_privilege('authenticated', p.oid, 'execute')) from pg_proc p where p.oid in (
  'public.admin_save_transaction_v1(uuid,jsonb,text)'::regprocedure, 'public.admin_review_queue_v1(uuid)'::regprocedure,
  'public.admin_review_transaction_v1(uuid,uuid,text,jsonb,text)'::regprocedure, 'public.expense_categories_v1(uuid)'::regprocedure,
  'public.get_hospitality_series_v1(uuid,integer)'::regprocedure)), 'authenticated can execute all of them');
select ok(not exists (select 1 from public.expense_categories e where e.property_id not in ('e8900000-0000-4000-8000-0000000000a1', 'e8900000-0000-4000-8000-0000000000a2')
  group by e.property_id having count(*) filter (where e.slug in ('internet','subscription','furnishing','cohost_fee','airbnb_adjustment','loan')) <> 6),
  'every real property has the six added category slugs (vacuous on an empty database)');

select set_config('request.jwt.claims', json_build_object('sub', 'e8a00000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'aal', 'aal2', 'app_metadata', json_build_object('role', 'owner'), 'iat', extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);

-- 1. admin_save_transaction_v1 --------------------------------------------------------------------------------------------------------------
select is((public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","category":"supplies","transaction_date":"2026-10-01","gross_amount":"250","payee_name":"Zz plain"}'::jsonb, 'key-plain-0000000001')->>'ok')::boolean, true,
  'a save with no receipt works exactly as before');
select ok((select receipt_image_path is null and ocr_confidence is null and ocr_raw is null and source = 'manual' and status = 'confirmed' from public.transactions where payee_name = 'Zz plain'), 'and stores no receipt');
select is((public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","category":"supplies","transaction_date":"2026-10-01","gross_amount":"250","payee_name":"Zz plain"}'::jsonb, 'key-plain-0000000001')->>'replayed')::boolean, true, 'the same idempotency key replays');
select is((public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', jsonb_build_object('txn_type','expense','category','supplies','transaction_date','2026-10-02','gross_amount','300','payee_name','Zz scan',
  'receipt_image_path','e8900000-0000-4000-8000-0000000000a1/u1/r1.jpg','ocr_confidence','0.82','ocr_raw',jsonb_build_object('vendor','Zz')), 'key-scan-00000000001')->>'ok')::boolean, true, 'a save with a receipt under the property folder works');
select ok((select receipt_image_path = 'e8900000-0000-4000-8000-0000000000a1/u1/r1.jpg' and ocr_confidence = 0.82 and ocr_raw->>'vendor' = 'Zz' from public.transactions where payee_name = 'Zz scan'), 'the path, confidence and raw read are stored');
select throws_ok($$select public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"10","receipt_image_path":"e8900000-0000-4000-8000-0000000000a1/u1/r1.jpg"}'::jsonb, 'key-dup-000000000001')$$,
  '23505', 'this receipt is already attached to another transaction', 'the same receipt cannot back a second live row');
select throws_ok($$select public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"10","receipt_image_path":"e8900000-0000-4000-8000-0000000000a2/u1/other.jpg"}'::jsonb, 'key-other-0000000001')$$,
  '22023', 'receipt path is not allowed', 'another property''s folder is refused');
select throws_ok($$select public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"10","receipt_image_path":"e8900000-0000-4000-8000-0000000000a1/../x.jpg"}'::jsonb, 'key-dots-0000000001')$$,
  '22023', 'receipt path is not allowed', 'a path with .. is refused');
select throws_ok($$select public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"10","receipt_image_path":"e8900000-0000-4000-8000-0000000000a1/u1/missing.jpg"}'::jsonb, 'key-miss-0000000001')$$,
  '22023', 'receipt file was not found', 'a path with no object behind it is refused');
select throws_ok($$select public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"10","receipt_image_path":"e8900000-0000-4000-8000-0000000000a1/u1/r2.jpg","ocr_confidence":"1.5"}'::jsonb, 'key-conf-0000000001')$$,
  '22023', 'ocr_confidence must be between 0 and 1', 'confidence outside 0..1 is refused');
select is((select count(*)::int from public.transactions where receipt_image_path = 'e8900000-0000-4000-8000-0000000000a1/u1/r2.jpg'), 0, 'the refused calls wrote nothing');
select is((public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"15","payee_name":"Zz legacy","receipt_image_path":"receipts/-100/legacy.jpg"}'::jsonb, 'key-legacy-00000001')->>'ok')::boolean, true, 'a legacy receipts/ path is accepted');
-- Edit: attach to an existing row, and an edit without the key keeps the path.
select is((public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', jsonb_build_object('id', (select id from public.transactions where payee_name = 'Zz plain'), 'receipt_image_path', 'e8900000-0000-4000-8000-0000000000a1/u1/r3.jpg', 'reason', 'attach receipt'), null)->>'ok')::boolean, true,
  'an edit can attach a receipt to an existing row');
select is((public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', jsonb_build_object('id', (select id from public.transactions where payee_name = 'Zz plain'), 'notes', 'n', 'reason', 'note only'), null)->>'ok')::boolean, true, 'a later edit without the key succeeds');
select is((select receipt_image_path from public.transactions where payee_name = 'Zz plain'), 'e8900000-0000-4000-8000-0000000000a1/u1/r3.jpg', 'and keeps the receipt');
select is((select count(*)::int from public.admin_audit_log where entity_table = 'transactions' and entity_id = (select id from public.transactions where payee_name = 'Zz plain') and action = 'update' and reason = 'attach receipt'), 1, 'the attach is audited with its reason');
select throws_ok($$select public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"10"}'::jsonb, 'short')$$, '22023', 'idempotency key required', 'existing validation is intact');

-- 2. expense_categories_v1 ------------------------------------------------------------------------------------------------------------------
select is((select array_agg(slug order by sort_order) from public.expense_categories_v1('e8900000-0000-4000-8000-0000000000a1')), array['supplies','repairs','loan'], 'the list is the active rows of this property, in order');

-- 3. review queue and review ----------------------------------------------------------------------------------------------------------------
select is((public.admin_review_queue_v1('e8900000-0000-4000-8000-0000000000a1')->>'count')::int, 3, 'the queue counts pending rows, without the booking-linked direct payment');
select is((public.admin_review_queue_v1('e8900000-0000-4000-8000-0000000000a1')->>'total')::numeric, 600::numeric, 'and totals them (100 + 500 + 0)');
select ok((select jsonb_array_length(r->'rows') = 3 and not (r->'rows'->0 ? 'ocr_raw') and not (r->'rows'->0 ? 'external_ref') and not (r->'rows'->0 ? 'booking_id') from (select public.admin_review_queue_v1('e8900000-0000-4000-8000-0000000000a1') r) x),
  'rows carry no raw OCR, external reference or booking link');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a3', 'approve')$$, '22023', 'a direct booking payment is confirmed on Inquiries, not here', 'a booking-linked direct payment cannot be approved here');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a3', 'void', '{}', 'no way')$$, '22023', 'a direct booking payment is confirmed on Inquiries, not here', 'nor voided');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a1', 'reject')$$, '22023', 'action must be approve or void', 'an unknown action is refused');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a5', 'approve')$$, '22023', 'enter the amount before approving', 'a zero-amount row needs an amount first');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a1', 'approve', '{"category":"nonsense"}')$$, '22023', 'unknown expense category', 'an edit to an unknown category is refused');
select is((select status from public.transactions where id = 'e8c00000-0000-4000-8000-0000000000a1'), 'pending_review', 'and the refused edits changed nothing');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a5', 'void', '{}', ' ')$$, '22023', 'a reason is required to void', 'a void needs a reason');
select is((public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a2', 'approve')->>'status'), 'confirmed', 'approve confirms the row');
select is((select count(*)::int from public.admin_audit_log where entity_table = 'transactions' and entity_id = 'e8c00000-0000-4000-8000-0000000000a2' and action = 'update' and reason = 'approved in review queue' and actor_user_id = 'e8a00000-0000-4000-8000-0000000000a1'), 1,
  'the approval is in the audit log with the actor');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a2', 'approve')$$, '22023', null, 'a row that is no longer pending cannot be reviewed again');
select is((public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a1', 'approve', '{"category":"repairs","gross_amount":"120","payee_name":"Zz fixed"}', 'checked receipt')->>'status'), 'confirmed', 'edit + approve confirms');
select ok((select category = 'repairs' and gross_amount = 120 and payee_name = 'Zz fixed' and status = 'confirmed' from public.transactions where id = 'e8c00000-0000-4000-8000-0000000000a1'), 'with the edits applied');
select ok((select (before_state->>'gross_amount')::numeric = 100 and (after_state->>'gross_amount')::numeric = 120 from public.admin_audit_log where entity_table = 'transactions' and entity_id = 'e8c00000-0000-4000-8000-0000000000a1' and reason = 'checked receipt'), 'the audit row keeps before and after');
select is((public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a5', 'void', '{}', 'duplicate scan')->>'status'), 'void', 'void voids the row');
select is((select count(*)::int from public.admin_audit_log where entity_table = 'transactions' and entity_id = 'e8c00000-0000-4000-8000-0000000000a5' and action = 'soft_delete' and reason = 'duplicate scan'), 1, 'and logs a soft_delete with the reason');
select is((public.admin_review_queue_v1('e8900000-0000-4000-8000-0000000000a1')->>'count')::int, 0, 'the queue is now empty');

-- 4. get_hospitality_series_v1 --------------------------------------------------------------------------------------------------------------
select is(jsonb_array_length(public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 4)->'months'), 4, 'p_months months come back');
select is(jsonb_array_length(public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1')->'months'), 12, 'twelve by default');
select is((public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 4)->'months'->3->>'month')::date, pg_temp.mo(0), 'the last month is the current month');
select ok((with s as (select m from jsonb_array_elements(public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 3)->'months') m),
                x as (select s.m, public.get_hospitality_metrics_v1('e8900000-0000-4000-8000-0000000000a1', (s.m->>'month')::date, ((s.m->>'month')::date + interval '1 month')::date)->'metrics' k from s)
          select bool_and((x.m->>'sold_nights')::numeric is not distinct from (x.k->'sold_nights'->>'value')::numeric
                      and (x.m->>'occupancy')::numeric is not distinct from (x.k->'occupancy'->>'value')::numeric
                      and (x.m->>'adr')::numeric is not distinct from (x.k->'adr'->>'value')::numeric
                      and (x.m->>'revpar')::numeric is not distinct from (x.k->'revpar'->>'value')::numeric
                      and (x.m->>'revenue')::numeric is not distinct from (x.k->'accommodation_revenue'->>'value')::numeric) from x),
  'every month equals get_hospitality_metrics_v1 for that month (sold nights, occupancy, ADR, RevPAR, revenue)');
select is(jsonb_array_length(public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 2)->'pace'), 3, 'pace has three months');
select is((public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 2)->'pace'->0->>'month')::date, pg_temp.mo(0), 'and starts with the current month');
select ok((public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 2)->'pace'->0->'ly_otb_nights') = 'null'::jsonb, 'last year pace is null when the property was not operating on that day');
select throws_ok($$select public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 0)$$, '22023', 'months must be between 1 and 24', 'zero months is refused');
select throws_ok($$select public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 25)$$, '22023', 'months must be between 1 and 24', 'more than 24 is refused');

-- Roles -------------------------------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'e8a00000-0000-4000-8000-0000000000a3', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$select public.admin_review_queue_v1('e8900000-0000-4000-8000-0000000000a1')$$, '42501', 'read_finance denied', 'a cleaner cannot read the queue');
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a1', 'void', '{}', 'cleaner')$$, '42501', 'approve_payment denied', 'a cleaner cannot review');
select throws_ok($$select * from public.expense_categories_v1('e8900000-0000-4000-8000-0000000000a1')$$, '42501', 'read_finance denied', 'a cleaner cannot read the category list');
select throws_ok($$select public.admin_save_transaction_v1('e8900000-0000-4000-8000-0000000000a1', '{"txn_type":"expense","transaction_date":"2026-10-02","gross_amount":"10"}'::jsonb, 'key-cleaner-00000001')$$, '42501', 'approve_payment denied', 'a cleaner cannot save a transaction');
select ok((public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 2)->>'financeVisible')::boolean = false and (public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 2)->'months'->0->'revenue') = 'null'::jsonb,
  'a cleaner gets the series with finance numbers withheld (same gate as the metrics)');

select set_config('request.jwt.claims', json_build_object('sub', 'e8a00000-0000-4000-8000-0000000000a4', 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$select public.admin_review_queue_v1('e8900000-0000-4000-8000-0000000000a1')$$, '42501', 'read_finance denied', 'an admin of another property cannot read this queue');
select throws_ok($$select public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 2)$$, '42501', 'read_operations denied', 'nor this series');

select set_config('request.jwt.claims', json_build_object('sub', 'e8a00000-0000-4000-8000-0000000000a5', 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$select public.admin_review_transaction_v1('e8900000-0000-4000-8000-0000000000a1', 'e8c00000-0000-4000-8000-0000000000a1', 'void', '{}', 'nobody')$$, '42501', 'approve_payment denied', 'a signed-in user with no staff profile is refused');

select set_config('request.jwt.claims', json_build_object('sub', 'e8a00000-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
select is((public.admin_review_queue_v1('e8900000-0000-4000-8000-0000000000a1')->>'count')::int, 0, 'finance can read the queue');

reset role;
select set_config('role', 'anon', true);
select throws_ok($$select public.get_hospitality_series_v1('e8900000-0000-4000-8000-0000000000a1', 2)$$, '42501', null, 'anon is refused outright');

select * from finish();
rollback;
