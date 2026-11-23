-- Session 134: release s134_expenses_20261204 (D-405). One expense ledger: stock bought becomes ONE ledger row per receipt, the Expenses screen, receipts, the KPI from the ledger.
-- Synthetic fixtures only (uuids e1340000-..., names "Zz S134 ..."); everything rolls back. Fixture rows and the reads run as the owner role (a --no-acl restore gives authenticated no table grants);
-- only the RPC calls run as the staff roles. Every case that relies on the deferred stock trigger issues "set constraints all immediate;" after the write (one uncommitted transaction never fires it otherwise).
-- T12 does not exist (dropped from the plan). T16 runs a verbatim copy of supabase/sql/s134_backfill.sql (between the BACKFILL markers; the lane's gate compares the two).
begin;
select plan(142);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
alter role service_role bypassrls;

create function pg_temp.as_user(p_uid uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal, 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid, text) to public;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true), set_config('role', 'service_role', true);
$$;
grant execute on function pg_temp.as_service() to public;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1340000-0000-4000-8000-0000000000' || p)::uuid $$;
-- non-void ledger rows of one receipt group; the newest row of a group; open sync tasks of a house
create function pg_temp.nrows(p_group text) returns integer language sql stable as $$
  select count(*)::integer from public.transactions t where t.external_ref = 'stock:' || p_group and t.status <> 'void' $$;
create function pg_temp.tid(p_group text) returns uuid language sql stable as $$
  select t.id from public.transactions t where t.external_ref = 'stock:' || p_group order by (t.status <> 'void') desc, t.created_at desc limit 1 $$;
create function pg_temp.tasks(p_prop uuid) returns integer language sql stable as $$
  select count(*)::integer from public.follow_up_tasks t where t.property_id = p_prop and t.source_kind = 'stock_expense_sync' $$;
-- a stored receipt object + its upload proof, as the Attach / Extract modes leave them
create function pg_temp.rpath(p_prop uuid, p_uid uuid, p_n text, p_ext text default 'jpg') returns text language sql immutable as $$
  select p_prop::text || '/' || p_uid::text || '/e1340000-0000-4000-8000-0000000000' || p_n || '.' || p_ext $$;
create function pg_temp.upload(p_prop uuid, p_uid uuid, p_n text, p_sha text, p_ext text default 'jpg', p_age interval default '0') returns text language plpgsql as $$
declare v text := pg_temp.rpath(p_prop, p_uid, p_n, p_ext);
begin
  insert into storage.objects(bucket_id, name) values ('expense-receipts', v) on conflict do nothing;
  insert into public.staff_upload_hashes(path, sha256, uploaded_by, created_at) values (v, p_sha, p_uid, now() - p_age)
    on conflict (path) do update set sha256 = excluded.sha256, uploaded_by = excluded.uploaded_by, created_at = excluded.created_at;
  return v;
end $$;
grant execute on function pg_temp.nrows(text), pg_temp.tid(text), pg_temp.tasks(uuid), pg_temp.rpath(uuid, uuid, text, text), pg_temp.upload(uuid, uuid, text, text, text, interval), pg_temp.id(text), pg_temp.try(text) to public;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- =============================================================================================================================================
-- Fixtures: 01 owner, 02 admin, 03 finance, 04 cleaner, 05 inspector, 06 maintenance, 07 laundry (02-07 on house b1 only); houses b1 and b2
--   b1: items a1 Soap, a2 Tissue, a3 Bleach       b2 (the clean room for auto-confirmed stock): e1 Rice, e2 Oil, e3 Salt (no price), e4 Sugar, e5 Flour; suppliers d1, d2
-- =============================================================================================================================================
insert into auth.users(id, email) select pg_temp.id('0' || n), 'zz134-u' || n || '@example.com' from generate_series(1, 7) n;
insert into public.properties(id, name, is_active) values (pg_temp.id('b1'), 'Zz S134 House', true), (pg_temp.id('b2'), 'Zz S134 Clean Room', true);
insert into public.staff_access_profiles(user_id, role) values (pg_temp.id('01'), 'owner'), (pg_temp.id('02'), 'admin'), (pg_temp.id('03'), 'finance'), (pg_temp.id('04'), 'cleaner'),
  (pg_temp.id('05'), 'inspector'), (pg_temp.id('06'), 'maintenance'), (pg_temp.id('07'), 'laundry');
insert into public.staff_property_access(user_id, property_id) select pg_temp.id('0' || n), pg_temp.id('b1') from generate_series(2, 7) n;
insert into public.staff_property_access(user_id, property_id) values (pg_temp.id('02'), pg_temp.id('b2')), (pg_temp.id('03'), pg_temp.id('b2'));
insert into public.expense_categories(property_id, slug, label, sort_order) select x.p, c.slug, c.label, c.o
  from (values (pg_temp.id('b1')), (pg_temp.id('b2'))) x(p), (values ('supplies', 'Supplies', 1), ('maintenance', 'Maintenance', 2), ('repairs', 'Repairs', 3), ('cleaning', 'Cleaning', 4), ('utilities', 'Utilities', 5),
     ('other', 'Other', 6), ('loan', 'Loan', 7), ('guest_refund', 'Guest refund', 900), ('airbnb_adjustment', 'Airbnb adjustment', 901)) c(slug, label, o);
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, unit_cost, purchase_unit) values
  (pg_temp.id('a1'), pg_temp.id('b1'), 'Zz S134 Soap', 'Toiletries', 'pc', 10, true, true, 1, 20, null),
  (pg_temp.id('a2'), pg_temp.id('b1'), 'Zz S134 Tissue', 'Toiletries', 'pc', 10, true, true, 1, 10, null),
  (pg_temp.id('a3'), pg_temp.id('b1'), 'Zz S134 Bleach', 'Cleaning', 'pc', 10, true, true, 1, 5, null),
  (pg_temp.id('e1'), pg_temp.id('b2'), 'Zz S134 Rice', 'Kitchen', 'pc', 5, true, true, 1, 10, null),
  (pg_temp.id('e2'), pg_temp.id('b2'), 'Zz S134 Oil', 'Kitchen', 'pc', 5, true, true, 1, 40, null),
  (pg_temp.id('e3'), pg_temp.id('b2'), 'Zz S134 Salt', 'Kitchen', 'pc', 5, true, true, 1, null, null),
  (pg_temp.id('e4'), pg_temp.id('b2'), 'Zz S134 Sugar', 'Kitchen', 'pc', 5, true, true, 1, 10, null),
  (pg_temp.id('e5'), pg_temp.id('b2'), 'Zz S134 Flour', 'Kitchen', 'pc', 5, true, true, 1, 10, null);
insert into public.inventory_suppliers(id, property_id, name, payment_method) values (pg_temp.id('d1'), pg_temp.id('b2'), 'Zz S134 Shop One', 'cash'), (pg_temp.id('d2'), pg_temp.id('b2'), 'Zz S134 Shop Two', 'cash');

-- =============================================================================================================================================
-- 1. schema, grants, definer / search_path
-- =============================================================================================================================================
select ok((select pg_get_constraintdef(c.oid) like '%''inventory''%' and pg_get_constraintdef(c.oid) like '%''bill''%' and pg_get_constraintdef(c.oid) like '%''airbnb_payout_email''%' from pg_constraint c where c.conrelid = 'public.transactions'::regclass and c.conname = 'transactions_source_check'), 'the source CHECK accepts inventory and still holds the older values');
select ok((select count(*) = 2 from information_schema.columns where table_schema = 'public' and table_name = 'inventory_purchases' and column_name in ('transaction_id', 'expense_group')), 'inventory_purchases has transaction_id and expense_group');
select ok((select count(*) = 1 from pg_trigger t where t.tgrelid = 'public.inventory_purchases'::regclass and t.tgname = 's134_stock_expense_group' and t.tgenabled = 'O' and (t.tgtype & 2) = 2 and (t.tgtype & 4) = 4)
      and (select count(*) = 1 from pg_trigger t where t.tgrelid = 'public.inventory_purchases'::regclass and t.tgname = 's134_stock_expense_sync' and t.tgenabled = 'O' and t.tgdeferrable and t.tginitdeferred and t.tgconstraint <> 0),
  'the group trigger (before insert) and the sync trigger (deferred constraint trigger) exist and are enabled');
select ok((select md5(replace(p.prosrc, chr(13), '')) = '7c6d5a22d09ad96916804630f31df602' from pg_proc p where p.oid = 'public.kpi_tab_v1(uuid,date)'::regprocedure), 'kpi_tab_v1 carries the s134 body (md5 pinned)');
select ok((select bool_and(has_function_privilege('authenticated', f::regprocedure, 'execute') and not has_function_privilege('anon', f::regprocedure, 'execute') and not has_function_privilege('service_role', f::regprocedure, 'execute'))
             from unnest(array['public.expenses_screen_v1(uuid,date,integer,timestamptz,text,uuid)', 'public.admin_save_transaction_v2(uuid,jsonb,text)', 'public.expense_void_v1(uuid,uuid,text,uuid)',
                               'public.expense_receipt_paths_v1(uuid,uuid[])', 'public.expense_receipt_set_v1(uuid,uuid,text,text)']) f), 'the five client RPCs: authenticated only');
select ok((select bool_and(has_function_privilege('service_role', f::regprocedure, 'execute') and not has_function_privilege('anon', f::regprocedure, 'execute') and not has_function_privilege('authenticated', f::regprocedure, 'execute'))
             from unnest(array['public.telegram_expense_save_v1(uuid,jsonb,text)', 'public.telegram_expense_review_v1(uuid,text,jsonb,text)']) f), 'the two Telegram RPCs: service_role only');
select ok((select bool_and(not has_function_privilege('anon', f::regprocedure, 'execute') and not has_function_privilege('authenticated', f::regprocedure, 'execute') and not has_function_privilege('service_role', f::regprocedure, 'execute'))
             from unnest(array['public.s_stock_expense_group_of_v1(uuid,text)', 'public.s_stock_expense_txn_of_v1(text)', 'public.s_stock_expense_group_v1()', 'public.s_stock_expense_trg_v1()', 'public.s_stock_expense_sync_v1(text)',
                               'public.s_stock_expense_task_v1(uuid,text,text,text)', 'public.s_stock_expense_owned_v1(uuid)', 'public.s_txn_void_core_v1(uuid,text,text,boolean)', 'public.s_expense_chip_v1(text,boolean,boolean)',
                               'public.s_expense_mime_v1(text)', 'public.s_expense_receipt_v1(uuid,boolean)', 'public.s_expense_lookalike_v1(uuid)', 'public.s_expense_receipt_gate_v1(uuid,text,uuid)',
                               'public.s_expense_bucket_pdf_v1(text)', 'public.kpi_admin_costs_v1(uuid,date,date)']) f), 'the 15 internal functions: no client grant');
select ok((select count(*) = 19 and bool_and(p.prosecdef) and bool_and(exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
             from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('expenses_screen_v1', 'admin_save_transaction_v2', 'expense_void_v1', 'expense_receipt_paths_v1', 'expense_receipt_set_v1',
               'telegram_expense_save_v1', 'telegram_expense_review_v1', 's_stock_expense_group_v1', 's_stock_expense_trg_v1', 's_stock_expense_sync_v1', 's_stock_expense_task_v1', 's_stock_expense_owned_v1',
               's_txn_void_core_v1', 's_expense_receipt_v1', 's_expense_lookalike_v1', 's_expense_receipt_gate_v1', 's_expense_bucket_pdf_v1', 'kpi_admin_costs_v1', 'kpi_tab_v1')),
  'the 19 definer functions all pin search_path');
select ok((select count(*) = 3 and bool_and(exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('s_stock_expense_group_of_v1', 's_expense_chip_v1', 's_expense_mime_v1')),
  'the 3 pure helpers pin search_path too');
select ok((select p.pronargs = 4 from pg_proc p where p.oid = 'public.expense_receipt_set_v1(uuid,uuid,text,text)'::regprocedure), 'expense_receipt_set_v1 has four arguments (no sha parameter: the server reads it)');
select ok((select (s.value #>> '{}')::timestamptz <= now() from public.app_settings s where s.key = 's134_stock_expense_from'), 'the cut-over timestamp is stored in app_settings');

-- =============================================================================================================================================
-- T1 definition drift: one fixture row per exclusion; the screen total = get_finance_summary.expenses = kpi_tab_v1.admin.costs_month
-- =============================================================================================================================================
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, hidden_at, archived_at, archived_prev_status) values
  (pg_temp.id('c1'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 100, 'Zz S134 counted', null, null, null),
  (pg_temp.id('c2'), pg_temp.id('b1'), 'expense', 'other', 'pending_review', 'manual', public.manila_today(), 40, 'Zz S134 pending', null, null, null),
  (pg_temp.id('c3'), pg_temp.id('b1'), 'expense', 'other', 'void', 'manual', public.manila_today(), 30, 'Zz S134 void', null, null, null),
  (pg_temp.id('c4'), pg_temp.id('b1'), 'expense', 'other', 'void', 'manual', public.manila_today(), 20, 'Zz S134 archived', null, now(), 'confirmed'),
  (pg_temp.id('c5'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 10, 'Zz S134 hidden still counts', now(), null, null),
  (pg_temp.id('c6'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'airbnb', public.manila_today(), 500, 'Zz S134 mirror', null, null, null),
  (pg_temp.id('c7'), pg_temp.id('b1'), 'expense', 'owner_drawing', 'confirmed', 'manual', public.manila_today(), 70, 'Zz S134 not an expense type', null, null, null);
update public.transactions set txn_type = 'drawing' where id = pg_temp.id('c7');
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, income_stage) values
  (pg_temp.id('c8'), pg_temp.id('b1'), 'income', 'other', 'confirmed', 'manual', public.manila_today(), 900, 'Zz S134 income', 'confirmed');
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'scr1', public.expenses_screen_v1(pg_temp.id('b1'));
insert into _t select 'kpi1', public.kpi_tab_v1(pg_temp.id('b1'));
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'total')::numeric = 110 and (v ->> 'count')::int = 2 from _t where k = 'scr1'), 'T1: the screen counts the confirmed + hidden rows only (110 in 2 rows): pending, void, archived, mirror, drawing and income are out');
select ok((select (public.get_finance_summary(public.manila_today(), pg_temp.id('b1')) ->> 'expenses')::numeric = (v ->> 'total')::numeric from _t where k = 'scr1'), 'T1: the screen total equals get_finance_summary.expenses');
select ok((select (v -> 'admin' ->> 'costs_month')::numeric = 110 from _t where k = 'kpi1'), 'T1: kpi_tab_v1.admin.costs_month equals the same figure');
select ok((select (v -> 'pending' ->> 'count')::int = 1 and (v -> 'pending' ->> 'total')::numeric = 40 and (v -> 'pending_all' ->> 'count')::int = 1 from _t where k = 'scr1')
      and (select (v -> 'admin' -> 'costs_pending_month' ->> 'count')::int = 1 and (v -> 'admin' -> 'costs_pending_month' ->> 'total')::numeric = 40 from _t where k = 'kpi1'), 'T1: pending is shown (screen and KPI) but not counted');
select ok((select jsonb_array_length(v -> 'rows') = 3 and (select bool_and((r ->> 'id')::uuid in (pg_temp.id('c1'), pg_temp.id('c2'), pg_temp.id('c5'))) from jsonb_array_elements(v -> 'rows') r) from _t where k = 'scr1'), 'T1: the list holds the confirmed, hidden and pending rows (hidden is a flag, not a filter)');

-- =============================================================================================================================================
-- T2 single admin receipt with price. b2 has a nearby CLEANING expense (it must not block auto-confirm: T2c). b1 has a nearby manual SUPPLIES expense of another amount (T2b: pending).
-- =============================================================================================================================================
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes) values
  (pg_temp.id('c9'), pg_temp.id('b2'), 'expense', 'cleaning', 'confirmed', 'manual', public.manila_today(), 333, 'Zz S134 nearby cleaning'),
  (pg_temp.id('ca'), pg_temp.id('b1'), 'expense', 'supplies', 'confirmed', 'manual', public.manila_today(), 77, 'Zz S134 nearby supplies');
select pg_temp.as_user(pg_temp.id('01'));
set constraints all deferred;
insert into _t select 'adm1', public.record_inventory_receipt_v1(pg_temp.id('e1'), 3, 20, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00001');
set constraints all immediate;
set constraints all deferred;
insert into _t select 'adm1b', public.record_inventory_receipt_v1(pg_temp.id('e1'), 3, 20, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00001');
set constraints all immediate;
set constraints all deferred;
insert into _t select 'adm2', public.record_inventory_receipt_v1(pg_temp.id('a1'), 1, 40, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00002');
set constraints all immediate;
reset role;
select ok(pg_temp.nrows('rcpt:zz-s134-adm-key-00001') = 1 and (select t.status = 'confirmed' and t.source = 'inventory' and t.category = 'supplies' and t.gross_amount = 60 and t.ocr_raw ->> 's134_auto' = 'true' and t.logged_by = 'system'
             and t.payee_name = 'Zz S134 Shop' and t.notes like 'Stock bought: Zz S134 Rice%' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00001')),
  'T2/T2c: one admin receipt with a price (3 x 20) gives ONE confirmed inventory row of 60 marked s134_auto; a nearby cleaning expense does not block it');
select ok((select count(*) = 1 and bool_and(p.transaction_id = pg_temp.tid('rcpt:zz-s134-adm-key-00001') and p.expense_group = 'rcpt:zz-s134-adm-key-00001') from public.inventory_purchases p where p.item_id = pg_temp.id('e1')), 'T2: the purchase is grouped and linked to the row');
select ok((select (v ->> 'replayed')::boolean from _t where k = 'adm1b') and (select count(*) = 1 from public.transactions t where t.property_id = pg_temp.id('b2') and t.source = 'inventory'), 'T2: the same receipt key again adds no purchase and no row');
select ok(pg_temp.nrows('rcpt:zz-s134-adm-key-00002') = 1 and (select t.status = 'pending_review' and t.ocr_raw ->> 's134_auto' = 'false' and t.gross_amount = 40 from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00002')),
  'T2b: with a supplies expense of another amount within 3 days the stock row is PENDING (never auto-confirmed)');

-- =============================================================================================================================================
-- T3 / T4: receipt lines, group updates, derived keys
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01'));
set constraints all deferred;
insert into _t select 'rl3', public.inventory_receipt_lines_v1(pg_temp.id('e2'), jsonb_build_array(jsonb_build_object('packs', 2), jsonb_build_object('packs', 1)), 300, public.manila_today(), null, 'zz-s134-rcpt-key-0003');
set constraints all immediate;
-- T3b: two items on one receipt, one with no price at all
set constraints all deferred;
insert into _t select 'g3b', public.inventory_group_update_v1(pg_temp.id('b2'), 'bought', jsonb_build_array(
    jsonb_build_object('item_id', pg_temp.id('e4'), 'lines', jsonb_build_array(jsonb_build_object('packs', 1, 'unit_cost', 5))),
    jsonb_build_object('item_id', pg_temp.id('e3'), 'lines', jsonb_build_array(jsonb_build_object('packs', 1)))), 'zz-s134-grp-key-3b0001');
set constraints all immediate;
-- T3c: nothing priced at all
set constraints all deferred;
insert into _t select 'g3c', public.inventory_group_update_v1(pg_temp.id('b2'), 'bought', jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('e3'), 'lines', jsonb_build_array(jsonb_build_object('packs', 1)))), 'zz-s134-grp-key-3c0001');
set constraints all immediate;
-- T4: two items, two suppliers
set constraints all deferred;
insert into _t select 'g4', public.inventory_group_update_v1(pg_temp.id('b2'), 'bought', jsonb_build_array(
    jsonb_build_object('item_id', pg_temp.id('e4'), 'total_paid', 100, 'supplier_id', pg_temp.id('d1'), 'lines', jsonb_build_array(jsonb_build_object('packs', 2))),
    jsonb_build_object('item_id', pg_temp.id('e5'), 'total_paid', 60, 'supplier_id', pg_temp.id('d2'), 'lines', jsonb_build_array(jsonb_build_object('packs', 1)))), 'zz-s134-grp-key-040001');
set constraints all immediate;
-- T4b: a key over 160 characters is hashed per line: one group (and one row) per line, never zero or two per purchase
set constraints all deferred;
insert into _t select 'g4b', pg_temp.try(format('select public.inventory_group_update_v1(%L::uuid, %L, %L::jsonb, %L)', pg_temp.id('b2'), 'bought', jsonb_build_array(
    jsonb_build_object('item_id', pg_temp.id('e1'), 'total_paid', 25, 'lines', jsonb_build_array(jsonb_build_object('packs', 1))),
    jsonb_build_object('item_id', pg_temp.id('e5'), 'total_paid', 35, 'lines', jsonb_build_array(jsonb_build_object('packs', 1))))::text, 'zz-s134-' || repeat('k', 151)));
set constraints all immediate;
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'rl3') and pg_temp.nrows('rcpt:zz-s134-rcpt-key-0003') = 1 and (select abs(t.gross_amount - 300) <= 0.10 and t.status = 'confirmed' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-rcpt-key-0003'))
      and (select count(*) = 2 and bool_and(p.transaction_id = pg_temp.tid('rcpt:zz-s134-rcpt-key-0003')) from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-rcpt-key-0003'),
  'T3: three packs on two lines make ONE row, within P0.10 of the total paid (300), both purchases linked');
select ok(pg_temp.nrows('rcpt:zz-s134-grp-key-3b0001') = 1 and (select t.status = 'pending_review' and t.ocr_raw ->> 's134_incomplete' = 'true' and t.gross_amount = 5 from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-grp-key-3b0001')),
  'T3b: one priced and one unpriced line: one PENDING row of what is priced, marked ocr_raw.s134_incomplete = true');
select ok(pg_temp.nrows('rcpt:zz-s134-grp-key-3c0001') = 0 and (select count(*) = 1 from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-grp-key-3c0001' and p.transaction_id is null), 'T3c: no priced line: no ledger row, the purchase stays unlinked');
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'scr3c', public.expenses_screen_v1(pg_temp.id('b2'));
reset role;
select ok((select (v -> 'unpriced' ->> 'count')::int = 1 and v -> 'unpriced' -> 'items' -> 0 ->> 'name' = 'Zz S134 Salt' from _t where k = 'scr3c'), 'T3c: the screen lists the receipt as unpriced (count 1, the item named)');
select ok(pg_temp.nrows('rcpt:zz-s134-grp-key-040001') = 1 and (select t.payee_name is null and t.notes like '%Several suppliers%' and t.gross_amount = 160 and t.status = 'confirmed' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-grp-key-040001'))
      and (select count(*) = 2 and bool_and(p.transaction_id = pg_temp.tid('rcpt:zz-s134-grp-key-040001')) from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-grp-key-040001'),
  'T4: a Bought update with two items and two suppliers is ONE row of 160 with no payee, noted "Several suppliers"');
select ok((select (v ->> 'ok')::boolean from _t where k = 'g4b') is not distinct from true and not exists (select 1 from public.inventory_purchases p where p.notes like '%[key:h%' and p.item_id in (pg_temp.id('e1'), pg_temp.id('e5')) and p.transaction_id is null)
      and (select count(distinct p.transaction_id) = 2 and count(distinct p.expense_group) = 2 from public.inventory_purchases p where p.notes like '%[key:h%' and p.item_id in (pg_temp.id('e1'), pg_temp.id('e5')))
      and not exists (select 1 from public.inventory_purchases p where p.notes like '%[key:h%' and p.item_id in (pg_temp.id('e1'), pg_temp.id('e5')) group by p.expense_group having count(distinct p.transaction_id) <> 1),
  'T4b: a derived key over 160 characters is hashed per line: two groups, two rows, each purchase linked to exactly one');

-- =============================================================================================================================================
-- T5 staff manual entry with a total: one PENDING row, the draft is linked; once a person approves it the undo is refused (S4). T5b an undo before review voids it and leaves no second row.
-- =============================================================================================================================================
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('04'));
insert into _t select 'm1', public.inventory_receipt_manual_v1(jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('a2'), 'qty_units', 3)), null, 'Zz S134 Vendor', 'zz-s134-manual-key-001', 450.5, null, 'zz note');
insert into _t select 'm2', public.inventory_receipt_manual_v1(jsonb_build_array(jsonb_build_object('item_id', pg_temp.id('a3'), 'qty_units', 2)), null, 'Zz S134 Vendor', 'zz-s134-manual-key-002', 90, null, null);
set constraints all immediate;
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'm1') and pg_temp.nrows('draft:' || (select v ->> 'draft_id' from _t where k = 'm1')) = 1
      and (select t.status = 'pending_review' and t.gross_amount = 450.50 and t.source = 'inventory' and t.ocr_raw ->> 's134_auto' = 'false' from public.transactions t where t.id = pg_temp.tid('draft:' || (select v ->> 'draft_id' from _t where k = 'm1')))
      and (select d.transaction_id = pg_temp.tid('draft:' || (select v ->> 'draft_id' from _t where k = 'm1')) from public.inventory_receipt_drafts d where d.id = (select (v ->> 'draft_id')::uuid from _t where k = 'm1')),
  'T5: a staff manual entry with a total paid gives ONE pending row of the typed total (never auto-confirmed) and the draft points at it');
update public.transactions set status = 'confirmed' where id = pg_temp.tid('draft:' || (select v ->> 'draft_id' from _t where k = 'm1'));
select pg_temp.as_user(pg_temp.id('04'));
insert into _t select 'm1u', public.inventory_receipt_undo_v1((select (v ->> 'draft_id')::uuid from _t where k = 'm1'));
insert into _t select 'm2u', public.inventory_receipt_undo_v1((select (v ->> 'draft_id')::uuid from _t where k = 'm2'));
set constraints all immediate;
reset role;
select ok((select v ->> 'error' = 'already_reviewed' from _t where k = 'm1u') and (select t.status = 'confirmed' from public.transactions t where t.id = pg_temp.tid('draft:' || (select v ->> 'draft_id' from _t where k = 'm1')))
      and exists (select 1 from public.inventory_purchases p where p.expense_group = 'draft:' || (select v ->> 'draft_id' from _t where k = 'm1')),
  'T5: after a person approved the row, the staff undo answers already_reviewed; the row stays confirmed and the stock stays');
select ok((select (v ->> 'ok')::boolean from _t where k = 'm2u') and (select t.status = 'void' from public.transactions t where t.id = pg_temp.tid('draft:' || (select v ->> 'draft_id' from _t where k = 'm2')))
      and (select count(*) = 1 from public.transactions t where t.external_ref = 'stock:draft:' || (select v ->> 'draft_id' from _t where k = 'm2'))
      and not exists (select 1 from public.inventory_purchases p where p.expense_group = 'draft:' || (select v ->> 'draft_id' from _t where k = 'm2')),
  'T5b: an undo before review voids the row, deletes the purchases and creates no second row');

-- =============================================================================================================================================
-- T6 OCR confirm: the staff-receipt core inserts its own pending OCR row; the sync links the purchases and adds nothing
-- =============================================================================================================================================
insert into public.inventory_receipt_drafts(id, property_id, created_by, vendor, total, lines, status)
values (pg_temp.id('d9'), pg_temp.id('b2'), pg_temp.id('01'), 'Zz S134 Vendor', 80, '[{"line_no":1,"qty":1,"unit_cost":80}]'::jsonb, 'draft');
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
reset role;
insert into _t select 'ocr', public.s_inventory_receipt_confirm_core_v1(pg_temp.id('d9'), '[{"line_no":1,"item_id":"e1340000-0000-4000-8000-0000000000e5","qty_units":2}]'::jsonb, null, null, false);
set constraints all immediate;
select ok((select (v ->> 'ok')::boolean from _t where k = 'ocr') and (select count(*) = 1 from public.transactions t where t.ocr_raw ->> 'draft_id' = pg_temp.id('d9')::text and t.status <> 'void')
      and (select count(*) = 0 from public.transactions t where t.external_ref like 'stock:draft:' || pg_temp.id('d9')::text || '%')
      and (select count(*) = 1 and bool_and(p.transaction_id = (select t.id from public.transactions t where t.ocr_raw ->> 'draft_id' = pg_temp.id('d9')::text)) from public.inventory_purchases p where p.expense_group = 'draft:' || pg_temp.id('d9')::text),
  'T6: an OCR confirm gives exactly ONE row (the OCR one, pending, source ocr), the purchases are linked to it and no stock: row exists');

-- =============================================================================================================================================
-- T7 apply_inventory_purchase with p_txn_id: linked, no new row. A note with a malformed uuid falls back to p:<id> and the insert still succeeds (S13).
-- =============================================================================================================================================
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes)
values (pg_temp.id('cb'), pg_temp.id('b2'), 'expense', 'other', 'pending_review', 'ocr', public.manila_today(), 20, 'Zz S134 telegram ocr row');
set constraints all deferred;
insert into _t select 'apply', public.apply_inventory_purchase(pg_temp.id('e5'), 2, 10, 'Zz S134 Shop', null, pg_temp.id('cb'), null);
insert into public.inventory_purchases(id, item_id, qty, unit_cost, notes) values (pg_temp.id('f1'), pg_temp.id('e5'), 1, 10, 'Zz S134 odd (txn not-a-uuid)');
set constraints all immediate;
select ok((select (v ->> 'ok')::boolean from _t where k = 'apply') and (select count(*) = 1 and bool_and(p.transaction_id = pg_temp.id('cb') and p.expense_group = 'txn:' || pg_temp.id('cb')::text) from public.inventory_purchases p where p.notes like '%(txn ' || pg_temp.id('cb')::text || ')%')
      and pg_temp.nrows('txn:' || pg_temp.id('cb')::text) = 0,
  'T7: apply_inventory_purchase with a transaction id links the purchase to that row and creates no stock row');
select ok((select p.expense_group = 'p:' || pg_temp.id('f1')::text and p.transaction_id is not null from public.inventory_purchases p where p.id = pg_temp.id('f1')) and pg_temp.nrows('p:' || pg_temp.id('f1')::text) = 1,
  'T7: a note with a malformed uuid falls back to the group p:<purchase id>, the insert succeeds and the purchase gets its one row');

-- =============================================================================================================================================
-- T8 undo: a full undo of an auto row voids it; a partial undo of a 3-line auto row makes the amount follow (S1)
-- =============================================================================================================================================
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'u1', public.record_inventory_receipt_v1(pg_temp.id('e1'), 2, 15, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00008');
insert into _t select 'u3', public.inventory_receipt_lines_v1(pg_temp.id('e2'), jsonb_build_array(jsonb_build_object('packs', 1), jsonb_build_object('packs', 1), jsonb_build_object('packs', 1)), 120, public.manila_today(), null, 'zz-s134-rcpt-key-008b');
set constraints all immediate;
reset role;
select ok(pg_temp.nrows('rcpt:zz-s134-adm-key-00008') = 1 and pg_temp.nrows('rcpt:zz-s134-rcpt-key-008b') = 1 and (select t.gross_amount = 120 and t.status = 'confirmed' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-rcpt-key-008b')), 'T8 setup: two auto rows, 30 and 120');
insert into _t select 'pid1', jsonb_build_object('id', (select p.id from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-adm-key-00008'));
insert into _t select 'pid3', jsonb_build_object('id', (select p.id from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-rcpt-key-008b' order by p.id limit 1));
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'undo1', public.inventory_undo_v1(null, (select (v ->> 'id')::uuid from _t where k = 'pid1'));
insert into _t select 'undo3', public.inventory_undo_v1(null, (select (v ->> 'id')::uuid from _t where k = 'pid3'));
set constraints all immediate;
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'undo1') and pg_temp.nrows('rcpt:zz-s134-adm-key-00008') = 0 and (select t.status = 'void' and t.notes like 'Stock bought: Zz S134 Rice%' and t.notes like '%[voided: stock receipt undone]' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00008')),
  'T8: a full undo of an auto row voids it; the original note stays, the marker is appended');
select ok((select (v ->> 'ok')::boolean from _t where k = 'undo3') and pg_temp.nrows('rcpt:zz-s134-rcpt-key-008b') = 1 and (select t.gross_amount = 80 and t.status = 'confirmed' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-rcpt-key-008b')),
  'T8b: a partial undo of a 3-line auto row: the amount follows the purchases left (80) and the row stays confirmed');

-- =============================================================================================================================================
-- T9 look-alike at read time, both directions, confirmed rows included (S2); T9b the create RPCs return it
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'scr9', public.expenses_screen_v1(pg_temp.id('b1'));
reset role;
select ok((select r ->> 'lookalike_id' = pg_temp.id('ca')::text and r ->> 'chip' = 'stock' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr9' and (r ->> 'id')::uuid = pg_temp.tid('rcpt:zz-s134-adm-key-00002')),
  'T9: the stock row (pending) points at the nearby manual supplies expense');
select ok((select r ->> 'lookalike_id' = pg_temp.tid('rcpt:zz-s134-adm-key-00002')::text and r ->> 'chip' = 'manual' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr9' and (r ->> 'id')::uuid = pg_temp.id('ca')),
  'T9: and the confirmed manual expense points back at the stock row (the nearest amount wins)');
select ok((select r ->> 'lookalike_id' is null from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr9' and (r ->> 'id')::uuid = pg_temp.id('c1')), 'T9: an unrelated row (category other) has no look-alike');
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'v2a', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'supplies', 'gross_amount', 55, 'transaction_date', public.manila_today(), 'notes', 'Zz S134 v2 create'), 'zz-s134-save-key-00001');
select pg_temp.as_service();
insert into _t select 'tga', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 66, 'category', 'supplies', 'notes', 'Zz S134 tg create'), 'tg:zz-s134-tg-key-000001');
reset role;
select ok((select (v ->> 'ok')::boolean and v -> 'lookalike' ->> 'id' is not null from _t where k = 'v2a') and (select (v ->> 'ok')::boolean and v -> 'lookalike' ->> 'id' is not null from _t where k = 'tga'),
  'T9b: admin_save_transaction_v2 and telegram_expense_save_v1 both return lookalike on create');

-- T8c a row a person approved: a later change of its stock leaves the amount and opens a follow-up task (S1)
update public.transactions set status = 'confirmed' where id = pg_temp.tid('rcpt:zz-s134-adm-key-00002');
set constraints all deferred;
update public.inventory_purchases set qty = qty + 1 where expense_group = 'rcpt:zz-s134-adm-key-00002';
set constraints all immediate;
select ok((select t.gross_amount = 40 and t.status = 'confirmed' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00002')) and pg_temp.tasks(pg_temp.id('b1')) = 1
      and (select count(*) = 1 from public.follow_up_tasks t where t.source_kind = 'stock_expense_sync' and t.source_ref = 'changed:rcpt:zz-s134-adm-key-00002' and t.status = 'open'),
  'T8c: a stock row a person approved keeps its amount when its purchase changes; one follow-up task is opened');

-- =============================================================================================================================================
-- Fix round 1, stock sync (review items 5-9, 13): an auto row that turns incomplete goes back to review (7); a person may change only category and note on a sync-owned row (13) and the sync keeps
-- their note; the real invariant per receipt group (6); the ownership rule is inside the UPDATE and the void (5); one task per event kind (9).
-- =============================================================================================================================================
-- (7) an auto-confirmed row; then a second, unpriced line joins the same receipt
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'fx7', public.record_inventory_receipt_v1(pg_temp.id('e4'), 1, 10, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00031');
reset role;
set constraints all immediate;
insert into _t select 'fx7a', jsonb_build_object('auto', (select t.status = 'confirmed' and t.ocr_raw ->> 's134_auto' = 'true' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00031')));
set constraints all deferred;
insert into public.inventory_purchases(item_id, qty, unit_cost, notes) values (pg_temp.id('e3'), 1, null, 'Admin receipt [key:zz-s134-adm-key-00031:g2] extra line with no price');
set constraints all immediate;
select ok((select (v ->> 'auto')::boolean from _t where k = 'fx7a') and pg_temp.nrows('rcpt:zz-s134-adm-key-00031') = 1
      and (select t.status = 'pending_review' and t.ocr_raw ->> 's134_auto' = 'false' and t.gross_amount = 10 and t.notes like 'Stock bought: Zz S134 Sugar%' and t.notes not like '%amount incomplete%' and t.ocr_raw ->> 's134_incomplete' = 'true'
             from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00031')),
  'fix 7: an auto-confirmed row whose receipt gains an unpriced line goes back to pending_review (s134_auto false, still P10, ocr_raw.s134_incomplete true, note text untouched) and stays ONE row');

-- fix round 2 (item 4): the incomplete marker is ocr_raw.s134_incomplete, set on every pass; the screen returns it; a priced line clears it and the row is not re-confirmed
insert into _t select 'fx7p', jsonb_build_object('p', (select t.property_id from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00031')));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'fx7s', public.expenses_screen_v1((select (v ->> 'p')::uuid from _t where k = 'fx7p'));
reset role;
select ok((select (r ->> 's134_incomplete')::boolean from _t x, jsonb_array_elements(x.v -> 'rows') r where x.k = 'fx7s' and r ->> 'id' = pg_temp.tid('rcpt:zz-s134-adm-key-00031')::text),
  'fix r2: expenses_screen_v1 returns s134_incomplete = true on the pending row that turned incomplete');
set constraints all deferred;
update public.inventory_purchases set unit_cost = 4 where expense_group = 'rcpt:zz-s134-adm-key-00031' and unit_cost is null;
set constraints all immediate;
select ok((select t.ocr_raw ->> 's134_incomplete' = 'false' and t.gross_amount = 14 and t.status = 'pending_review' and t.ocr_raw ->> 's134_auto' = 'false' and t.notes not like '%amount incomplete%'
             from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00031')) and pg_temp.nrows('rcpt:zz-s134-adm-key-00031') = 1,
  'fix r2: when the receipt becomes complete again the marker is cleared (false), the amount follows (P14), the row stays pending_review and is not re-confirmed');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'fx7t', public.expenses_screen_v1((select (v ->> 'p')::uuid from _t where k = 'fx7p'));
reset role;
select ok((select not (r ->> 's134_incomplete')::boolean from _t x, jsonb_array_elements(x.v -> 'rows') r where x.k = 'fx7t' and r ->> 'id' = pg_temp.tid('rcpt:zz-s134-adm-key-00031')::text),
  'fix r2: expenses_screen_v1 returns s134_incomplete = false once the receipt is complete');

-- (13) a second auto row: the person edits category and note; date and payee are refused; the purchases still move the amount and the note is kept
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'fx13', public.record_inventory_receipt_v1(pg_temp.id('e5'), 2, 10, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00032');
reset role;
set constraints all immediate;
insert into _t select 'fx13id', jsonb_build_object('id', pg_temp.tid('rcpt:zz-s134-adm-key-00032'));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'fx13a', public.admin_save_transaction_v2(pg_temp.id('b2'), jsonb_build_object('id', (select v ->> 'id' from _t where k = 'fx13id'), 'category', 'maintenance', 'notes', 'Zz S134 my own note', 'reason', 'tidy'), null);
insert into _t select 'fx13d', public.admin_save_transaction_v2(pg_temp.id('b2'), jsonb_build_object('id', (select v ->> 'id' from _t where k = 'fx13id'), 'transaction_date', public.manila_today() - 1, 'reason', 'move it'), null);
insert into _t select 'fx13p', public.admin_save_transaction_v2(pg_temp.id('b2'), jsonb_build_object('id', (select v ->> 'id' from _t where k = 'fx13id'), 'payee_name', 'Someone else', 'reason', 'rename it'), null);
reset role;
set constraints all deferred;
update public.inventory_purchases set qty = qty + 1 where expense_group = 'rcpt:zz-s134-adm-key-00032';
set constraints all immediate;
select ok((select (v ->> 'ok')::boolean from _t where k = 'fx13a') and (select v ->> 'error' = 'amount_locked' and v ->> 'where' = 'Inventory' from _t where k = 'fx13d')
      and (select v ->> 'error' = 'amount_locked' and v ->> 'where' = 'Inventory' from _t where k = 'fx13p'),
  'fix 13: on a sync-owned row with linked purchases a person can change category and note; a date or payee change is refused (amount_locked, where Inventory)');
select ok(pg_temp.nrows('rcpt:zz-s134-adm-key-00032') = 1
      and (select t.gross_amount = 30 and t.status = 'confirmed' and t.notes = 'Zz S134 my own note' and t.category = 'maintenance' and t.payee_name = 'Zz S134 Shop'
             from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00032')),
  'fix 13: a later change of the purchases still moves the amount (P30), date and payee, and the sync keeps the note and the category the person set');

-- (6) the real invariant, per receipt group: at most one live row among the purchases links and the stock:<group> row; exactly one for a priced group made after the cut-over
select ok((with g as (
              select p.expense_group grp, min(p.created_at) first_at,
                     (bool_or(p.unit_cost > 0) or exists (select 1 from public.inventory_receipt_drafts d where p.expense_group = 'draft:' || d.id::text and d.total > 0)) priced
                from public.inventory_purchases p where p.expense_group is not null group by p.expense_group),
            live as (
              select p.expense_group grp, t.id from public.inventory_purchases p join public.transactions t on t.id = p.transaction_id and t.status <> 'void' where p.expense_group is not null
              union
              select g.grp, t.id from g join public.transactions t on t.external_ref = 'stock:' || g.grp and t.status <> 'void')
           select not exists (select 1 from live group by grp having count(distinct id) > 1)
              and not exists (select 1 from g where g.priced and g.first_at >= (select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from')
                                and not exists (select 1 from live l where l.grp = g.grp)
                                and not exists (select 1 from public.inventory_purchases p2 join public.transactions v on (v.id = p2.transaction_id or v.external_ref = 'stock:' || p2.expense_group) and v.status = 'void' and coalesce(v.notes, '') not like '%[voided: stock receipt%'
                                                 where p2.expense_group = g.grp))),
  'fix 6: per receipt group, at most one live row (purchase links + stock:<group>) and exactly one for every priced group made after the cut-over');

-- (5, 9) the ownership rule inside the write. A pending stock row in the other house; then a person approves and edits it; the next sync is made to read it as still owned (a stale read), and its UPDATE refuses.
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'fx5', public.record_inventory_receipt_v1(pg_temp.id('a3'), 1, 8, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00033');
insert into _t select 'fx5b', public.record_inventory_receipt_v1(pg_temp.id('a1'), 1, 9, 'Zz S134 Shop', null, null, null, 'zz-s134-adm-key-00034');
reset role;
set constraints all immediate;
insert into _t select 'owned_def', to_jsonb(pg_get_functiondef('public.s_stock_expense_owned_v1(uuid)'::regprocedure));
update public.transactions set status = 'confirmed', gross_amount = 99, ocr_raw = ocr_raw || '{"s134_auto": false}'::jsonb where id = pg_temp.tid('rcpt:zz-s134-adm-key-00033');
create or replace function public.s_stock_expense_owned_v1(p_id uuid) returns boolean language sql stable security definer set search_path = '' as 'select true';
set constraints all deferred;
update public.inventory_purchases set qty = qty + 1 where expense_group = 'rcpt:zz-s134-adm-key-00033';
set constraints all immediate;
select ok((select t.gross_amount = 99 and t.status = 'confirmed' and (t.ocr_raw ->> 's134_amount')::numeric = 8 from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00033'))
      and (select count(*) = 1 from public.follow_up_tasks t where t.source_kind = 'stock_expense_sync' and t.source_ref = 'changed:rcpt:zz-s134-adm-key-00033' and t.status = 'open'),
  'fix 5: when the sync read the row as owned but a person had already approved and edited it, the UPDATE (ownership in its WHERE) changes nothing and a "changed:" task opens');
select ok(public.s_txn_void_core_v1(pg_temp.tid('rcpt:zz-s134-adm-key-00033'), 'guard test', null, true) is false
      and (select t.status = 'confirmed' and t.notes not like '%voided%' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00033')),
  'fix 5: the guarded void (ownership in its WHERE) leaves an approved row alone and answers false');
do $r$ begin execute (select v #>> '{}' from _t where k = 'owned_def'); end $r$;
select ok((select p.prosrc like '%s134_auto%' from pg_proc p where p.oid = 'public.s_stock_expense_owned_v1(uuid)'::regprocedure)
      and public.s_stock_expense_owned_v1(pg_temp.tid('rcpt:zz-s134-adm-key-00033')) is false and public.s_stock_expense_owned_v1(pg_temp.tid('rcpt:zz-s134-adm-key-00034')) is true,
  'fix 5: the real ownership function is back (an approved, edited row is not owned; a pending sync row is)');
-- an undo after the person took the row opens a different task (kind "undone:"), the earlier "changed:" task stays: two events, two tasks
set constraints all deferred;
delete from public.inventory_purchases where expense_group = 'rcpt:zz-s134-adm-key-00033';
set constraints all immediate;
select ok((select count(*) = 2 and count(distinct t.source_ref) = 2 and bool_and(t.status = 'open') from public.follow_up_tasks t
            where t.source_kind = 'stock_expense_sync' and t.source_ref in ('changed:rcpt:zz-s134-adm-key-00033', 'undone:rcpt:zz-s134-adm-key-00033'))
      and (select t.status = 'confirmed' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00033')),
  'fix 9: a later problem of another kind on the same receipt is its own task (changed: and undone:), the approved row stays confirmed');
-- the guarded void of a row that is still the sync own does void it
insert into _t select 'gv', to_jsonb(public.s_txn_void_core_v1(pg_temp.tid('rcpt:zz-s134-adm-key-00034'), 'guard test', null, true));
select ok((select (v #>> '{}')::boolean from _t where k = 'gv')
      and (select t.status = 'void' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00034')),
  'fix 5: the guarded void of a pending sync row voids it');

-- =============================================================================================================================================
-- T10 admin_save_transaction_v2 refusals (business refusals answer {ok:false,error}; locked rows and void rows are never touched)
-- =============================================================================================================================================
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, external_ref) values
  (pg_temp.id('cc'), pg_temp.id('b1'), 'expense', 'utilities', 'confirmed', 'bill', public.manila_today(), 300, 'Zz S134 bill row', 'bill:electric:2026-11'),
  (pg_temp.id('cd'), pg_temp.id('b1'), 'expense', 'cleaning', 'confirmed', 'cleaner_fee', public.manila_today(), 250, 'Zz S134 staff pay row', null),
  (pg_temp.id('ce'), pg_temp.id('b1'), 'expense', 'guest_refund', 'confirmed', 'refund', public.manila_today(), 100, 'Zz S134 refund row', null);
insert into _t select 'stk1', jsonb_build_object('id', pg_temp.tid('rcpt:zz-s134-adm-key-00001'));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'x_cat', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'zz_nope', 'gross_amount', 10, 'transaction_date', public.manila_today()), 'zz-s134-save-key-10001');
insert into _t select 'x_sys1', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'guest_refund', 'gross_amount', 10, 'transaction_date', public.manila_today()), 'zz-s134-save-key-10002');
insert into _t select 'x_sys2', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'airbnb_adjustment', 'gross_amount', 10, 'transaction_date', public.manila_today()), 'zz-s134-save-key-10003');
insert into _t select 'x_amt', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'other', 'gross_amount', 0, 'transaction_date', public.manila_today()), 'zz-s134-save-key-10004');
insert into _t select 'x_fut', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'other', 'gross_amount', 10, 'transaction_date', public.manila_today() + 10), 'zz-s134-save-key-10005');
insert into _t select 'x_bill', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('cc'), 'gross_amount', 1, 'reason', 'fix it'), null);
insert into _t select 'x_pay', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('cd'), 'gross_amount', 1, 'reason', 'fix it'), null);
insert into _t select 'x_ref', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('ce'), 'transaction_date', public.manila_today() - 1, 'reason', 'fix it'), null);
insert into _t select 'x_stat', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('cc'), 'status', 'pending_review', 'reason', 'fix it'), null);
insert into _t select 'x_stk', public.admin_save_transaction_v2(pg_temp.id('b2'), jsonb_build_object('id', (select v ->> 'id' from _t where k = 'stk1'), 'gross_amount', 99, 'reason', 'fix it'), null);
insert into _t select 'x_void', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('c3'), 'notes', 'revive', 'reason', 'fix it'), null);
insert into _t select 'x_rsn', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('c1'), 'notes', 'no reason'), null);
insert into _t select 'x_type', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('c1'), 'txn_type', 'income', 'reason', 'fix it'), null);
insert into _t select 'x_nf', public.admin_save_transaction_v2(pg_temp.id('b2'), jsonb_build_object('id', pg_temp.id('c1'), 'notes', 'x', 'reason', 'fix it'), null);
insert into _t select 'x_ok', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('c1'), 'category', 'supplies', 'notes', 'Zz S134 edited', 'reason', 'recategorised'), null);
insert into _t select 'v2a2', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'supplies', 'gross_amount', 55, 'transaction_date', public.manila_today(), 'notes', 'Zz S134 v2 create'), 'zz-s134-save-key-00001');
reset role;
select ok((select v ->> 'error' = 'bad_category' from _t where k = 'x_cat') and (select v ->> 'error' = 'system_category' from _t where k = 'x_sys1') and (select v ->> 'error' = 'system_category' from _t where k = 'x_sys2')
      and (select v ->> 'error' = 'bad_amount' from _t where k = 'x_amt') and (select v ->> 'error' = 'future_date' from _t where k = 'x_fut'), 'T10: unknown category, both system slugs, amount 0 and a future date are refused on create');
select ok((select v ->> 'error' = 'locked' and v ->> 'where' = 'Bills' from _t where k = 'x_bill') and (select v ->> 'error' = 'locked' and v ->> 'where' = 'Pay staff' from _t where k = 'x_pay')
      and (select v ->> 'error' = 'locked' from _t where k = 'x_ref') and (select v ->> 'error' = 'locked' from _t where k = 'x_stat')
      and (select t.gross_amount = 300 and t.status = 'confirmed' from public.transactions t where t.id = pg_temp.id('cc')) and (select t.gross_amount = 250 from public.transactions t where t.id = pg_temp.id('cd'))
      and (select t.transaction_date = public.manila_today() from public.transactions t where t.id = pg_temp.id('ce')), 'T10: a bill, a staff pay and a refund row refuse an amount, date or status edit (locked, with where) and are unchanged');
select ok((select v ->> 'error' = 'amount_locked' and v ->> 'where' = 'Inventory' from _t where k = 'x_stk') and (select t.gross_amount = 60 from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-adm-key-00001')),
  'T10: the amount of a sync-owned stock row with linked purchases cannot be edited (S15)');
select ok((select v ->> 'error' = 'void' from _t where k = 'x_void') and (select t.status = 'void' and t.notes = 'Zz S134 void' from public.transactions t where t.id = pg_temp.id('c3')), 'T10: a void row cannot be edited or revived');
select ok((select v ->> 'error' = 'reason_required' from _t where k = 'x_rsn') and (select v ->> 'error' = 'type_locked' from _t where k = 'x_type') and (select v ->> 'error' = 'not_found' from _t where k = 'x_nf'),
  'T10: an edit needs a reason, cannot change the type, and cannot reach a row of another house');
select ok((select (v ->> 'ok')::boolean from _t where k = 'x_ok') and (select t.category = 'supplies' and t.notes = 'Zz S134 edited' and t.gross_amount = 100 from public.transactions t where t.id = pg_temp.id('c1'))
      and (select count(*) >= 1 from public.admin_audit_log a where a.entity_id = pg_temp.id('c1') and a.reason = 'recategorised'), 'T10: a plain edit works and is audited with its reason');
select ok((select (v ->> 'replayed')::boolean and v ->> 'id' = (select v ->> 'id' from _t where k = 'v2a') from _t where k = 'v2a2'),
  'T10: the same key again replays the same row');

-- =============================================================================================================================================
-- T11 expense_void_v1
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'vd1', public.expense_void_v1(pg_temp.id('b1'), pg_temp.id('c5'), 'duplicate entry', null);
insert into _t select 'vd2', public.expense_void_v1(pg_temp.id('b1'), pg_temp.id('c5'), 'again please', null);
insert into _t select 'vd3', public.expense_void_v1(pg_temp.id('b1'), pg_temp.id('cc'), 'it is a bill', null);
insert into _t select 'vd4', public.expense_void_v1(pg_temp.id('b1'), pg_temp.id('ca'), 'x', null);
insert into _t select 'vd5', public.expense_void_v1(pg_temp.id('b2'), (select (v ->> 'id')::uuid from _t where k = 'stk1'), 'same as the OCR row', pg_temp.id('cb'));
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'vd1') and (select t.status = 'void' and t.notes = 'Zz S134 hidden still counts [voided: duplicate entry]' from public.transactions t where t.id = pg_temp.id('c5'))
      and (select v ->> 'error' = 'void' from _t where k = 'vd2') and (select v ->> 'error' = 'reason_required' from _t where k = 'vd4'), 'T11: a void keeps the note and appends the reason; void again and a one-letter reason are refused');
select ok((select v ->> 'error' = 'locked' and v ->> 'where' = 'Bills' from _t where k = 'vd3') and (select t.status = 'confirmed' from public.transactions t where t.id = pg_temp.id('cc')), 'T11: a bill row cannot be voided here (locked, where Bills)');
select ok((select (v ->> 'ok')::boolean from _t where k = 'vd5') and (select t.status = 'void' and t.notes like '%[voided: duplicate of ' || left(pg_temp.id('cb')::text, 8) || ']' from public.transactions t where t.id = (select id from public.transactions where external_ref = 'stock:rcpt:zz-s134-adm-key-00001'))
      and (select count(*) = 1 and bool_and(p.transaction_id = pg_temp.id('cb')) from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-adm-key-00001'),
  'T11: voiding as "same as" another row moves the purchases to it and names it in the marker (S19)');
set constraints all deferred;
update public.inventory_purchases set qty = qty + 1 where expense_group = 'rcpt:zz-s134-adm-key-00001';
set constraints all immediate;
select ok(pg_temp.nrows('rcpt:zz-s134-adm-key-00001') = 0 and (select t.gross_amount = 20 from public.transactions t where t.id = pg_temp.id('cb')) and (select count(*) = 1 from public.transactions t where t.external_ref = 'stock:rcpt:zz-s134-adm-key-00001'),
  'T11: a later change of those purchases creates no new row and does not touch the row they now belong to');

-- =============================================================================================================================================
-- T13 Telegram RPCs (service_role only)
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'tg_auth', pg_temp.try(format('select public.telegram_expense_save_v1(%L::uuid, %L::jsonb, %L)', pg_temp.id('b1'), '{"amount":5}', 'tg:zz-s134-tg-key-000009'));
select pg_temp.as_service();
insert into _t select 'tg_rep', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 66, 'category', 'supplies', 'notes', 'Zz S134 tg create'), 'tg:zz-s134-tg-key-000001');
insert into _t select 'tg_p1', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 120, 'category', 'other', 'status', 'pending_review', 'notes', 'Zz S134 tg pending'), 'tg:zz-s134-tg-key-000002');
insert into _t select 'tg_bad', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 120, 'category', 'guest_refund'), 'tg:zz-s134-tg-key-000003');
insert into _t select 'tg_amt', public.telegram_expense_review_v1((select (v ->> 'id')::uuid from _t where k = 'tg_p1'), 'amount', '{"amount":130}'::jsonb, 'Cassy');
insert into _t select 'tg_conf', public.telegram_expense_review_v1((select (v ->> 'id')::uuid from _t where k = 'tg_p1'), 'confirm', '{}'::jsonb, 'Cassy');
insert into _t select 'tg_amt2', public.telegram_expense_review_v1((select (v ->> 'id')::uuid from _t where k = 'tg_p1'), 'amount', '{"amount":140}'::jsonb, 'Cassy');
insert into _t select 'tg_void', public.telegram_expense_review_v1((select (v ->> 'id')::uuid from _t where k = 'tga'), 'void', '{"reason":"wrong receipt"}'::jsonb, 'Cassy');
insert into _t select 'tg_lock', public.telegram_expense_review_v1(pg_temp.id('cc'), 'void', '{}'::jsonb, 'Cassy');
insert into _t select 'tg_lock2', public.telegram_expense_review_v1(pg_temp.id('cd'), 'confirm', '{}'::jsonb, 'Cassy');
reset role;
select ok((select v ->> 'err' = '42501' from _t where k = 'tg_auth'), 'T13: a signed-in staff user cannot call the Telegram save (42501)');
select ok((select (v ->> 'replayed')::boolean and v ->> 'id' = (select v ->> 'id' from _t where k = 'tga') from _t where k = 'tg_rep') and (select t.transaction_date = public.manila_today() and t.source = 'telegram' and t.logged_by = 'telegram' and t.external_ref = 'tg:zz-s134-tg-key-000001' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'tga')),
  'T13: the same key replays the same row; the date is the Manila day; the row is a telegram row');
select ok((select v ->> 'error' = 'bad_category' from _t where k = 'tg_bad') and (select (v ->> 'ok')::boolean and (v ->> 'amount')::numeric = 130 from _t where k = 'tg_amt') and (select (v ->> 'ok')::boolean and v ->> 'status' = 'confirmed' from _t where k = 'tg_conf')
      and (select v ->> 'error' = 'not_pending' from _t where k = 'tg_amt2') and (select t.gross_amount = 130 from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'tg_p1')),
  'T13: a system category is refused; the amount can be corrected while pending and not after the row is confirmed');
select ok((select (v ->> 'ok')::boolean from _t where k = 'tg_void') and (select t.status = 'void' and t.notes = 'Zz S134 tg create [voided: wrong receipt]' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'tga')),
  'T13: a void from Telegram keeps the note and appends the reason');
select ok((select v ->> 'error' = 'locked' and v ->> 'where' = 'bills' from _t where k = 'tg_lock') and (select v ->> 'error' = 'locked' and v ->> 'where' = 'pay' from _t where k = 'tg_lock2') and (select t.status = 'confirmed' from public.transactions t where t.id = pg_temp.id('cc')),
  'T13: a bill row and a staff pay row are refused (locked) and unchanged');

-- =============================================================================================================================================
-- T14 gates: only owner / admin / finance read the screen and the receipt paths
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('04'));
insert into _t select 'g_cl', public.expenses_screen_v1(pg_temp.id('b1'));
insert into _t select 'gp_cl', public.expense_receipt_paths_v1(pg_temp.id('b1'), array[pg_temp.id('c1')]);
select pg_temp.as_user(pg_temp.id('05'));
insert into _t select 'g_in', public.expenses_screen_v1(pg_temp.id('b1'));
select pg_temp.as_user(pg_temp.id('06'));
insert into _t select 'g_mt', public.expenses_screen_v1(pg_temp.id('b1'));
select pg_temp.as_user(pg_temp.id('07'));
insert into _t select 'g_ln', public.expenses_screen_v1(pg_temp.id('b1'));
insert into _t select 'gp_ln', public.expense_receipt_paths_v1(pg_temp.id('b1'), array[pg_temp.id('c1')]);
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'g_fin', public.expenses_screen_v1(pg_temp.id('b1'));
insert into _t select 'g_fin2', public.expenses_screen_v1('e1340000-0000-4000-8000-0000000000ff'::uuid);
insert into _t select 'gp_fin', public.expense_receipt_paths_v1(pg_temp.id('b1'), array[pg_temp.id('c1')]);
select pg_temp.as_user(pg_temp.id('02'));
insert into _t select 'g_adm', public.expenses_screen_v1(pg_temp.id('b1'));
select pg_temp.as_user(pg_temp.id('04'));
insert into _t select 'gs_cl', pg_temp.try(format('select public.expense_receipt_set_v1(%L::uuid, %L::uuid, null, %L)', pg_temp.id('b1'), pg_temp.id('c1'), 'remove it'));
insert into _t select 'gv_cl', pg_temp.try(format('select public.expense_void_v1(%L::uuid, %L::uuid, %L, null)', pg_temp.id('b1'), pg_temp.id('c1'), 'nope nope'));
insert into _t select 'gw_cl', pg_temp.try(format('select public.admin_save_transaction_v2(%L::uuid, %L::jsonb, null)', pg_temp.id('b1'), '{"txn_type":"expense","category":"other","gross_amount":5}'));
reset role;
select ok((select bool_and(v ->> 'error' = 'forbidden' and (v ->> 'ok')::boolean is false) from _t where k in ('g_cl', 'g_in', 'g_mt', 'g_ln', 'g_fin2')), 'T14: cleaner, inspector, maintenance and laundry get forbidden from the screen (and so does finance on a house it does not hold)');
select ok((select v = '[]'::jsonb from _t where k = 'gp_cl') and (select v = '[]'::jsonb from _t where k = 'gp_ln'), 'T14: receipt paths for a cleaner and a laundry user are an empty list');
select ok((select (v ->> 'ok')::boolean from _t where k = 'g_fin') and (select (v ->> 'ok')::boolean from _t where k = 'g_adm') and (select jsonb_typeof(v) = 'array' from _t where k = 'gp_fin'), 'T14: finance and admin get the screen and the paths call answers a list');
select ok((select bool_and(v ->> 'err' = '42501') from _t where k in ('gs_cl', 'gv_cl', 'gw_cl')), 'T14: a cleaner calling the receipt control, the void or the save gets 42501');

-- =============================================================================================================================================
-- T15 KPI: a cleaner session still gets a payload (no admin key); a month before the cut-over reads the legacy figures; the cut-over month reads the ledger
-- =============================================================================================================================================
insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount) values
  (pg_temp.id('b1'), pg_temp.id('04'), 'Zz S134 Cleaner', 'zz-s134-pay-0001', 'requested', '[{"x":1}]'::jsonb, 175);
insert into public.inventory_purchases(id, item_id, qty, unit_cost, purchased_at, notes) values
  (pg_temp.id('f2'), pg_temp.id('a2'), 2, 20, (date_trunc('month', public.manila_today()) - interval '1 month')::date + 10, 'Zz S134 last month');
select pg_temp.as_user(pg_temp.id('04'));
insert into _t select 'k_cl', public.kpi_tab_v1(pg_temp.id('b1'));
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'k_now', public.kpi_tab_v1(pg_temp.id('b1'));
insert into _t select 'k_prev', public.kpi_tab_v1(pg_temp.id('b1'), (date_trunc('month', public.manila_today()) - interval '1 month')::date);
reset role;
select ok((select (v ->> 'ok')::boolean and v is not null and not (v ? 'admin') from _t where k = 'k_cl'), 'T15: a cleaner session gets ok:true and a payload with no admin key (the patch sits inside the finance branch)');
select ok((select v -> 'admin' ->> 'kpi_source' = 'ledger' and (v -> 'admin' ->> 'cleaning_pay_month')::numeric = 250 and (v -> 'admin' ->> 'cleaning_pay_open')::numeric = 175
             and (v -> 'admin' ->> 'supplies_month')::numeric = (select coalesce(sum(t.gross_amount), 0) from public.transactions t where t.property_id = pg_temp.id('b1') and t.txn_type = 'expense' and t.status = 'confirmed' and t.category = 'supplies'
                                                                   and t.source not in ('airbnb', 'airbnb_email') and t.transaction_date >= date_trunc('month', public.manila_today())::date and t.transaction_date < (date_trunc('month', public.manila_today()) + interval '1 month')::date)
        from _t where k = 'k_now'), 'T15: the cut-over month reads Supplies bought and Cleaning pay from the ledger; cleaning_pay_open counts the open pay request');
select ok((select v -> 'admin' ->> 'kpi_source' = 'legacy' and (v -> 'admin' ->> 'supplies_month')::numeric = 40 and (v -> 'admin' ->> 'cleaning_pay_month')::numeric = 0 from _t where k = 'k_prev'), 'T15: a month before the cut-over keeps the legacy figures (purchases 2 x 20 = 40) and says kpi_source legacy (S7)');
update public.app_settings set value = to_jsonb((date_trunc('month', public.manila_today()) + interval '1 month 5 days')) where key = 's134_stock_expense_from';
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'k_leg', public.kpi_tab_v1(pg_temp.id('b1'));
reset role;
select ok((select v -> 'admin' ->> 'kpi_source' = 'legacy' and (v -> 'admin' ->> 'cleaning_pay_month')::numeric = 175 from _t where k = 'k_leg'), 'T15: with the cut-over moved to next month the current month reads the legacy figures (cleaning pay = the pay request, 175)');
update public.app_settings set value = to_jsonb(now()) where key = 's134_stock_expense_from';

-- =============================================================================================================================================
-- T17 a forced sync error leaves the stock write committed and opens the task; a forced error inside the task call still leaves it committed (S13)
-- =============================================================================================================================================
create function public.zz_s134_boom() returns trigger language plpgsql as $$ begin raise exception 'zz s134 boom'; end $$;
create trigger zz_s134_boom_txn before insert on public.transactions for each row when (new.source = 'inventory') execute function public.zz_s134_boom();
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'f1', pg_temp.try(format('select public.record_inventory_receipt_v1(%L::uuid, 1, 10, %L, null, null, null, %L)', pg_temp.id('e4'), 'Zz S134 Shop', 'zz-s134-adm-key-00017'));
set constraints all immediate;
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'f1') and exists (select 1 from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-adm-key-00017') and pg_temp.nrows('rcpt:zz-s134-adm-key-00017') = 0
      and pg_temp.tasks(pg_temp.id('b2')) = 1, 'T17: when the ledger insert fails the stock write is kept and a follow-up task is opened');
create trigger zz_s134_boom_task before insert on public.follow_up_tasks for each row when (new.source_kind = 'stock_expense_sync') execute function public.zz_s134_boom();
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'f2', pg_temp.try(format('select public.record_inventory_receipt_v1(%L::uuid, 1, 10, %L, null, null, null, %L)', pg_temp.id('e4'), 'Zz S134 Shop', 'zz-s134-adm-key-00018'));
set constraints all immediate;
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'f2') and exists (select 1 from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-adm-key-00018') and pg_temp.nrows('rcpt:zz-s134-adm-key-00018') = 0
      and pg_temp.tasks(pg_temp.id('b2')) = 1, 'T17: when the task call fails as well the stock write is still kept (no error reaches the caller)');
drop trigger zz_s134_boom_task on public.follow_up_tasks;
drop trigger zz_s134_boom_txn on public.transactions;

-- =============================================================================================================================================
-- Fix round 1, RPC contracts (review items 1, 2, 3, 11, 12, 14): Telegram payee and key prefixes, the keyset page, kpi_ledger_from, the staff pay category lock
-- =============================================================================================================================================
-- (1, 11, 12) telegram_expense_save_v1: payee_name and payee both store the vendor; a draft_id in the client ocr_raw is dropped; only the L3 key prefixes (tg:, tgp:, tgocr:) are accepted
select pg_temp.as_service();
insert into _t select 'tp1', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 11, 'category', 'other', 'payee_name', 'Zz S134 Vendor A'), 'tg:zz-s134-tg-key-000011');
insert into _t select 'tp2', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 12, 'category', 'other', 'payee', 'Zz S134 Vendor B'), 'tgp:zz-s134-tg-key-000012');
insert into _t select 'tp3', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 13, 'category', 'other', 'payee_name', 'Zz S134 Vendor C', 'status', 'pending_review',
    'ocr_raw', jsonb_build_object('draft_id', 'zz', 'total', 13, 'keep', 1)), 'tgocr:zz-s134-obj-000013#m1');
insert into _t select 'tp4', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 14, 'category', 'other'), 'admin:zz-s134-tg-key-000014');
insert into _t select 'tp5', public.telegram_expense_save_v1(pg_temp.id('b1'), jsonb_build_object('amount', 15, 'category', 'other'), 'zz-s134-tg-key-000015');
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'tp1') and (select (v ->> 'ok')::boolean from _t where k = 'tp2') and (select (v ->> 'ok')::boolean from _t where k = 'tp3')
      and (select t.payee_name = 'Zz S134 Vendor A' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'tp1'))
      and (select t.payee_name = 'Zz S134 Vendor B' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'tp2'))
      and (select t.payee_name = 'Zz S134 Vendor C' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'tp3')),
  'fix 1/12: the Telegram save stores the vendor sent as payee_name or as payee; the keys tg:, tgp: and tgocr: are accepted');
select ok((select t.source = 'ocr' and not (t.ocr_raw ? 'draft_id') and t.ocr_raw ->> 'keep' = '1' and (t.ocr_raw ->> 'total')::numeric = 13 from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'tp3')),
  'fix 11: a draft_id in the client ocr_raw is dropped by the Telegram save, the rest of the model read is kept');
select ok((select v ->> 'error' = 'bad_request' from _t where k = 'tp4') and (select v ->> 'error' = 'bad_request' from _t where k = 'tp5')
      and not exists (select 1 from public.transactions t where t.external_ref in ('admin:zz-s134-tg-key-000014', 'zz-s134-tg-key-000015')),
  'fix 12: a key that does not start with tg:, tgp: or tgocr: is refused (bad_request) and nothing is written');

-- (2) expenses_screen_v1: three rows with one created_at across a page boundary come back exactly once (keyset on created_at, id); p_before alone keeps its old meaning
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, created_at) values
  (pg_temp.id('91'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', date '2026-03-15', 1, 'Zz S134 page 1', timestamptz '2026-03-15 10:00:00+00'),
  (pg_temp.id('92'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', date '2026-03-15', 2, 'Zz S134 page 2', timestamptz '2026-03-15 10:00:00+00'),
  (pg_temp.id('93'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', date '2026-03-15', 3, 'Zz S134 page 3', timestamptz '2026-03-15 10:00:00+00'),
  (pg_temp.id('94'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', date '2026-03-15', 4, 'Zz S134 page newest', timestamptz '2026-03-15 11:00:00+00'),
  (pg_temp.id('95'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', date '2026-03-15', 5, 'Zz S134 page oldest', timestamptz '2026-03-15 09:00:00+00');
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'pg1', public.expenses_screen_v1(pg_temp.id('b1'), date '2026-03-01', 2);
insert into _t select 'pg2', public.expenses_screen_v1(pg_temp.id('b1'), date '2026-03-01', 2, timestamptz '2026-03-15 10:00:00+00', null, pg_temp.id('93'));
insert into _t select 'pg3', public.expenses_screen_v1(pg_temp.id('b1'), date '2026-03-01', 2, timestamptz '2026-03-15 10:00:00+00', null, pg_temp.id('91'));
insert into _t select 'pg_old', public.expenses_screen_v1(pg_temp.id('b1'), date '2026-03-01', 10, timestamptz '2026-03-15 10:00:00+00');
reset role;
select ok((select (select array_agg((r.r ->> 'id')::uuid order by r.o) from jsonb_array_elements(v -> 'rows') with ordinality r(r, o)) = array[pg_temp.id('94'), pg_temp.id('93')] and (v ->> 'more')::boolean from _t where k = 'pg1')
      and (select (select array_agg((r.r ->> 'id')::uuid order by r.o) from jsonb_array_elements(v -> 'rows') with ordinality r(r, o)) = array[pg_temp.id('92'), pg_temp.id('91')] and (v ->> 'more')::boolean from _t where k = 'pg2')
      and (select (select array_agg((r.r ->> 'id')::uuid order by r.o) from jsonb_array_elements(v -> 'rows') with ordinality r(r, o)) = array[pg_temp.id('95')] and not (v ->> 'more')::boolean from _t where k = 'pg3'),
  'fix 2: three rows sharing one created_at across a page boundary: page 1 = newest + 93, page 2 (before 93) = 92 + 91, page 3 (before 91) = the oldest; each exactly once, in (created_at desc, id desc) order');
select ok((select (select array_agg((r ->> 'id')::uuid) from jsonb_array_elements(v -> 'rows') r) = array[pg_temp.id('95')] from _t where k = 'pg_old'),
  'fix 2: p_before alone still means created_at < p_before (the old callers keep working)');
select ok((select count(*) = 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'expenses_screen_v1'), 'fix 2: one signature of expenses_screen_v1 (the old one is dropped, no overload)');

-- (3) kpi_ledger_from: the Manila month of the cut-over, null when the setting is unset
insert into _t select 'cut_orig', (select to_jsonb(s.value) from public.app_settings s where s.key = 's134_stock_expense_from');
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'kl1', public.kpi_tab_v1(pg_temp.id('b1'));
reset role;
delete from public.app_settings where key = 's134_stock_expense_from';
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'kl2', public.kpi_tab_v1(pg_temp.id('b1'));
reset role;
insert into public.app_settings (key, value) select 's134_stock_expense_from', v from _t where k = 'cut_orig';
select ok((select v -> 'admin' ->> 'kpi_ledger_from' = to_char((select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from') at time zone 'Asia/Manila', 'YYYY-MM') from _t where k = 'kl1')
      and (select v -> 'admin' -> 'kpi_ledger_from' = 'null'::jsonb and v -> 'admin' ->> 'kpi_source' = 'legacy' from _t where k = 'kl2'),
  'fix 3: admin.kpi_ledger_from is the Manila month of the cut-over (YYYY-MM) and null when it is unset');

-- (14) a staff pay row keeps its category (the cleaning-pay month and the V19 reconciliation read category cleaning)
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'cp1', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('cd'), 'category', 'supplies', 'reason', 'recategorise'), null);
insert into _t select 'cp2', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('cd'), 'category', 'cleaning', 'notes', 'Zz S134 pay note', 'reason', 'note only'), null);
reset role;
select ok((select v ->> 'error' = 'locked' and v ->> 'where' = 'Pay staff' from _t where k = 'cp1') and (select (v ->> 'ok')::boolean from _t where k = 'cp2')
      and (select t.category = 'cleaning' from public.transactions t where t.id = pg_temp.id('cd')),
  'fix 14: the category of a staff pay row cannot be changed (locked, where Pay staff); a same-category edit still works');

-- =============================================================================================================================================
-- T18 receipt resolution: one fixture row per kind (txn, scanned draft, manual draft, bill, stock) and a staff pay row; the screen never carries a path
-- =============================================================================================================================================
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), 'a0', repeat('1', 64));
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, receipt_image_path) values
  (pg_temp.id('e0'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 10, 'Zz S134 kind txn', pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), 'a0'));
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes) values
  (pg_temp.id('e1'), pg_temp.id('b1'), 'expense', 'supplies', 'pending_review', 'ocr', public.manila_today() - 30, 11, 'Zz S134 kind scanned draft'),
  (pg_temp.id('e2'), pg_temp.id('b1'), 'expense', 'supplies', 'pending_review', 'inventory', public.manila_today() - 30, 12, 'Zz S134 kind manual draft'),
  (pg_temp.id('e3'), pg_temp.id('b1'), 'expense', 'utilities', 'confirmed', 'bill', public.manila_today(), 13, 'Zz S134 kind bill'),
  (pg_temp.id('e4'), pg_temp.id('b1'), 'expense', 'supplies', 'pending_review', 'inventory', public.manila_today() - 30, 14, 'Zz S134 kind stock'),
  (pg_temp.id('e5'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 15, 'Zz S134 kind none'),
  (pg_temp.id('e7'), pg_temp.id('b1'), 'expense', 'supplies', 'pending_review', 'ocr', public.manila_today() - 30, 16, 'Zz S134 kind draft without a file');
update public.transactions set external_ref = 'bill:water:2026-10' where id = pg_temp.id('e3');
insert into public.inventory_receipt_drafts(id, property_id, created_by, receipt_path, lines, status, transaction_id) values
  (pg_temp.id('d5'), pg_temp.id('b1'), pg_temp.id('01'), pg_temp.id('b1')::text || '/' || pg_temp.id('a1')::text || '/' || pg_temp.id('a2')::text || '.jpg', '[]'::jsonb, 'confirmed', pg_temp.id('e1')),
  (pg_temp.id('d6'), pg_temp.id('b1'), pg_temp.id('01'), 'items/' || pg_temp.id('a2')::text || '/' || pg_temp.id('a3')::text || '.webp', '[]'::jsonb, 'confirmed', pg_temp.id('e2')),
  (pg_temp.id('d7'), pg_temp.id('b1'), pg_temp.id('01'), pg_temp.id('b1')::text || '/' || pg_temp.id('a3')::text || '/' || pg_temp.id('a4')::text || '.jpg', '[]'::jsonb, 'confirmed', pg_temp.id('e7'));
insert into storage.objects(bucket_id, name) values
  ('expense-receipts', pg_temp.id('b1')::text || '/' || pg_temp.id('a1')::text || '/' || pg_temp.id('a2')::text || '.jpg'),
  ('inventory-photos', 'items/' || pg_temp.id('a2')::text || '/' || pg_temp.id('a3')::text || '.webp'),
  ('cleaning-photos', pg_temp.id('b1')::text || '/' || pg_temp.id('a4')::text || '/proof.jpg'),
  ('inventory-photos', 'items/' || pg_temp.id('a5')::text || '/' || pg_temp.id('a6')::text || '.webp');
insert into public.utility_bills(property_id, kind, period, status, proof_path, txn_id) values
  (pg_temp.id('b1'), 'water', '2026-10', 'due', pg_temp.id('b1')::text || '/' || pg_temp.id('a4')::text || '/proof.jpg', pg_temp.id('e3'));
insert into public.inventory_purchases(id, item_id, qty, unit_cost, receipt_path, transaction_id, notes) values
  (pg_temp.id('f3'), pg_temp.id('a1'), 1, 5, 'items/' || pg_temp.id('a5')::text || '/' || pg_temp.id('a6')::text || '.webp', pg_temp.id('e4'), 'Zz S134 stock photo');
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'scr18', public.expenses_screen_v1(pg_temp.id('b1'), (public.manila_today() - 30)::date);
insert into _t select 'scr18b', public.expenses_screen_v1(pg_temp.id('b1'));
insert into _t select 'rp18', public.expense_receipt_paths_v1(pg_temp.id('b1'), array[pg_temp.id('e0'), pg_temp.id('e1'), pg_temp.id('e2'), pg_temp.id('e3'), pg_temp.id('e4'), pg_temp.id('e5'), pg_temp.id('e7'), pg_temp.id('cd'), pg_temp.id('f3')]);
reset role;
select ok((select count(*) = 4 from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18' and r -> 'receipt_ref' ->> 'kind' in ('draft', 'stock') and (r ->> 'id')::uuid in (pg_temp.id('e1'), pg_temp.id('e2'), pg_temp.id('e4'), pg_temp.id('e7')))
      and (select r -> 'receipt_ref' ->> 'kind' = 'draft' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18' and (r ->> 'id')::uuid = pg_temp.id('e1'))
      and (select r -> 'receipt_ref' ->> 'kind' = 'draft' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18' and (r ->> 'id')::uuid = pg_temp.id('e2'))
      and (select r -> 'receipt_ref' ->> 'kind' = 'stock' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18' and (r ->> 'id')::uuid = pg_temp.id('e4')),
  'T18: the pending rows older than this month resolve to their scanned draft, manual draft, stock photo and a draft with no file');
select ok((select r -> 'receipt_ref' ->> 'kind' = 'txn' and (r ->> 'has_receipt')::boolean and r -> 'receipt_ref' ->> 'mime' = 'image/jpeg' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18b' and (r ->> 'id')::uuid = pg_temp.id('e0'))
      and (select r -> 'receipt_ref' ->> 'kind' = 'bill' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18b' and (r ->> 'id')::uuid = pg_temp.id('e3'))
      and (select not (r ->> 'has_receipt')::boolean and r -> 'receipt_ref' = 'null'::jsonb from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18b' and (r ->> 'id')::uuid = pg_temp.id('e5')),
  'T18: a row with its own receipt is kind txn, a bill row is kind bill, a row with nothing has no receipt_ref');
select ok((select not (r ->> 'has_receipt')::boolean and r -> 'receipt_can' = '{"add": false, "remove": false, "replace": false}'::jsonb and r ->> 'locked' = 'true' from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18b' and (r ->> 'id')::uuid = pg_temp.id('cd'))
      and (select (r -> 'receipt_can' ->> 'add')::boolean and not coalesce((r -> 'receipt_can' ->> 'remove')::boolean, false) and not coalesce((r -> 'receipt_can' ->> 'replace')::boolean, false) from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18b' and (r ->> 'id')::uuid = pg_temp.id('e5'))
      and (select r -> 'receipt_can' = '{"add": false, "remove": true, "replace": true}'::jsonb from _t, jsonb_array_elements(v -> 'rows') r where k = 'scr18b' and (r ->> 'id')::uuid = pg_temp.id('e0')),
  'T18: a staff pay row has no receipt and no control; a manual row can add, one with a receipt can replace / remove');
select ok((select (v::text !~ '[.](jpg|webp|png|pdf)' and v::text !~ 'items/') from _t where k = 'scr18b') and (select v::text !~ '[.](jpg|webp|png|pdf)' from _t where k = 'scr18' ), 'T18: no path string appears in the screen payload');

-- =============================================================================================================================================
-- T23 expense_receipt_paths_v1: kind -> bucket from the map; a draft with no stored file is not returned; foreign property, over 20 ids
-- =============================================================================================================================================
select ok((select count(*) = 5 from _t, jsonb_array_elements(v) r where k = 'rp18')
      and (select r ->> 'bucket' = 'expense-receipts' and r ->> 'kind' = 'txn' from _t, jsonb_array_elements(v) r where k = 'rp18' and (r ->> 'id')::uuid = pg_temp.id('e0'))
      and (select r ->> 'bucket' = 'expense-receipts' and r ->> 'kind' = 'draft' and r ->> 'mime' = 'image/jpeg' from _t, jsonb_array_elements(v) r where k = 'rp18' and (r ->> 'id')::uuid = pg_temp.id('e1'))
      and (select r ->> 'bucket' = 'inventory-photos' and r ->> 'kind' = 'draft' and r ->> 'mime' = 'image/webp' from _t, jsonb_array_elements(v) r where k = 'rp18' and (r ->> 'id')::uuid = pg_temp.id('e2'))
      and (select r ->> 'bucket' = 'cleaning-photos' and r ->> 'kind' = 'bill' from _t, jsonb_array_elements(v) r where k = 'rp18' and (r ->> 'id')::uuid = pg_temp.id('e3'))
      and (select r ->> 'bucket' = 'inventory-photos' and r ->> 'kind' = 'stock' from _t, jsonb_array_elements(v) r where k = 'rp18' and (r ->> 'id')::uuid = pg_temp.id('e4')),
  'T23: finance gets kind, bucket, path and type per the map (txn and scanned draft: expense-receipts, manual draft and stock: inventory-photos, bill: cleaning-photos)');
select ok(not exists (select 1 from _t, jsonb_array_elements(v) r where k = 'rp18' and (r ->> 'id')::uuid in (pg_temp.id('e5'), pg_temp.id('e7'), pg_temp.id('cd'), pg_temp.id('f3'))),
  'T23: a draft path with no stored object, a row with no receipt, a staff pay row and a purchase id are not returned (bucket is never guessed)');
select pg_temp.as_user(pg_temp.id('03'));
insert into _t select 'rp_foreign', public.expense_receipt_paths_v1(pg_temp.id('b2'), array[pg_temp.id('e0'), pg_temp.id('e1')]);
insert into _t select 'rp_many', pg_temp.try(format('select public.expense_receipt_paths_v1(%L::uuid, (select array_agg(gen_random_uuid()) from generate_series(1, 21)))', pg_temp.id('b1')));
reset role;
select ok((select v = '[]'::jsonb from _t where k = 'rp_foreign') and (select v ->> 'err' = '22023' from _t where k = 'rp_many'), 'T23: another house returns nothing; more than 20 ids is refused (22023)');

-- =============================================================================================================================================
-- T19 expense_receipt_set_v1: add, replace, remove on a manual row; an OCR row loses its model read on replace
-- =============================================================================================================================================
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, payee_name, notes) values
  (pg_temp.id('f4'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 50, 'Zz S134 Payee', 'Zz S134 set target'),
  (pg_temp.id('f5'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 51, 'Zz S134 Payee', 'Zz S134 set target two');
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, receipt_image_path, ocr_confidence, ocr_raw) values
  (pg_temp.id('f6'), pg_temp.id('b1'), 'expense', 'other', 'pending_review', 'ocr', public.manila_today(), 52, 'Zz S134 ocr row', pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), 'a9'), 0.9,
   '{"draft_id":"zz","items":[{"name":"x","price":1}],"total":52,"s134_group":"g","source":"telegram"}'::jsonb);
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '71', repeat('a', 64));
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '72', repeat('b', 64));
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '73', repeat('c', 64));
insert into _t select 'snap19', jsonb_build_object('h', (select md5(t.gross_amount::text || t.transaction_date::text || t.payee_name || t.category || t.status || t.notes) from public.transactions t where t.id = pg_temp.id('f4')));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 's_add', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f4'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '71'), null);
reset role;
insert into _t select 'st_add', to_jsonb(t) from public.transactions t where t.id = pg_temp.id('f4');
insert into _t select 'a_add', jsonb_build_object('n', (select count(*) from public.admin_audit_log a where a.entity_id = pg_temp.id('f4')));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 's_rep', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f4'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '72'), 'a better photo');
insert into _t select 's_rep2', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f4'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '72'), 'a better photo');
insert into _t select 's_ocr', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f6'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '73'), 'clearer scan');
reset role;
select ok((select (v ->> 'ok')::boolean and (v ->> 'has_receipt')::boolean and v -> 'receipt_ref' ->> 'kind' = 'txn' and v -> 'receipt_ref' ->> 'mime' = 'image/jpeg' from _t where k = 's_add')
      and (select v ->> 'receipt_image_path' = pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '71') and v -> 'ocr_raw' = jsonb_build_object('receipt_sha256', repeat('a', 64), 'receipt_mime', 'image/jpeg') and v -> 'ocr_confidence' = 'null'::jsonb from _t where k = 'st_add'),
  'T19: add stores the path and only receipt_sha256 + receipt_mime in ocr_raw (the sha is the server one; no history key)');
select ok((select (v ->> 'ok')::boolean from _t where k = 's_rep') and (select t.receipt_image_path = pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '72') and t.ocr_raw ->> 'receipt_sha256' = repeat('b', 64) and not (t.ocr_raw ? 'history') from public.transactions t where t.id = pg_temp.id('f4'))
      and (select count(*) = 1 from public.admin_audit_log a where a.entity_id = pg_temp.id('f4') and a.reason = 'a better photo' and a.before_state ->> 'receipt_image_path' = pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '71') and a.after_state ->> 'receipt_image_path' = pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '72')),
  'T19: replace changes the pointer and the sha; the audit row carries the reason and the old path');
select ok((select md5(t.gross_amount::text || t.transaction_date::text || t.payee_name || t.category || t.status || t.notes) = (select v ->> 'h' from _t where k = 'snap19') from public.transactions t where t.id = pg_temp.id('f4')) and (select (v ->> 'ok')::boolean from _t where k = 's_rep2')
      and (select count(*) = (select (v ->> 'n')::int from _t where k = 'a_add') + 1 from public.admin_audit_log a where a.entity_id = pg_temp.id('f4')),
  'T19: amount, date, payee, category, status and note are unchanged; one audit row per change and the replay of the same path writes nothing');
select ok((select (v ->> 'ok')::boolean from _t where k = 's_ocr') and (select t.ocr_confidence is null and t.ocr_raw = jsonb_build_object('draft_id', 'zz', 's134_group', 'g', 'source', 'telegram', 'receipt_sha256', repeat('c', 64), 'receipt_mime', 'image/jpeg') and t.gross_amount = 52 and t.status = 'pending_review'
             from public.transactions t where t.id = pg_temp.id('f6')), 'T19/R11: replacing the receipt of an OCR row nulls ocr_confidence and drops the model read (items, total); the system keys stay');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 's_rm0', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f4'), null, null);
insert into _t select 's_rm1', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f4'), null, 'wrong photo');
insert into _t select 's_rm2', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f4'), null, 'wrong photo');
reset role;
select ok((select v ->> 'error' = 'reason_required' from _t where k = 's_rm0') and (select (v ->> 'ok')::boolean and not (v ->> 'has_receipt')::boolean from _t where k = 's_rm1') and (select (v ->> 'ok')::boolean and not (v ->> 'has_receipt')::boolean from _t where k = 's_rm2')
      and (select t.receipt_image_path is null and t.ocr_raw is null from public.transactions t where t.id = pg_temp.id('f4')),
  'T19: remove needs a reason; it clears the pointer and the receipt keys; removing again is a no-op');

-- =============================================================================================================================================
-- T20 refusals
-- =============================================================================================================================================
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '74', repeat('d', 64));
insert into storage.objects(bucket_id, name) values ('expense-receipts', pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7f'));
select pg_temp.as_user(pg_temp.id('04'));
insert into _t select 'r_cl', pg_temp.try(format('select public.expense_receipt_set_v1(%L::uuid, %L::uuid, %L, null)', pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('04'), '74')));
select pg_temp.as_user(pg_temp.id('05'));
insert into _t select 'r_in', pg_temp.try(format('select public.expense_receipt_set_v1(%L::uuid, %L::uuid, %L, null)', pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('05'), '74')));
select pg_temp.as_user(pg_temp.id('06'));
insert into _t select 'r_mt', pg_temp.try(format('select public.expense_receipt_set_v1(%L::uuid, %L::uuid, null, %L)', pg_temp.id('b1'), pg_temp.id('f5'), 'remove it'));
select pg_temp.as_user(pg_temp.id('07'));
insert into _t select 'r_ln', pg_temp.try(format('select public.expense_receipt_set_v1(%L::uuid, %L::uuid, null, %L)', pg_temp.id('b1'), pg_temp.id('f5'), 'remove it'));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r_other_user', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('02'), '74'), null);
insert into _t select 'r_other_prop', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b2'), pg_temp.id('01'), '74'), null);
insert into _t select 'r_shape', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), 'x.jpg', null);
insert into _t select 'r_dots', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.id('b1')::text || '/' || pg_temp.id('01')::text || '/../e1340000-0000-4000-8000-000000000074.jpg', null);
insert into _t select 'r_noobj', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7e'), null);
insert into _t select 'r_nohash', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7f'), null);
insert into _t select 'r_void', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('c3'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '74'), null);
insert into _t select 'r_ok74', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '74'), null);
reset role;
select ok((select bool_and(v ->> 'err' = '42501') from _t where k in ('r_cl', 'r_in', 'r_mt', 'r_ln')), 'T20: cleaner, inspector, maintenance and laundry are refused (42501)');
select ok((select v ->> 'error' = 'bad_path' from _t where k = 'r_other_user') and (select v ->> 'error' = 'bad_path' from _t where k = 'r_other_prop') and (select v ->> 'error' = 'bad_path' from _t where k = 'r_shape') and (select v ->> 'error' = 'bad_path' from _t where k = 'r_dots'),
  'T20: a path of another user, of another house, of the wrong shape or with .. is refused (bad_path)');
select ok((select v ->> 'error' = 'no_file' from _t where k = 'r_noobj') and (select v ->> 'error' = 'void' from _t where k = 'r_void') and (select (v ->> 'ok')::boolean from _t where k = 'r_ok74')
      and (select t.receipt_image_path is null from public.transactions t where t.id = pg_temp.id('c3')), 'T20: a path with no stored object (no_file) and a void row (void) are refused; a good path on a normal row works');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'l_bill_add', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('cc'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '74'), null);
insert into _t select 'l_bill_rm', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('cc'), null, 'remove it');
insert into _t select 'l_pay_add', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('cd'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '74'), null);
insert into _t select 'l_pay_rm', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('cd'), null, 'remove it');
insert into _t select 'l_ref_add', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('ce'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '74'), null);
insert into _t select 'l_ref_rm', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('ce'), null, 'remove it');
insert into _t select 'l_bill2_rep', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('e3'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '74'), null);
insert into _t select 'l_drf_rep', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('e1'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '74'), null);
insert into _t select 'l_drf_rm', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('e2'), null, 'remove it');
insert into _t select 'l_stk_rm', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('e4'), null, 'remove it');
reset role;
select ok((select bool_and(v ->> 'error' = 'locked') from _t where k in ('l_bill_add', 'l_bill_rm', 'l_pay_add', 'l_pay_rm', 'l_ref_add', 'l_ref_rm', 'l_bill2_rep'))
      and (select v ->> 'where' = 'Bills' from _t where k = 'l_bill_add') and (select v ->> 'where' = 'Pay staff' from _t where k = 'l_pay_rm') and (select v ->> 'where' = 'Bills' from _t where k = 'l_bill2_rep')
      and (select t.receipt_image_path is null from public.transactions t where t.id in (pg_temp.id('cc'), pg_temp.id('cd'), pg_temp.id('ce')) limit 1),
  'T20/C2: every locked kind (bill, staff pay, refund) refuses add, replace and remove with the screen to go to');
select ok((select bool_and(v ->> 'error' = 'locked' and v ->> 'where' = 'Inventory') from _t where k in ('l_drf_rep', 'l_drf_rm', 'l_stk_rm')), 'T20: a row whose receipt lives on an Inventory draft or purchase refuses the control and names Inventory');

-- =============================================================================================================================================
-- T21 upload proof
-- =============================================================================================================================================
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '75', repeat('e', 64), 'jpg', interval '25 hours');
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '76', repeat('f', 64));
update public.staff_upload_hashes set uploaded_by = pg_temp.id('02') where path = pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '76');
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '77', repeat('9', 64), 'jpg', interval '23 hours');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'u_old', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '75'), null);
insert into _t select 'u_other', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '76'), null);
insert into _t select 'u_fresh', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f5'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '77'), 'within the day');
reset role;
select ok((select v ->> 'error' = 'no_upload_record' from _t where k = 'r_nohash') and (select v ->> 'error' = 'no_upload_record' from _t where k = 'u_other') and (select v ->> 'error' = 'no_upload_record' from _t where k = 'u_old'),
  'T21: an object with no upload row, an upload row of another user and an upload row older than 24 hours are all refused');
select ok((select (v ->> 'ok')::boolean from _t where k = 'u_fresh') and (select t.ocr_raw ->> 'receipt_sha256' = repeat('9', 64) from public.transactions t where t.id = pg_temp.id('f5')), 'T21: an upload row under 24 hours old by the same user is accepted and its sha is the one stored');

-- =============================================================================================================================================
-- T22 duplicates
-- =============================================================================================================================================
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes) values
  (pg_temp.id('f7'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 60, 'Zz S134 dup target'),
  (pg_temp.id('f8'), pg_temp.id('b1'), 'expense', 'other', 'confirmed', 'manual', public.manila_today(), 61, 'Zz S134 dup second');
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '78', repeat('7', 64));
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '79', repeat('7', 64));
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '7a', repeat('8', 64));
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '7b', repeat('5', 64));
insert into public.utility_bills(property_id, kind, period, status, proof_sha256) values (pg_temp.id('b1'), 'electric', '2026-09', 'due', repeat('8', 64));
insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, proof_sha256) values
  (pg_temp.id('b1'), pg_temp.id('04'), 'Zz S134 Cleaner', 'zz-s134-pay-0002', 'requested', '[{"x":1}]'::jsonb, 80, repeat('5', 64));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'd_first', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f7'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '78'), null);
insert into _t select 'd_sha', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f8'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '79'), null);
insert into _t select 'd_path', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f8'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '78'), null);
insert into _t select 'd_bill', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f8'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7a'), null);
insert into _t select 'd_pay', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f8'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7b'), null);
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'd_first') and (select v ->> 'error' = 'duplicate_receipt' and v ->> 'id' = pg_temp.id('f7')::text and v ->> 'ref' = left(pg_temp.id('f7')::text, 8) from _t where k = 'd_sha')
      and (select v ->> 'error' = 'duplicate_receipt' and v ->> 'id' = pg_temp.id('f7')::text from _t where k = 'd_path') and (select t.receipt_image_path is null from public.transactions t where t.id = pg_temp.id('f8')),
  'T22: the same sha, or the same path, on another non-void row is refused as duplicate_receipt naming that row (no exception); the second row stays clean (one winner)');
select ok((select v ->> 'error' = 'duplicate_receipt' and v ->> 'where' = 'Bills' from _t where k = 'd_bill') and (select v ->> 'error' = 'duplicate_receipt' and v ->> 'where' = 'Pay staff' from _t where k = 'd_pay'),
  'T22: the sha of a bill payment proof or of a staff pay proof is refused too, naming Bills or Pay staff');

-- =============================================================================================================================================
-- T24 a pdf is accepted and typed application/pdf
-- =============================================================================================================================================
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '7c', repeat('4', 64), 'pdf');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'pdf', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f8'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7c', 'pdf'), null);
reset role;
select ok((select (v ->> 'ok')::boolean and v -> 'receipt_ref' ->> 'mime' = 'application/pdf' from _t where k = 'pdf') and (select t.ocr_raw ->> 'receipt_mime' = 'application/pdf' from public.transactions t where t.id = pg_temp.id('f8')), 'T24: a .pdf path is accepted and its receipt_ref.mime is application/pdf');

-- =============================================================================================================================================
-- T25 admin_save_transaction_v2 and receipts (R1): no edit path to the receipt columns; create needs the upload proof
-- =============================================================================================================================================
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '7d', repeat('3', 64));
insert into _t select 'snap25', jsonb_build_object('h', (select md5(coalesce(t.receipt_image_path, '') || coalesce(t.ocr_raw::text, '')) from public.transactions t where t.id = pg_temp.id('f8')));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'e_path', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('f8'), 'receipt_image_path', pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7d'), 'reason', 'try'), null);
insert into _t select 'e_raw', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('f8'), 'ocr_raw', '{"a":1}'::jsonb, 'reason', 'try'), null);
insert into _t select 'e_conf', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('f8'), 'ocr_confidence', 0.5, 'reason', 'try'), null);
insert into _t select 'e_amt', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('id', pg_temp.id('f8'), 'gross_amount', 62, 'reason', 'price corrected'), null);
insert into _t select 'c_noup', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'other', 'gross_amount', 5, 'transaction_date', public.manila_today(), 'receipt_image_path', pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7f')), 'zz-s134-save-key-25001');
insert into _t select 'c_ok', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'other', 'gross_amount', 5, 'transaction_date', public.manila_today(),
    'receipt_image_path', pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7d'), 'ocr_raw', jsonb_build_object('receipt_sha256', repeat('0', 64), 's134_auto', true, 'draft_id', 'zz', 'source', 'telegram', 'note', 'kept')), 'zz-s134-save-key-25002');
reset role;
select ok((select bool_and(v ->> 'error' = 'use_receipt_control') from _t where k in ('e_path', 'e_raw', 'e_conf')), 'T25: an edit that carries receipt_image_path, ocr_raw or ocr_confidence is refused (use_receipt_control)');
select ok((select (v ->> 'ok')::boolean from _t where k = 'e_amt') and (select md5(coalesce(t.receipt_image_path, '') || coalesce(t.ocr_raw::text, '')) = (select v ->> 'h' from _t where k = 'snap25') and t.gross_amount = 62 from public.transactions t where t.id = pg_temp.id('f8')),
  'T25: an amount-only edit leaves the receipt pointer and ocr_raw byte-identical');
select ok((select v ->> 'error' = 'no_upload_record' from _t where k = 'c_noup') and (select (v ->> 'ok')::boolean from _t where k = 'c_ok')
      and (select t.receipt_image_path = pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7d') and t.ocr_raw ->> 'receipt_sha256' = repeat('3', 64) and not (t.ocr_raw ? 's134_auto') and not (t.ocr_raw ? 'draft_id') and not (t.ocr_raw ? 'source') and t.ocr_raw ->> 'note' = 'kept'
          from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'c_ok')),
  'T25: a create with a path that has no upload row is refused; with one it stores the SERVER sha (a client-sent receipt_sha256 or s134 key is dropped)');

-- =============================================================================================================================================
-- T26 a photo held by an open Inventory draft is refused (R3)
-- =============================================================================================================================================
select pg_temp.upload(pg_temp.id('b1'), pg_temp.id('01'), '7e', repeat('2', 64));
insert into public.inventory_receipt_drafts(id, property_id, created_by, receipt_path, lines, status) values
  (pg_temp.id('d8'), pg_temp.id('b1'), pg_temp.id('01'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7e'), '[]'::jsonb, 'draft');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'h_set', public.expense_receipt_set_v1(pg_temp.id('b1'), pg_temp.id('f7'), pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7e'), null);
insert into _t select 'h_new', public.admin_save_transaction_v2(pg_temp.id('b1'), jsonb_build_object('txn_type', 'expense', 'category', 'other', 'gross_amount', 6, 'transaction_date', public.manila_today(), 'receipt_image_path', pg_temp.rpath(pg_temp.id('b1'), pg_temp.id('01'), '7e')), 'zz-s134-save-key-26001');
reset role;
select ok((select v ->> 'error' = 'receipt_in_use' and v ->> 'where' = 'Inventory' from _t where k = 'h_set') and (select v ->> 'error' = 'receipt_in_use' from _t where k = 'h_new')
      and not exists (select 1 from public.transactions t where t.external_ref = 'admin:zz-s134-save-key-26001'), 'T26: a path held by an open Inventory draft is refused by the receipt control and by a v2 create (receipt_in_use, where Inventory)');

-- =============================================================================================================================================
-- T27 the PDF bucket statement (s_expense_bucket_pdf_v1) on fixture buckets
-- =============================================================================================================================================
insert into storage.buckets(id, name, file_size_limit, allowed_mime_types) values
  ('zz-s134-nolist', 'zz-s134-nolist', null, null),
  ('zz-s134-img', 'zz-s134-img', 10485760, array['image/jpeg', 'image/png', 'image/webp']),
  ('zz-s134-small', 'zz-s134-small', 1048576, array['image/jpeg']);
select public.s_expense_bucket_pdf_v1('zz-s134-nolist');
select public.s_expense_bucket_pdf_v1('zz-s134-img');
insert into _t select 'bk1', to_jsonb((select allowed_mime_types from storage.buckets where id = 'zz-s134-img'));
select public.s_expense_bucket_pdf_v1('zz-s134-img');
select ok((select allowed_mime_types is null from storage.buckets where id = 'zz-s134-nolist'), 'T27: a bucket with no mime list stays unrestricted (NULL stays NULL)');
select ok((select v = '["image/jpeg", "image/png", "image/webp", "application/pdf"]'::jsonb from _t where k = 'bk1') and (select allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'] from storage.buckets where id = 'zz-s134-img'),
  'T27: a list without pdf gains application/pdf once and keeps jpeg / png / webp; a second run changes nothing');
select ok((select (pg_temp.try('select public.s_expense_bucket_pdf_v1(''zz-s134-small'')')) ->> 'err' = '55000') and (select allowed_mime_types = array['image/jpeg'] from storage.buckets where id = 'zz-s134-small'),
  'T27: a bucket whose file_size_limit is under 5 MB stops the migration (55000) and is left alone');

-- =============================================================================================================================================
-- T16 back-fill on legacy fixtures: one pending row per group, never confirmed, nothing existing touched, second run a no-op
-- =============================================================================================================================================
alter table public.inventory_purchases disable trigger s134_stock_expense_group;
alter table public.inventory_purchases disable trigger s134_stock_expense_sync;
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes) values
  (pg_temp.id('b8'), pg_temp.id('b1'), 'expense', 'supplies', 'confirmed', 'manual', date '2026-09-21', 33, 'Zz S134 bf look-alike'),
  (pg_temp.id('b9'), pg_temp.id('b1'), 'expense', 'supplies', 'confirmed', 'inventory', date '2026-09-01', 44, 'Zz S134 bf human-owned stock row');
-- the row of G5 was made by a person: external_ref stock:p:<purchase id>
insert into public.inventory_purchases(id, item_id, qty, unit_cost, purchased_at, supplier, notes) values
  (pg_temp.id('c1'), pg_temp.id('a1'), 2, 10, date '2026-10-05', 'Zz S134 Sup', 'Admin receipt [key:zz-s134-bf-g1:g1] first'),
  (pg_temp.id('c2'), pg_temp.id('a2'), 1, 5, date '2026-10-05', 'Zz S134 Sup', 'Admin receipt [key:zz-s134-bf-g1:g2] second'),
  (pg_temp.id('c3'), pg_temp.id('a1'), 3, 5, date '2026-10-12', null, 'Admin receipt [key:zz-s134-bf-g2:g1] priced'),
  (pg_temp.id('c4'), pg_temp.id('a2'), 1, null, date '2026-10-12', null, 'Admin receipt [key:zz-s134-bf-g2:g2] not priced'),
  (pg_temp.id('c5'), pg_temp.id('a3'), 4, 25, date '2026-07-15', null, 'Zz S134 bf before the start date'),
  (pg_temp.id('c6'), pg_temp.id('a3'), 1, 12, date '2026-09-10', null, 'Zz S134 bf linked by note (txn ' || pg_temp.id('e5')::text || ')'),
  (pg_temp.id('c7'), pg_temp.id('a3'), 1, 44, date '2026-09-01', null, 'Zz S134 bf human row'),
  (pg_temp.id('c8'), pg_temp.id('a3'), 2, 7, date '2026-09-20', null, 'Zz S134 bf look-alike purchase'),
  (pg_temp.id('c9'), pg_temp.id('a3'), 2, null, date '2026-09-05', null, 'Zz S134 bf nothing priced');
update public.transactions set external_ref = 'stock:p:' || pg_temp.id('c7')::text where id = pg_temp.id('b9');
-- fix round 1: a scanned draft whose own live row already exists (ocr_raw draft_id) must not get a second row; a "(txn ...)" note that names an expense of ANOTHER house must not link
insert into public.inventory_receipt_drafts(id, property_id, created_by, receipt_path, lines, status, total) values
  (pg_temp.id('9a'), pg_temp.id('b1'), pg_temp.id('01'), 'items/' || pg_temp.id('9a')::text || '/' || pg_temp.id('9a')::text || '.jpg', '[]'::jsonb, 'confirmed', 30);
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, ocr_raw) values
  (pg_temp.id('9b'), pg_temp.id('b1'), 'expense', 'supplies', 'confirmed', 'ocr', date '2026-10-20', 30, 'Zz S134 bf draft own row', jsonb_build_object('draft_id', pg_temp.id('9a')::text)),
  (pg_temp.id('9c'), pg_temp.id('b2'), 'expense', 'supplies', 'confirmed', 'manual', date '2026-10-21', 9, 'Zz S134 bf other house row', null);
insert into public.inventory_purchases(id, item_id, qty, unit_cost, purchased_at, supplier, notes, expense_group) values
  (pg_temp.id('9d'), pg_temp.id('a3'), 3, 10, date '2026-10-20', null, 'Zz S134 bf draft line', 'draft:' || pg_temp.id('9a')::text);
insert into public.inventory_purchases(id, item_id, qty, unit_cost, purchased_at, supplier, notes) values
  (pg_temp.id('9e'), pg_temp.id('a3'), 1, null, date '2026-10-21', null, 'Zz S134 bf cross house (txn ' || pg_temp.id('9c')::text || ')');
-- these purchases model stock written BEFORE the cut-over (the sync never saw them): their created_at is before the cut-over, so the "exactly one live row for a priced post-cut-over group" half of the invariant does not apply to them
update public.inventory_purchases set created_at = now() - interval '400 days' where id in (pg_temp.id('c1'), pg_temp.id('c2'), pg_temp.id('c3'), pg_temp.id('c4'), pg_temp.id('c5'), pg_temp.id('c6'), pg_temp.id('c7'), pg_temp.id('c8'), pg_temp.id('c9'), pg_temp.id('9d'), pg_temp.id('9e'));
alter table public.inventory_purchases enable trigger s134_stock_expense_group;
alter table public.inventory_purchases enable trigger s134_stock_expense_sync;
create temp table _bf0 as select t.id, md5(t::text) as h from public.transactions t;
grant select on _bf0 to public;

-- BACKFILL-BEGIN
do $bf$
declare
  v_from date := coalesce(nullif(current_setting('s134.start_date', true), ''), '2026-08-01')::date;
  g record; v_new uuid; v_names text[]; v_note text; v_dup boolean; v_made integer := 0; v_b1 integer; v_b2 integer; v_b2b integer;
begin
  -- B1
  update public.inventory_purchases p set expense_group = public.s_stock_expense_group_of_v1(p.id, p.notes) where p.expense_group is null;
  get diagnostics v_b1 = row_count;
  -- B2
  update public.inventory_purchases p set transaction_id = t.id
    from public.transactions t, public.inventory_items it
   where p.transaction_id is null and t.id = public.s_stock_expense_txn_of_v1(p.notes)
     and it.id = p.item_id and t.property_id = it.property_id and t.txn_type = 'expense';
  get diagnostics v_b2 = row_count;
  update public.inventory_purchases p set transaction_id = d.transaction_id
    from public.inventory_receipt_drafts d, public.inventory_items it
   where p.transaction_id is null and p.expense_group = 'draft:' || d.id::text and d.transaction_id is not null
     and it.id = p.item_id
     and exists (select 1 from public.transactions t where t.id = d.transaction_id and t.property_id = it.property_id and t.txn_type = 'expense');
  get diagnostics v_b2b = row_count;
  -- B4
  for g in
    select p.expense_group as grp, (array_agg(i.property_id))[1] as prop, min(p.purchased_at) as first_date,
           round(coalesce(sum(p.qty * p.unit_cost) filter (where p.unit_cost > 0), 0), 2) as priced_sum,
           count(*) as n, count(*) filter (where p.unit_cost > 0) as priced,
           count(distinct nullif(btrim(p.supplier), '')) as nsup, min(nullif(btrim(p.supplier), '')) as sup
      from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
     where p.expense_group is not null
     group by p.expense_group
    having bool_and(p.transaction_id is null) and min(p.purchased_at) >= v_from and count(*) filter (where p.unit_cost > 0) > 0
       and not exists (select 1 from public.transactions t where t.external_ref = 'stock:' || p.expense_group and t.txn_type = 'expense')
       -- a scanned draft's own live row (the sync's step 1 rule): that group already has its one row
       and not exists (select 1 from public.transactions t where p.expense_group like 'draft:%' and t.txn_type = 'expense' and t.status <> 'void' and t.ocr_raw ->> 'draft_id' = substr(p.expense_group, 7))
     order by min(p.purchased_at), p.expense_group
  loop
    declare
      v_total numeric := (select round(d.total, 2) from public.inventory_receipt_drafts d where g.grp like 'draft:%' and d.id::text = substr(g.grp, 7) and d.total > 0);
      v_amt numeric; v_incomplete boolean;
    begin
      v_amt := coalesce(v_total, g.priced_sum);
      v_incomplete := v_total is null and g.priced < g.n;
      continue when v_amt is null or v_amt <= 0;
      -- the sync's own lock for this group, then the checks again: a stock write that committed since the list was read may have made the group's row
      perform pg_advisory_xact_lock(hashtextextended('s134:stock:' || g.grp, 0));
      continue when exists (select 1 from public.transactions t where t.external_ref = 'stock:' || g.grp and t.txn_type = 'expense')
                 or exists (select 1 from public.inventory_purchases ip where ip.expense_group = g.grp and ip.transaction_id is not null)
                 or exists (select 1 from public.transactions t where g.grp like 'draft:%' and t.txn_type = 'expense' and t.status <> 'void' and t.ocr_raw ->> 'draft_id' = substr(g.grp, 7));
      select array_agg(x.name order by x.first_at, x.name) into v_names
        from (select i.name, min(p.created_at) first_at from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id where p.expense_group = g.grp group by i.name) x;
      v_dup := exists (select 1 from public.transactions o
                        where o.property_id = g.prop and o.txn_type = 'expense' and o.status <> 'void' and o.category in ('supplies', 'maintenance', 'repairs')
                          and o.source not in ('airbnb', 'airbnb_email') and abs(o.transaction_date - g.first_date) <= 3
                          and not exists (select 1 from public.inventory_purchases ip where ip.transaction_id = o.id));
      v_note := 'Stock bought: ' || array_to_string(v_names[1:3], ', ') || case when array_length(v_names, 1) > 3 then ' (+' || (array_length(v_names, 1) - 3) || ' more)' else '' end
                || case when g.nsup >= 2 then ' - Several suppliers' else '' end
                || ' [back-fill s134]' || case when v_dup then ' [possible duplicate]' else '' end;
      perform public.admin_audit_context_v1('s134 back-fill', null, null);
      insert into public.transactions (property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by, ocr_raw)
      values (g.prop, 'expense', 'supplies', 'pending_review', 'inventory', g.first_date, v_amt, 'PHP', case when g.nsup = 1 then g.sup end, v_note, 'stock:' || g.grp, 'system',
              jsonb_build_object('s134_auto', false, 's134_amount', v_amt, 's134_group', g.grp, 's134_backfill', true, 's134_incomplete', v_incomplete))
      returning id into v_new;
      perform public.admin_audit_context_v1('', null, null);
      update public.inventory_purchases set transaction_id = v_new where expense_group = g.grp and transaction_id is null;
      v_made := v_made + 1;
    end;
  end loop;
  raise notice 's134 back-fill: % purchase(s) given a group, % linked to an existing expense, % pending_review row(s) created', v_b1, v_b2 + v_b2b, v_made;
end
$bf$;
-- BACKFILL-END

create temp table _bf1 as select 'p'::text as k, p.id::text as id, md5(p::text) as h from public.inventory_purchases p union all select 't', t.id::text, md5(t::text) from public.transactions t;
grant select on _bf1 to public;

-- BACKFILL-BEGIN
do $bf$
declare
  v_from date := coalesce(nullif(current_setting('s134.start_date', true), ''), '2026-08-01')::date;
  g record; v_new uuid; v_names text[]; v_note text; v_dup boolean; v_made integer := 0; v_b1 integer; v_b2 integer; v_b2b integer;
begin
  -- B1
  update public.inventory_purchases p set expense_group = public.s_stock_expense_group_of_v1(p.id, p.notes) where p.expense_group is null;
  get diagnostics v_b1 = row_count;
  -- B2
  update public.inventory_purchases p set transaction_id = t.id
    from public.transactions t, public.inventory_items it
   where p.transaction_id is null and t.id = public.s_stock_expense_txn_of_v1(p.notes)
     and it.id = p.item_id and t.property_id = it.property_id and t.txn_type = 'expense';
  get diagnostics v_b2 = row_count;
  update public.inventory_purchases p set transaction_id = d.transaction_id
    from public.inventory_receipt_drafts d, public.inventory_items it
   where p.transaction_id is null and p.expense_group = 'draft:' || d.id::text and d.transaction_id is not null
     and it.id = p.item_id
     and exists (select 1 from public.transactions t where t.id = d.transaction_id and t.property_id = it.property_id and t.txn_type = 'expense');
  get diagnostics v_b2b = row_count;
  -- B4
  for g in
    select p.expense_group as grp, (array_agg(i.property_id))[1] as prop, min(p.purchased_at) as first_date,
           round(coalesce(sum(p.qty * p.unit_cost) filter (where p.unit_cost > 0), 0), 2) as priced_sum,
           count(*) as n, count(*) filter (where p.unit_cost > 0) as priced,
           count(distinct nullif(btrim(p.supplier), '')) as nsup, min(nullif(btrim(p.supplier), '')) as sup
      from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
     where p.expense_group is not null
     group by p.expense_group
    having bool_and(p.transaction_id is null) and min(p.purchased_at) >= v_from and count(*) filter (where p.unit_cost > 0) > 0
       and not exists (select 1 from public.transactions t where t.external_ref = 'stock:' || p.expense_group and t.txn_type = 'expense')
       -- a scanned draft's own live row (the sync's step 1 rule): that group already has its one row
       and not exists (select 1 from public.transactions t where p.expense_group like 'draft:%' and t.txn_type = 'expense' and t.status <> 'void' and t.ocr_raw ->> 'draft_id' = substr(p.expense_group, 7))
     order by min(p.purchased_at), p.expense_group
  loop
    declare
      v_total numeric := (select round(d.total, 2) from public.inventory_receipt_drafts d where g.grp like 'draft:%' and d.id::text = substr(g.grp, 7) and d.total > 0);
      v_amt numeric; v_incomplete boolean;
    begin
      v_amt := coalesce(v_total, g.priced_sum);
      v_incomplete := v_total is null and g.priced < g.n;
      continue when v_amt is null or v_amt <= 0;
      -- the sync's own lock for this group, then the checks again: a stock write that committed since the list was read may have made the group's row
      perform pg_advisory_xact_lock(hashtextextended('s134:stock:' || g.grp, 0));
      continue when exists (select 1 from public.transactions t where t.external_ref = 'stock:' || g.grp and t.txn_type = 'expense')
                 or exists (select 1 from public.inventory_purchases ip where ip.expense_group = g.grp and ip.transaction_id is not null)
                 or exists (select 1 from public.transactions t where g.grp like 'draft:%' and t.txn_type = 'expense' and t.status <> 'void' and t.ocr_raw ->> 'draft_id' = substr(g.grp, 7));
      select array_agg(x.name order by x.first_at, x.name) into v_names
        from (select i.name, min(p.created_at) first_at from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id where p.expense_group = g.grp group by i.name) x;
      v_dup := exists (select 1 from public.transactions o
                        where o.property_id = g.prop and o.txn_type = 'expense' and o.status <> 'void' and o.category in ('supplies', 'maintenance', 'repairs')
                          and o.source not in ('airbnb', 'airbnb_email') and abs(o.transaction_date - g.first_date) <= 3
                          and not exists (select 1 from public.inventory_purchases ip where ip.transaction_id = o.id));
      v_note := 'Stock bought: ' || array_to_string(v_names[1:3], ', ') || case when array_length(v_names, 1) > 3 then ' (+' || (array_length(v_names, 1) - 3) || ' more)' else '' end
                || case when g.nsup >= 2 then ' - Several suppliers' else '' end
                || ' [back-fill s134]' || case when v_dup then ' [possible duplicate]' else '' end;
      perform public.admin_audit_context_v1('s134 back-fill', null, null);
      insert into public.transactions (property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by, ocr_raw)
      values (g.prop, 'expense', 'supplies', 'pending_review', 'inventory', g.first_date, v_amt, 'PHP', case when g.nsup = 1 then g.sup end, v_note, 'stock:' || g.grp, 'system',
              jsonb_build_object('s134_auto', false, 's134_amount', v_amt, 's134_group', g.grp, 's134_backfill', true, 's134_incomplete', v_incomplete))
      returning id into v_new;
      perform public.admin_audit_context_v1('', null, null);
      update public.inventory_purchases set transaction_id = v_new where expense_group = g.grp and transaction_id is null;
      v_made := v_made + 1;
    end;
  end loop;
  raise notice 's134 back-fill: % purchase(s) given a group, % linked to an existing expense, % pending_review row(s) created', v_b1, v_b2 + v_b2b, v_made;
end
$bf$;
-- BACKFILL-END

select ok((select count(*) = 1 from public.transactions t where t.external_ref = 'stock:rcpt:zz-s134-bf-g1')
      and (select t.status = 'pending_review' and t.gross_amount = 25 and t.payee_name = 'Zz S134 Sup' and t.source = 'inventory' and t.category = 'supplies' and t.logged_by = 'system' and t.transaction_date = date '2026-10-05'
                  and t.ocr_raw = jsonb_build_object('s134_auto', false, 's134_amount', 25, 's134_group', 'rcpt:zz-s134-bf-g1', 's134_backfill', true, 's134_incomplete', false) and t.notes like '%[back-fill s134]' and t.notes not like '%possible duplicate%'
             from public.transactions t where t.external_ref = 'stock:rcpt:zz-s134-bf-g1')
      and (select count(*) = 2 and bool_and(p.transaction_id = (select t.id from public.transactions t where t.external_ref = 'stock:rcpt:zz-s134-bf-g1') and p.expense_group = 'rcpt:zz-s134-bf-g1')
             from public.inventory_purchases p where p.id in (pg_temp.id('c1'), pg_temp.id('c2'))),
  'T16: a legacy two-line receipt group gets ONE pending_review row (sum of its lines, its one supplier, source inventory, logged_by system) and both purchases are linked');
select ok((select t.gross_amount = 15 and t.status = 'pending_review' and t.notes not like '%amount incomplete%' and t.ocr_raw ->> 's134_incomplete' = 'true' from public.transactions t where t.external_ref = 'stock:rcpt:zz-s134-bf-g2')
      and (select t.notes like '%possible duplicate%' and t.status = 'pending_review' from public.transactions t where t.external_ref = 'stock:p:' || pg_temp.id('c8')::text),
  'T16: a group with an unpriced line is flagged by ocr_raw.s134_incomplete (no note text) and counted at its priced lines; a group with a look-alike is flagged "possible duplicate"; neither is confirmed or guessed');
select ok(not exists (select 1 from public.transactions t where t.external_ref = 'stock:p:' || pg_temp.id('c5')::text) and not exists (select 1 from public.transactions t where t.external_ref = 'stock:p:' || pg_temp.id('c9')::text)
      and not exists (select 1 from public.transactions t where t.external_ref = 'stock:p:' || pg_temp.id('c6')::text) and (select p.transaction_id is null from public.inventory_purchases p where p.id = pg_temp.id('c5'))
      and (select p.transaction_id = pg_temp.id('e5') from public.inventory_purchases p where p.id = pg_temp.id('c6')) and (select p.transaction_id is null from public.inventory_purchases p where p.id = pg_temp.id('c7')),
  'T16: stock before the start date, stock with no price, and stock already linked (by its note, or to a human-owned stock row) get no new row; the note link is made and a human-owned stock row is left alone');
select ok(not exists (select 1 from public.transactions t where t.external_ref like 'stock:%' and t.ocr_raw ->> 's134_backfill' = 'true' and (t.status <> 'pending_review' or t.ocr_raw ->> 's134_auto' <> 'false'))
      and not exists (select 1 from _bf0 b join public.transactions t on t.id = b.id where md5(t::text) is distinct from b.h)
      and (with g as (
              select p.expense_group grp, min(p.created_at) first_at,
                     (bool_or(p.unit_cost > 0) or exists (select 1 from public.inventory_receipt_drafts d where p.expense_group = 'draft:' || d.id::text and d.total > 0)) priced
                from public.inventory_purchases p where p.expense_group is not null group by p.expense_group),
            live as (
              select p.expense_group grp, t.id from public.inventory_purchases p join public.transactions t on t.id = p.transaction_id and t.status <> 'void' where p.expense_group is not null
              union
              select g.grp, t.id from g join public.transactions t on t.external_ref = 'stock:' || g.grp and t.status <> 'void')
           select not exists (select 1 from live group by grp having count(distinct id) > 1)
              and not exists (select 1 from g where g.priced and g.first_at >= (select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from')
                                and not exists (select 1 from live l where l.grp = g.grp)
                                and not exists (select 1 from public.inventory_purchases p2 join public.transactions v on (v.id = p2.transaction_id or v.external_ref = 'stock:' || p2.expense_group) and v.status = 'void' and coalesce(v.notes, '') not like '%[voided: stock receipt%'
                                                 where p2.expense_group = g.grp))),
  'T16: no back-filled row is confirmed, no row that existed before is modified, and the full per-group invariant holds (at most one live row; exactly one for a priced post-cut-over group unless a person voided it)');
select ok(not exists (select 1 from (select 'p'::text as k, p.id::text as id, md5(p::text) as h from public.inventory_purchases p union all select 't', t.id::text, md5(t::text) from public.transactions t) a
                       where not exists (select 1 from _bf1 b where b.k = a.k and b.id = a.id and b.h = a.h))
      and (select count(*) from public.transactions) = (select count(*) from _bf1 where k = 't'), 'T16: running the back-fill a second time changes nothing (idempotent)');
select ok(not exists (select 1 from public.transactions t where t.external_ref = 'stock:draft:' || pg_temp.id('9a')::text) and (select p.transaction_id is null from public.inventory_purchases p where p.id = pg_temp.id('9d')),
  'fix 10: the back-fill gives no second row to a scanned draft that already has its own live row (ocr_raw draft_id)');
select ok((select p.transaction_id is null from public.inventory_purchases p where p.id = pg_temp.id('9e')),
  'fix 10: a "(txn ...)" note naming an expense of another house is not linked by the back-fill');

-- =============================================================================================================================================
-- Fix round 3: a sync-voided row is reopened when the group is priced again (a person-voided one never); the review queue's approve refuses the stock rows the purchases own; the incomplete marker
-- survives a receipt attach and is never taken from a client; the screen rows carry the look-alike object. Clean room: house b3.
-- =============================================================================================================================================
insert into public.properties(id, name, is_active) values (pg_temp.id('b3'), 'Zz S134 R3 Room', true);
insert into public.expense_categories(property_id, slug, label, sort_order) values
  (pg_temp.id('b3'), 'supplies', 'Supplies', 1), (pg_temp.id('b3'), 'maintenance', 'Maintenance', 2), (pg_temp.id('b3'), 'cleaning', 'Cleaning', 4), (pg_temp.id('b3'), 'other', 'Other', 6),
  (pg_temp.id('b3'), 'guest_refund', 'Guest refund', 900), (pg_temp.id('b3'), 'airbnb_adjustment', 'Airbnb adjustment', 901);
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, unit_cost, purchase_unit) values
  (pg_temp.id('81'), pg_temp.id('b3'), 'Zz S134 Pad', 'Kitchen', 'pc', 5, true, true, 1, 10, null),
  (pg_temp.id('82'), pg_temp.id('b3'), 'Zz S134 Cup', 'Kitchen', 'pc', 5, true, true, 1, 10, null),
  (pg_temp.id('83'), pg_temp.id('b3'), 'Zz S134 Mug', 'Kitchen', 'pc', 5, true, true, 1, 10, null);
-- the per-group invariant (as the forward check): at most one live row per receipt group, exactly one for a priced group made after the cut-over unless a person voided it
create function pg_temp.inv_ok() returns boolean language sql stable as $$
  with g as (
      select p.expense_group grp, min(p.created_at) first_at,
             (bool_or(p.unit_cost > 0) or exists (select 1 from public.inventory_receipt_drafts d where p.expense_group = 'draft:' || d.id::text and d.total > 0)) priced
        from public.inventory_purchases p where p.expense_group is not null group by p.expense_group),
    live as (
      select p.expense_group grp, t.id from public.inventory_purchases p join public.transactions t on t.id = p.transaction_id and t.status <> 'void' where p.expense_group is not null
      union
      select g.grp, t.id from g join public.transactions t on t.external_ref = 'stock:' || g.grp and t.status <> 'void')
  select not exists (select 1 from live group by grp having count(distinct id) > 1)
     and not exists (select 1 from g where g.priced and g.first_at >= (select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from')
                       and not exists (select 1 from live l where l.grp = g.grp)
                       and not exists (select 1 from public.inventory_purchases p2 join public.transactions v on (v.id = p2.transaction_id or v.external_ref = 'stock:' || p2.expense_group) and v.status = 'void' and coalesce(v.notes, '') not like '%[voided: stock receipt%'
                                        where p2.expense_group = g.grp)) $$;
grant execute on function pg_temp.inv_ok() to public;
-- the stock row of a group, readable while the session runs as a staff role (the id is looked up as the owner)
create function pg_temp.sid(p_group text) returns uuid language sql stable security definer as $$
  select t.id from public.transactions t where t.external_ref = 'stock:' || p_group order by (t.status <> 'void') desc, t.created_at desc limit 1 $$;
grant execute on function pg_temp.sid(text) to public;

-- (1) price -> nothing (the sync voids its own row) -> priced again: ONE live row again, reopened as pending_review at the new amount
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3a', public.record_inventory_receipt_v1(pg_temp.id('81'), 2, 10, 'Zz S134 Shop', null, null, null, 'zz-s134-r3-key-0001');
reset role;
set constraints all immediate;
set constraints all deferred;
update public.inventory_purchases set unit_cost = null where expense_group = 'rcpt:zz-s134-r3-key-0001';
set constraints all immediate;
select ok(pg_temp.nrows('rcpt:zz-s134-r3-key-0001') = 0 and (select t.status = 'void' and t.gross_amount = 20 and t.notes like 'Stock bought: Zz S134 Pad%[voided: stock receipt has no priced line left]' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0001')),
  'fix r3 item 1: when the last priced line goes the sync voids its own row (marker appended)');
set constraints all deferred;
update public.inventory_purchases set unit_cost = 12 where expense_group = 'rcpt:zz-s134-r3-key-0001';
set constraints all immediate;
select ok(pg_temp.nrows('rcpt:zz-s134-r3-key-0001') = 1 and (select count(*) = 1 from public.transactions t where t.external_ref = 'stock:rcpt:zz-s134-r3-key-0001')
      and (select t.status = 'pending_review' and t.ocr_raw ->> 's134_auto' = 'false' and t.gross_amount = 24 and (t.ocr_raw ->> 's134_amount')::numeric = 24 and t.ocr_raw ->> 's134_incomplete' = 'false'
                  and t.notes = 'Stock bought: Zz S134 Pad' and t.payee_name = 'Zz S134 Shop' and t.source = 'inventory'
                  and (select count(*) = 1 and bool_and(p.transaction_id = t.id) from public.inventory_purchases p where p.expense_group = 'rcpt:zz-s134-r3-key-0001') is not distinct from true
             from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0001'))
      and not exists (select 1 from public.follow_up_tasks f where f.source_kind = 'stock_expense_sync' and f.source_ref = 'repriced:rcpt:zz-s134-r3-key-0001'),
  'fix r3 item 1: priced again after the sync void: the SAME row is reopened (pending_review, s134_auto false, P24, sync marker gone from the note), one live row, no task');

-- (2) a person voids a stock row; the group is priced again: the row stays void, one follow-up task names it
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3b', public.record_inventory_receipt_v1(pg_temp.id('82'), 1, 7, 'Zz S134 Shop', null, null, null, 'zz-s134-r3-key-0002');
reset role;
set constraints all immediate;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3bv', public.expense_void_v1(pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0002'), 'not a cost really', null);
reset role;
set constraints all deferred;
update public.inventory_purchases set unit_cost = 9 where expense_group = 'rcpt:zz-s134-r3-key-0002';
set constraints all immediate;
select ok((select (v ->> 'ok')::boolean from _t where k = 'r3bv') and pg_temp.nrows('rcpt:zz-s134-r3-key-0002') = 0
      and (select t.status = 'void' and t.gross_amount = 7 and t.notes like '%[voided: not a cost really]' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0002'))
      and (select count(*) = 1 from public.follow_up_tasks f where f.source_kind = 'stock_expense_sync' and f.source_ref = 'repriced:rcpt:zz-s134-r3-key-0002'),
  'fix r3 item 1: a row a PERSON voided is never reopened when the group is priced again; one follow-up task opens instead');
select ok(pg_temp.inv_ok(), 'fix r3 item 1: the per-group invariant passes after the sync-voided reprice and the person-voided reprice');

-- (3) approve refusals. An incomplete stock row (a priced and an unpriced line)
set constraints all deferred;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3c', public.record_inventory_receipt_v1(pg_temp.id('83'), 1, 10, 'Zz S134 Shop', null, null, null, 'zz-s134-r3-key-0003');
reset role;
insert into public.inventory_purchases(item_id, qty, unit_cost, notes) values (pg_temp.id('82'), 1, null, 'Admin receipt [key:zz-s134-r3-key-0003:g2] extra line with no price');
set constraints all immediate;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3c_a', public.admin_review_transaction_v1(pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0003'), 'approve');
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'error' = 'amount_incomplete' and v ->> 'where' = 'Inventory' from _t where k = 'r3c_a')
      and (select t.status = 'pending_review' and t.ocr_raw ->> 's134_incomplete' = 'true' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0003')),
  'fix r3 item 2: admin_review_transaction_v1 refuses to approve a row with an unpriced line (amount_incomplete, where Inventory); the row stays pending_review');
select pg_temp.as_service();
insert into _t select 'r3c_t', public.telegram_expense_review_v1(pg_temp.sid('rcpt:zz-s134-r3-key-0003'), 'confirm', '{}'::jsonb, 'Cassy');
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'error' = 'amount_incomplete' and v ->> 'where' = 'Inventory' from _t where k = 'r3c_t')
      and (select t.status = 'pending_review' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0003')),
  'fix r3 item 2: telegram_expense_review_v1 refuses to confirm the same row (amount_incomplete, where Inventory)');

-- (3b) fix r4: admin_review_queue_v1 rows carry s134_incomplete (true for the incomplete pending stock row, false for an ordinary pending row)
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes) values
  (pg_temp.id('fa'), pg_temp.id('b3'), 'expense', 'other', 'pending_review', 'manual', public.manila_today(), 33, 'Zz S134 r4 plain pending');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r4q', public.admin_review_queue_v1(pg_temp.id('b3'));
reset role;
select ok((select (r ->> 's134_incomplete')::boolean is true and jsonb_typeof(r -> 's134_incomplete') = 'boolean' from _t, jsonb_array_elements(v -> 'rows') r where k = 'r4q' and (r ->> 'id')::uuid = pg_temp.tid('rcpt:zz-s134-r3-key-0003')),
  'fix r4: admin_review_queue_v1 returns s134_incomplete = true for an incomplete pending stock row');
select ok((select (r ->> 's134_incomplete')::boolean is false and jsonb_typeof(r -> 's134_incomplete') = 'boolean' from _t, jsonb_array_elements(v -> 'rows') r where k = 'r4q' and (r ->> 'id')::uuid = pg_temp.id('fa'))
      and (select v ->> 'count' from _t where k = 'r4q') = (select count(*)::text from public.transactions t where t.property_id = pg_temp.id('b3') and t.status = 'pending_review' and not (t.source = 'direct_booking' and t.booking_id is not null)),
  'fix r4: admin_review_queue_v1 returns s134_incomplete = false for an ordinary pending row; count and shape are the s89 ones');

-- (3c) fix r5: the queue never raises on a client-written ocr_raw (s134_incomplete as a JSON string); admin_save_transaction_v1 (s89, granted to authenticated) cannot write or clear the server's s134 keys
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes, ocr_raw) values
  (pg_temp.id('fb'), pg_temp.id('b3'), 'expense', 'other', 'pending_review', 'manual', public.manila_today(), 34, 'Zz S134 r5 junk marker', '{"s134_incomplete": "x"}'::jsonb),
  (pg_temp.id('fc'), pg_temp.id('b3'), 'expense', 'other', 'pending_review', 'manual', public.manila_today(), 35, 'Zz S134 r5 string true', '{"s134_incomplete": "true"}'::jsonb),
  (pg_temp.id('fd'), pg_temp.id('b3'), 'expense', 'other', 'pending_review', 'manual', public.manila_today(), 36, 'Zz S134 r5 stock-marked row', '{"s134_incomplete": "true", "s134_amount": "12", "s134_auto": "false", "s134_group": "zz-r5", "keep": 1}'::jsonb);
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r5q', pg_temp.try('select public.admin_review_queue_v1(''' || pg_temp.id('b3') || '''::uuid)');
reset role;
select ok((select v ? 'err' is false from _t where k = 'r5q')
      and (select (r ->> 's134_incomplete')::boolean is false and jsonb_typeof(r -> 's134_incomplete') = 'boolean' from _t, jsonb_array_elements(v -> 'rows') r where k = 'r5q' and (r ->> 'id')::uuid = pg_temp.id('fb')),
  'fix r5: admin_review_queue_v1 does not raise when ocr_raw.s134_incomplete is a non-boolean JSON string; that row returns false');
select ok((select (r ->> 's134_incomplete')::boolean is true from _t, jsonb_array_elements(v -> 'rows') r where k = 'r5q' and (r ->> 'id')::uuid = pg_temp.id('fc')),
  'fix r5: admin_review_queue_v1 returns true for s134_incomplete = the JSON string "true" (same reading as approve)');
select pg_temp.upload(pg_temp.id('b3'), pg_temp.id('01'), '8a', repeat('8a', 32));
select pg_temp.upload(pg_temp.id('b3'), pg_temp.id('01'), '8b', repeat('8b', 32));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r5i', public.admin_save_transaction_v1(pg_temp.id('b3'),
  json_build_object('txn_type', 'expense', 'gross_amount', 7, 'transaction_date', public.manila_today(), 'category', 'other', 'receipt_image_path', pg_temp.rpath(pg_temp.id('b3'), pg_temp.id('01'), '8a'),
    'ocr_raw', json_build_object('s134_incomplete', false, 's134_amount', 1, 's134_auto', true, 's134_group', 'x', 's134_backfill', true, 'keep', 1))::jsonb, 'zz-s134-r5-key-0001');
insert into _t select 'r5u', public.admin_save_transaction_v1(pg_temp.id('b3'),
  json_build_object('id', pg_temp.id('fd'), 'reason', 'zz r5', 'receipt_image_path', pg_temp.rpath(pg_temp.id('b3'), pg_temp.id('01'), '8b'),
    'ocr_raw', json_build_object('s134_incomplete', false, 's134_amount', 999, 's134_auto', true, 's134_group', 'y', 'keep', 2))::jsonb, 'zz-s134-r5-key-0002');
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'r5i')
      and (select t.ocr_raw = '{"keep": 1}'::jsonb from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'r5i')),
  'fix r5: admin_save_transaction_v1 strips the client''s s134_* keys from ocr_raw on insert (the other keys stay)');
select ok((select (v ->> 'ok')::boolean from _t where k = 'r5u')
      and (select t.receipt_image_path = pg_temp.rpath(pg_temp.id('b3'), pg_temp.id('01'), '8b') and t.ocr_raw ->> 's134_incomplete' = 'true' and t.ocr_raw ->> 's134_amount' = '12' and t.ocr_raw ->> 's134_auto' = 'false'
                  and t.ocr_raw ->> 's134_group' = 'zz-r5' and (t.ocr_raw -> 'keep') = '2'::jsonb
             from public.transactions t where t.id = pg_temp.id('fd')),
  'fix r5: admin_save_transaction_v1 on an edit keeps the row''s own s134_* keys (s134_incomplete stays true) while the client''s other ocr_raw keys are written');

-- (4) item 3: a receipt attached to the incomplete owned row keeps the marker (and the other system keys)
select pg_temp.upload(pg_temp.id('b3'), pg_temp.id('01'), '86', repeat('86', 32));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3c_r', public.expense_receipt_set_v1(pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0003'), pg_temp.rpath(pg_temp.id('b3'), pg_temp.id('01'), '86'), null);
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'r3c_r')
      and (select t.receipt_image_path = pg_temp.rpath(pg_temp.id('b3'), pg_temp.id('01'), '86') and t.ocr_raw ->> 's134_incomplete' = 'true' and t.ocr_raw ->> 's134_auto' = 'false'
                  and (t.ocr_raw ->> 's134_amount')::numeric = 10 and t.ocr_raw ->> 'receipt_sha256' = repeat('86', 32)
             from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0003')),
  'fix r3 item 3: attaching a receipt to an owned incomplete row keeps ocr_raw.s134_incomplete (and s134_auto, s134_amount)');

-- (5) pricing the unpriced line clears the marker; a plain approve then works
set constraints all deferred;
update public.inventory_purchases set unit_cost = 3 where expense_group = 'rcpt:zz-s134-r3-key-0003' and unit_cost is null;
set constraints all immediate;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3c_ok', public.admin_review_transaction_v1(pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0003'), 'approve');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'status' = 'confirmed' from _t where k = 'r3c_ok')
      and (select t.status = 'confirmed' and t.gross_amount = 13 and t.ocr_raw ->> 's134_incomplete' = 'false' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0003')),
  'fix r3 item 2: once the line is priced the marker is false and a normal approve still works (confirmed, P13)');

-- (6) the reopened row of (1) is sync-owned with linked purchases: amount, date and payee edits are refused; a system category is refused; a category and note edit approves
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3d_a', pg_temp.try(format('select public.admin_review_transaction_v1(%L::uuid, %L::uuid, %L, %L::jsonb, %L)', pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0001'), 'approve', '{"gross_amount": 99}', 'bigger'));
insert into _t select 'r3d_d', pg_temp.try(format('select public.admin_review_transaction_v1(%L::uuid, %L::uuid, %L, %L::jsonb, %L)', pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0001'), 'approve', jsonb_build_object('transaction_date', public.manila_today() - 1), 'older'));
insert into _t select 'r3d_p', pg_temp.try(format('select public.admin_review_transaction_v1(%L::uuid, %L::uuid, %L, %L::jsonb, %L)', pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0001'), 'approve', '{"payee_name": "Someone else"}', 'other shop'));
insert into _t select 'r3d_s', pg_temp.try(format('select public.admin_review_transaction_v1(%L::uuid, %L::uuid, %L, %L::jsonb, %L)', pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0001'), 'approve', '{"category": "guest_refund"}', 'refund'));
reset role;
select ok((select bool_and(v ->> 'ok' = 'false' and v ->> 'error' = 'amount_locked' and v ->> 'where' = 'Inventory') from _t where k in ('r3d_a', 'r3d_d', 'r3d_p'))
      and (select v ->> 'ok' = 'false' and v ->> 'error' = 'system_category' from _t where k = 'r3d_s')
      and (select t.status = 'pending_review' and t.gross_amount = 24 and t.category = 'supplies' and t.payee_name = 'Zz S134 Shop' from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0001')),
  'fix r3 item 2: approving with an amount, date or payee edit on a sync-owned stock row is refused (amount_locked, Inventory); a system category is refused (system_category); the row is untouched');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3d_ok', public.admin_review_transaction_v1(pg_temp.id('b3'), pg_temp.sid('rcpt:zz-s134-r3-key-0001'), 'approve', '{"category": "maintenance", "notes": "Zz S134 r3 own note"}', 'checked');
reset role;
select ok((select (v ->> 'ok')::boolean and v ->> 'status' = 'confirmed' from _t where k = 'r3d_ok')
      and (select t.status = 'confirmed' and t.category = 'maintenance' and t.notes = 'Zz S134 r3 own note' and t.gross_amount = 24 from public.transactions t where t.id = pg_temp.tid('rcpt:zz-s134-r3-key-0001')),
  'fix r3 item 2: an approve that edits only category and note still works on a sync-owned stock row');

-- (7) a staff pay row keeps its category in the review queue
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes) values
  (pg_temp.id('85'), pg_temp.id('b3'), 'expense', 'cleaning', 'pending_review', 'cleaner_fee', public.manila_today(), 250, 'Zz S134 r3 staff pay row');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3e', public.admin_review_transaction_v1(pg_temp.id('b3'), pg_temp.id('85'), 'approve', '{"category": "other"}', 'recategorise');
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'error' = 'locked' and v ->> 'where' = 'Pay staff' from _t where k = 'r3e')
      and (select t.status = 'pending_review' and t.category = 'cleaning' from public.transactions t where t.id = pg_temp.id('85')),
  'fix r3 item 2: a category edit on a cleaner_fee row is refused (locked, where Pay staff); the row is untouched');

-- (8) item 4: s134_incomplete from a client ocr_raw is stripped (admin create and Telegram save)
select pg_temp.upload(pg_temp.id('b3'), pg_temp.id('01'), '87', repeat('87', 32));
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3f', public.admin_save_transaction_v2(pg_temp.id('b3'), jsonb_build_object('txn_type', 'expense', 'category', 'other', 'gross_amount', 5, 'transaction_date', public.manila_today(),
    'receipt_image_path', pg_temp.rpath(pg_temp.id('b3'), pg_temp.id('01'), '87'), 'ocr_raw', jsonb_build_object('s134_incomplete', true, 'keep', 1)), 'zz-s134-r3-save-key-0001');
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'r3f')
      and (select not (t.ocr_raw ? 's134_incomplete') and t.ocr_raw ->> 'keep' = '1' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'r3f')),
  'fix r3 item 4: admin_save_transaction_v2 (create) drops s134_incomplete from a client ocr_raw and keeps the other keys');
select pg_temp.as_service();
insert into _t select 'r3g', public.telegram_expense_save_v1(pg_temp.id('b3'), jsonb_build_object('amount', 6, 'category', 'other', 'ocr_raw', jsonb_build_object('s134_incomplete', true, 'keep', 1)), 'tg:zz-s134-r3-key-000001');
reset role;
select ok((select (v ->> 'ok')::boolean from _t where k = 'r3g')
      and (select not (t.ocr_raw ? 's134_incomplete') and t.ocr_raw ->> 'keep' = '1' from public.transactions t where t.id = (select (v ->> 'id')::uuid from _t where k = 'r3g')),
  'fix r3 item 4: telegram_expense_save_v1 drops s134_incomplete from a client ocr_raw and keeps the other keys');

-- (9) item 5: the screen row carries lookalike = {id, date, amount, chip} (and still lookalike_id)
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, notes) values
  (pg_temp.id('84'), pg_temp.id('b3'), 'expense', 'supplies', 'confirmed', 'manual', public.manila_today(), 25, 'Zz S134 r3 manual supplies');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t select 'r3s', public.expenses_screen_v1(pg_temp.id('b3'));
reset role;
select ok((select (r -> 'lookalike' ->> 'id')::uuid = pg_temp.id('84') and r -> 'lookalike' ->> 'date' = public.manila_today()::text and (r -> 'lookalike' ->> 'amount')::numeric = 25 and r -> 'lookalike' ->> 'chip' = 'manual'
                  and (select count(*) = 4 from jsonb_object_keys(r -> 'lookalike')) and r ->> 'lookalike_id' = pg_temp.id('84')::text
             from _t, jsonb_array_elements(v -> 'rows') r where k = 'r3s' and (r ->> 'id')::uuid = pg_temp.tid('rcpt:zz-s134-r3-key-0001'))
      and (select jsonb_typeof(r -> 'lookalike') = 'null' and r ->> 'lookalike_id' is null from _t, jsonb_array_elements(v -> 'rows') r where k = 'r3s' and (r ->> 'id')::uuid = pg_temp.id('85')),
  'fix r3 item 5: expenses_screen_v1 rows carry lookalike {id, date, amount, chip} next to lookalike_id; null when there is none');

select * from finish();
rollback;
