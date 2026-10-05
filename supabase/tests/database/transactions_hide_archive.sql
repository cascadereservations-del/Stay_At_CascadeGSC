-- Session 71, Finance > Transactions: admin_transactions_bulk_v1 (hide, unhide, archive, restore).
-- Synthetic property, owner (aal2) and cleaner; inside begin/rollback. The money check uses the real run_health_checks_v1
-- ledger_position (confirmed, non-mirror rows: the same rule the dashboard totals use), so "out of the totals" is measured, not assumed.
begin;
select plan(43);

select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.admin_transactions_bulk_v1(uuid,uuid[],text,text)'::regprocedure),
  'the RPC is security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.admin_transactions_bulk_v1(uuid,uuid[],text,text)', 'execute'), 'anon cannot call it');
select ok(has_function_privilege('authenticated', 'public.admin_transactions_bulk_v1(uuid,uuid[],text,text)', 'execute'), 'authenticated can call it');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.admin_transactions_bulk_v1(uuid,uuid[],text,text)'::regprocedure and a.grantee = 0),
  'PUBLIC has no execute grant');

-- Fixtures. P: income 1000 (T1), expenses 300 (T2) and 200 (T3), a void telegram row (T4), a direct booking payment tied to a live booking (T5).
insert into public.properties(id, name, is_active) values ('e7100000-0000-4000-8000-0000000000a1', 'Synthetic Txn Actions', true);
insert into public.properties(id, name, is_active) values ('e7100000-0000-4000-8000-0000000000a2', 'Synthetic Other Property', true);
insert into auth.users(id) values ('e7200000-0000-4000-8000-0000000000a1'), ('e7200000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id, role) values ('e7200000-0000-4000-8000-0000000000a1', 'owner'), ('e7200000-0000-4000-8000-0000000000a2', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values ('e7200000-0000-4000-8000-0000000000a2', 'e7100000-0000-4000-8000-0000000000a1');
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status)
  values ('e7400000-0000-4000-8000-0000000000a1', 'e7100000-0000-4000-8000-0000000000a1', 'Synthetic Guest', '0000000000', current_date + 10, current_date + 12, 'direct', 'confirmed');
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, payee_name, booking_id) values
  ('e7300000-0000-4000-8000-0000000000a1', 'e7100000-0000-4000-8000-0000000000a1', 'income',  'direct_income', 'confirmed', 'manual',   current_date - 5, 1000, 'Zz income', null),
  ('e7300000-0000-4000-8000-0000000000a2', 'e7100000-0000-4000-8000-0000000000a1', 'expense', 'supplies',      'confirmed', 'manual',   current_date - 4, 300,  'Zz supplies', null),
  ('e7300000-0000-4000-8000-0000000000a3', 'e7100000-0000-4000-8000-0000000000a1', 'expense', 'cleaning',      'confirmed', 'manual',   current_date - 3, 200,  'Zz cleaning', null),
  ('e7300000-0000-4000-8000-0000000000a4', 'e7100000-0000-4000-8000-0000000000a1', 'expense', 'other',         'void',      'telegram', current_date - 2, 50,   'Zz already void', null),
  ('e7300000-0000-4000-8000-0000000000a5', 'e7100000-0000-4000-8000-0000000000a1', 'income',  'direct_income', 'confirmed', 'direct_booking', current_date - 1, 400, 'Zz direct', 'e7400000-0000-4000-8000-0000000000a1');

select throws_ok($$update public.transactions set archived_at = now() where id = 'e7300000-0000-4000-8000-0000000000a1'$$, '23514', null,
  'the table itself refuses an archived row that is not void');

grant select on public.transactions, public.admin_audit_log to authenticated;
create function pg_temp.net() returns numeric language sql as $$
  select (c->'detail'->>'net')::numeric from jsonb_array_elements(public.run_health_checks_v1('e7100000-0000-4000-8000-0000000000a1')->'checks') c where c->>'check_key' = 'ledger_position'
$$;

select set_config('request.jwt.claims', json_build_object('sub', 'e7200000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'aal', 'aal2', 'app_metadata', json_build_object('role', 'owner'), 'iat', extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);

select is(pg_temp.net(), 900::numeric, 'baseline cash position: 1000 + 400 income - 300 - 200 expenses = 900');

-- Hide: display only.
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a2']::uuid[], 'hide', null)->>'changed')::int, 1, 'hide changes one row');
select ok((select hidden_at is not null and hidden_by = 'e7200000-0000-4000-8000-0000000000a1' and status = 'confirmed' from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a2'),
  'the row is stamped with who hid it and stays confirmed');
select is(pg_temp.net(), 900::numeric, 'hide does not change the totals');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a2']::uuid[], 'hide', null)->>'skipped')::int, 1, 'hiding an already hidden row is reported as skipped, not an error');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a2']::uuid[], 'unhide', null)->>'changed')::int, 1, 'unhide changes one row');
select ok((select hidden_at is null and hidden_by is null from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a2'), 'unhide clears the stamp');

-- Archive: out of the totals, restorable.
select throws_ok($$select public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a3']::uuid[], 'archive', ' ')$$, '22023', 'a reason is required', 'archive needs a reason');
select is(pg_temp.net(), 900::numeric, 'a refused archive changed nothing');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a3', 'e7300000-0000-4000-8000-0000000000a3']::uuid[], 'archive', 'duplicate entry')->>'amount')::numeric, 200::numeric,
  'archive reports the amount archived once, even if the id is sent twice');
select ok((select status = 'void' and archived_at is not null and archived_prev_status = 'confirmed' and archived_by = 'e7200000-0000-4000-8000-0000000000a1' from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a3'),
  'the row is void, stamped, and remembers it was confirmed; it is never deleted');
select is(pg_temp.net(), 1100::numeric, 'the archived expense left the totals (900 + 200)');
select is((select count(*)::int from public.admin_audit_log where entity_table = 'transactions' and entity_id = 'e7300000-0000-4000-8000-0000000000a3' and action = 'soft_delete' and reason = 'duplicate entry' and actor_user_id = 'e7200000-0000-4000-8000-0000000000a1'), 1,
  'the archive is in the audit log with its reason and actor');
select throws_ok($$select public.admin_save_transaction_v1('e7100000-0000-4000-8000-0000000000a1', '{"id":"e7300000-0000-4000-8000-0000000000a3","gross_amount":"1","reason":"try edit"}'::jsonb, null)$$, '22023', 'a void transaction cannot be edited; undo the void first',
  'an archived row cannot be edited');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a3']::uuid[], 'restore', 'archived by mistake')->>'changed')::int, 1, 'restore changes one row');
select ok((select status = 'confirmed' and archived_at is null and archived_by is null and archived_prev_status is null from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a3'), 'restore puts the old status back and clears the stamps');
select is(pg_temp.net(), 900::numeric, 'the restored row counts again');

-- An already voided row archives without becoming live on restore; undo reverses an archive.
select is((select status from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a4'), 'void', 'T4 starts void');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a4']::uuid[], 'archive', 'clear old void')->>'changed')::int, 1, 'a void row can be archived');
select is((select status from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a4'), 'void', 'archived void row stays void');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a4']::uuid[], 'restore', 'back to voided')->>'changed')::int, 1, 'restoring an archived void row works');
select is((select status from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a4'), 'void', 'and returns it to voided, not live');

-- Edit writes the change (existing RPC, exercised here so the list actions cannot regress it).
select is((public.admin_save_transaction_v1('e7100000-0000-4000-8000-0000000000a1', '{"id":"e7300000-0000-4000-8000-0000000000a2","gross_amount":"350","reason":"receipt says 350"}'::jsonb, null)->>'ok')::boolean, true, 'edit succeeds');
select is((select gross_amount from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a2'), 350::numeric, 'edit wrote the new amount');

-- Guards.
select throws_ok($$select public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a5']::uuid[], 'archive', 'try it')$$, '22023', null, 'a live direct booking payment cannot be archived');
select throws_ok($$select public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a2', array['e7300000-0000-4000-8000-0000000000a1']::uuid[], 'hide', null)$$, 'P0002', 'one or more transactions were not found for this property', 'a row from another property is refused, not touched');
select throws_ok($$select public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', '{}'::uuid[], 'hide', null)$$, '22023', 'select at least one transaction', 'an empty selection is refused');

select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a2', 'e7300000-0000-4000-8000-0000000000a3']::uuid[], 'hide', null)->'ids'), '["e7300000-0000-4000-8000-0000000000a2", "e7300000-0000-4000-8000-0000000000a3"]'::jsonb, 'the result lists the ids it changed, so an undo can invert exactly those');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a2', 'e7300000-0000-4000-8000-0000000000a3']::uuid[], 'hide', null)->'ids'), '[]'::jsonb, 'a row already in the target state is not listed');
select is((public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a2', 'e7300000-0000-4000-8000-0000000000a3']::uuid[], 'unhide', null)->>'changed')::int, 2, 'the inverse action with those ids puts both back in one call');

-- Undo from Settings > Audit history reverses an archive in full.
select public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a3']::uuid[], 'archive', 'archive then undo');
select is((public.admin_undo_v1((select id from public.admin_audit_log where entity_table = 'transactions' and entity_id = 'e7300000-0000-4000-8000-0000000000a3' and action = 'soft_delete' and reason = 'archive then undo'), 'undo archive')->>'ok')::boolean, true, 'undo of an archive succeeds');
select ok((select status = 'confirmed' and archived_at is null from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a3'), 'and the row is live again with no archive stamp');

select set_config('request.jwt.claims', json_build_object('sub', 'e7200000-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$select public.admin_transactions_bulk_v1('e7100000-0000-4000-8000-0000000000a1', array['e7300000-0000-4000-8000-0000000000a1']::uuid[], 'archive', 'cleaner tries')$$, '42501', 'approve_payment denied', 'an unauthorised caller is refused');

reset role;
select is((select count(*)::int from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a1' and status = 'confirmed' and archived_at is null), 1, 'the refused call changed nothing');

-- The compensating rollback must work once a row is archived: archive T3, run the rollback body (same statements, same order), check the row.
update public.transactions set archived_at = now(), archived_prev_status = status, status = 'void' where id = 'e7300000-0000-4000-8000-0000000000a3';
select lives_ok($$
  update public.transactions set status = coalesce(archived_prev_status, 'void'), archived_at = null, archived_by = null, archived_prev_status = null where archived_at is not null;
  drop function if exists public.admin_transactions_bulk_v1(uuid, uuid[], text, text);
  alter table public.transactions drop constraint if exists transactions_archived_is_void_check;
  alter table public.transactions
    drop column if exists hidden_at, drop column if exists hidden_by,
    drop column if exists archived_at, drop column if exists archived_by, drop column if exists archived_prev_status;
$$, 'the rollback body runs cleanly with an archived row present');
select is((select status from public.transactions where id = 'e7300000-0000-4000-8000-0000000000a3'), 'confirmed', 'rollback put the archived row back to confirmed');
select is((select count(*)::int from information_schema.columns where table_schema = 'public' and table_name = 'transactions' and column_name in ('hidden_at', 'archived_at')), 0, 'rollback dropped the columns');
select is((select count(*)::int from pg_proc where proname = 'admin_transactions_bulk_v1' and pronamespace = 'public'::regnamespace), 0, 'rollback dropped the function');

select * from finish();
rollback;
