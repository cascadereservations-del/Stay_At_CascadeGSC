begin;
select plan(20);

select has_table('public','acct_journals','journals table exists');
select has_table('public','acct_journal_lines','journal lines table exists');
select has_function('public','post_journal_v1',array['uuid','date','text','jsonb','text','text','text','text','text','text'],'posting RPC exists');
select ok(not has_table_privilege('authenticated','public.acct_journals','insert'),'journals are written only through the RPC');

insert into public.properties(id,name,is_active) values('e1000000-0000-4000-8000-0000000000b1','Synthetic Ledger',true);
insert into auth.users(id) values('e2000000-0000-4000-8000-0000000000b1');
insert into public.staff_access_profiles(user_id,role) values('e2000000-0000-4000-8000-0000000000b1','owner');
select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000000b1','role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);

select ok((public.acct_seed_chart_v1('e1000000-0000-4000-8000-0000000000b1')->>'inserted')::int = 29,'chart of accounts seeded');

-- Posting before opening balances is refused.
select throws_ok($$select public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-05','Too early','[{"account_code":"1010","debit":"10","credit":"0"},{"account_code":"3000","debit":"0","credit":"10"}]',null,null,null,null,'key-000000000000-too-early')$$,'22023','accounting start date is not set; complete opening balances first','no posting before opening balances');

-- Opening balances must balance exactly.
create temp table ob as select (public.save_opening_balance_batch_v1('e1000000-0000-4000-8000-0000000000b1', jsonb_build_object('accounting_start','2026-03-01','reference_notes','Bank statement 2026-02-28','lines',jsonb_build_array(jsonb_build_object('account_code','1010','debit','50000','credit','0'),jsonb_build_object('account_code','3000','debit','0','credit','40000'))))) res;
select throws_like($$select public.approve_opening_balances_v1((select (res->>'id')::uuid from ob),'ok','key-000000000000-ob-unbalanced')$$,'%do not balance (difference 10000%','unbalanced opening batch is refused with the difference');
select ok((public.save_opening_balance_batch_v1('e1000000-0000-4000-8000-0000000000b1', jsonb_build_object('id',(select res->>'id' from ob),'expected_version',1,'lines',jsonb_build_array(jsonb_build_object('account_code','1010','debit','50000','credit','0'),jsonb_build_object('account_code','3000','debit','0','credit','50000')))))->>'difference' = '0','balanced batch saved');
select ok((public.approve_opening_balances_v1((select (res->>'id')::uuid from ob),'reviewed','key-000000000000-ob-approve')->>'ok')::boolean,'balanced opening batch approved and posted');

-- Fixture: guest pays 6000 before a three-night stay -> cash +6000, advances +6000, no revenue.
select ok((public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-02','Deposit',(public.prepare_simple_entry_v1('e1000000-0000-4000-8000-0000000000b1','guest_deposit',jsonb_build_object('amount','6000','paid_into','1020')))->'lines',null,null,null,null,'key-000000000000-deposit-1')->>'ok')::boolean,'deposit posted');
select is((public.get_financial_statement_v1('e1000000-0000-4000-8000-0000000000b1','pnl','2026-03-01','2026-04-01')->'body'->>'totalIncome'),'0','no revenue earned yet after the deposit');
-- First night earned at 2000: advance -2000, revenue +2000.
select ok((public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-03','Night 1',(public.prepare_simple_entry_v1('e1000000-0000-4000-8000-0000000000b1','accommodation_earned',jsonb_build_object('amount','2000','channel','direct')))->'lines','airbnb_reservations','stay-1','night:2026-03-03',null,'key-000000000000-night-1')->>'ok')::boolean,'night earned');
select is((public.get_financial_statement_v1('e1000000-0000-4000-8000-0000000000b1','pnl','2026-03-01','2026-04-01')->'body'->>'totalIncome'),'2000.00','revenue recognised by night');
-- Duplicate economic event is rejected.
select throws_ok($$select public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-03','Night 1 again','[{"account_code":"2100","debit":"2000","credit":"0"},{"account_code":"4000","debit":"0","credit":"2000"}]','airbnb_reservations','stay-1','night:2026-03-03',null,'key-000000000000-night-1b')$$,'23505','this economic event is already posted; reverse it before posting again','one economic event posts once');
-- Idempotent replay returns the same journal; a different payload conflicts.
select ok((public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-02','Deposit',(public.prepare_simple_entry_v1('e1000000-0000-4000-8000-0000000000b1','guest_deposit',jsonb_build_object('amount','6000','paid_into','1020')))->'lines',null,null,null,null,'key-000000000000-deposit-1')->>'replayed')::boolean,'replay returns the existing journal');
select throws_ok($$select public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-02','Deposit changed','[{"account_code":"1020","debit":"1","credit":"0"},{"account_code":"2100","debit":"0","credit":"1"}]',null,null,null,null,'key-000000000000-deposit-1')$$,'23505','idempotency conflict: this key was used with a different payload','reused key with a different payload conflicts');
-- Owner contribution 10000: cash and equity up, profit unchanged. Transfer 1000 bank->GCash: totals unchanged.
select ok((public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-04','Contribution',(public.prepare_simple_entry_v1('e1000000-0000-4000-8000-0000000000b1','owner_contribution',jsonb_build_object('amount','10000','paid_into','1010')))->'lines',null,null,null,null,'key-000000000000-contrib-1')->>'ok')::boolean,'contribution posted');
select ok((public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-05','Transfer',(public.prepare_simple_entry_v1('e1000000-0000-4000-8000-0000000000b1','transfer',jsonb_build_object('amount','1000','from_code','1010','to_code','1020')))->'lines',null,null,null,null,'key-000000000000-transfer-1')->>'ok')::boolean,'transfer posted');
select is((public.get_financial_statement_v1('e1000000-0000-4000-8000-0000000000b1','pnl','2026-03-01','2026-04-01')->'body'->>'netProfit'),'2000.00','contribution and transfer do not touch profit');
select is((public.get_financial_statement_v1('e1000000-0000-4000-8000-0000000000b1','cash_flow','2026-03-01','2026-04-01')->'body'->>'financing'),'10000.00','contribution is a financing inflow');
-- Immutability.
select throws_ok($$update public.acct_journals set description = 'edited' where idempotency_key = 'key-000000000000-contrib-1'$$,'55000','posted journals are immutable; post a reversal','posted journals cannot be edited');
-- Close and correction in a closed period.
select ok((public.close_accounting_period_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-01','{"ingestion_verified":true,"cash_and_settlements_reconciled":true,"duplicates_and_classifications_resolved":true,"obligations_deposits_refunds_reviewed":true,"stock_and_depreciation_reviewed":true,"statement_identities_verified":true}','key-000000000000-close-mar')->>'ok')::boolean,'March closes with all identities holding');
select throws_ok($$select public.post_journal_v1('e1000000-0000-4000-8000-0000000000b1','2026-03-20','Late','[{"account_code":"5900","debit":"5","credit":"0"},{"account_code":"1000","debit":"0","credit":"5"}]',null,null,null,null,'key-000000000000-late-entry')$$,'22023','period is closed; reopen it with a reason or post a correction in an open period','closed period rejects direct edits');

select * from finish();
rollback;
