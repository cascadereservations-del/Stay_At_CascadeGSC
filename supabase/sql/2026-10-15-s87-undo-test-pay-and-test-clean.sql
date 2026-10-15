-- One-off reviewed SQL (session 87, Lloyd 2026-10-15: "delete created TEST entries"; and, asked
-- whether Honey was really paid the 1,340: "Not paid - undo it"). Run with run-sql-on-host.sh from
-- this repo. Every statement is keyed on explicit ids; a re-run finds nothing and the guard at the
-- top stops it (nothing changes).
--
-- A. The payment-proof test (13:00Z): staff_pay_requests 5f955045 (ref 5F955045, PHP 1,340, proof
--    reference 'TEST') was made from Honey's REAL unpaid lines and settled by staff_pay_settle_v1:
--      cleans 0f88c251 (Angeleen, Oct 11, 650) and 768aabea (Rohamidin, Oct 13, 650)
--        -> fee_amount, fee_paid_at, fee_txn_id and pay_request_id set
--      claims 5c64d9d6 (sugar, Oct 4, 20) and d3bf2dd1 (sugar, Oct 5, 20)
--        -> status 'paid', reviewed_at, review_note and pay_request_id set
--      transactions 4874ac03, e61e584c (cleaning 650 each), 3a8f57ec, 8dcac276 (supplies 20 each),
--        all source cleaner_fee, no acct_journals posted (checked: none in the window)
--    Undo = put every one of those columns back to its state before the request, delete the four
--    transactions and the request. Before: both claims were never reviewed (updated_at = created_at,
--    reviewed_by_user_id null), so status goes back to the column default 'pending_review'; both
--    sessions had pay_request_id null (staff_pay_admin_create_v1 refuses a session that has one) and
--    were unpaid (fee_paid_at null). fee_amount is cleared too: it is written only by the settle.
--    Afterwards the four lines show as unpaid in Pay staff and can be paid for real.
--
-- B. The checklist test (13:03-13:06Z): cleaning_sessions 975d32e4 (submission 2d40771f, cleaner
--    Honey's account, last_guest_name 'TEST', check-in Oct 14, out Oct 15; no real stay). Its meter
--    reading 214da77b reads electric 4209 -> 4209 and water 80.1710 -> 80.1710, delta exactly 0, so
--    the next real reading compares against the same numbers either way. Children: 1 meter_readings,
--    1 cleaning_diagnostics; zero claims, evidence, usage, readiness or turnover_verification rows.
--    staff_upload_hashes rows of its 18 photos are deleted so the same photo is not refused later.
--
-- NOT deleted: the admin_audit_log rows of the test; one 'undo' row is added for this undo (undo_of = the paid update).
-- Also by hand: the test clean's Drive folder 15fgawV_EtuQtu6VZnoV1YU2OIkkhQnvw and any TEST turnover-report email.
-- STILL OWED, only by hand (SQL cannot delete Storage objects): in the Supabase dashboard, Storage ->
--   cleaning-photos/6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/
--     50ccca5a-3e59-4299-9680-837fd8d88ac4/2d40771f-49d7-4c94-96dc-4b8376c09194/   (18 photos)
--     0017d405-bc68-4190-bdab-366d7adea4e0/20a53f35-df27-431d-a498-d52bfe94ad0c/   (1 payment proof)
-- and tell Honey the "paid" notice at 13:00Z was a test.

begin;

set local cascade.audit_reason = 'session 87 undo of a test pay request (5F955045) and a test checklist (TEST)';

-- Guard: stop unless every row is exactly as the test left it.
do $$
begin
  if (select count(*) from public.staff_pay_requests where id = '5f955045-c66a-42d7-8618-04620c859249'
        and status = 'paid' and proof_reference = 'TEST' and total_amount = 1340.00) <> 1 then
    raise exception 'pay request 5F955045 is not the paid TEST request (already undone?)';
  end if;
  if (select count(*) from public.cleaning_sessions where id in ('0f88c251-b901-4e89-bded-28bd92b69288', '768aabea-13b6-4758-ae17-1d3fd7eb6eb5')
        and pay_request_id = '5f955045-c66a-42d7-8618-04620c859249') <> 2 then
    raise exception 'the two cleans are not on request 5F955045';
  end if;
  if (select count(*) from public.cleaning_expense_claims where id in ('5c64d9d6-93c0-47b4-b7c2-abb7b5526930', 'd3bf2dd1-9272-40da-8e37-10d5069369ff')
        and pay_request_id = '5f955045-c66a-42d7-8618-04620c859249' and status = 'paid' and reviewed_by_user_id is null) <> 2 then
    raise exception 'the two sugar claims are not the paid lines of 5F955045';
  end if;
  if (select count(*) from public.transactions where id in ('4874ac03-047b-4590-ab7b-2441d9dcf9b3', 'e61e584c-2c7f-476a-88ed-4ae7f486600e',
        '3a8f57ec-fd26-4bef-b585-19f324370d33', '8dcac276-c3ab-4016-9acc-d8c156692454') and source = 'cleaner_fee' and notes like '%Pay request 5F955045.%') <> 4 then
    raise exception 'the four ledger rows are not the 5F955045 rows';
  end if;
  if (select count(*) from public.cleaning_sessions where id = '975d32e4-5425-4dc9-8ec3-8f240933f3e5'
        and last_guest_name = 'TEST' and pay_request_id is null and fee_paid_at is null) <> 1 then
    raise exception 'cleaning session 975d32e4 is not the unpaid TEST submission';
  end if;
end $$;

-- A. The pay test. Sessions first (fee_txn_id has a FK to transactions).
update public.cleaning_sessions
   set fee_amount = null, fee_paid_at = null, fee_txn_id = null, pay_request_id = null
 where id in ('0f88c251-b901-4e89-bded-28bd92b69288', '768aabea-13b6-4758-ae17-1d3fd7eb6eb5');

update public.cleaning_expense_claims
   set status = 'pending_review', reviewed_at = null, review_note = null, pay_request_id = null
 where id in ('5c64d9d6-93c0-47b4-b7c2-abb7b5526930', 'd3bf2dd1-9272-40da-8e37-10d5069369ff');

delete from public.transactions
 where id in ('4874ac03-047b-4590-ab7b-2441d9dcf9b3', 'e61e584c-2c7f-476a-88ed-4ae7f486600e',
              '3a8f57ec-fd26-4bef-b585-19f324370d33', '8dcac276-c3ab-4016-9acc-d8c156692454');

delete from public.staff_pay_requests where id = '5f955045-c66a-42d7-8618-04620c859249';

delete from public.staff_upload_hashes
 where path = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/0017d405-bc68-4190-bdab-366d7adea4e0/20a53f35-df27-431d-a498-d52bfe94ad0c/e1c2a9d5-a2bc-4c1a-b558-d479cb531487-payment-proof.jpg';

-- B. The checklist test. Children first.
delete from public.meter_readings where session_id = '975d32e4-5425-4dc9-8ec3-8f240933f3e5';
delete from public.cleaning_diagnostics where session_id = '975d32e4-5425-4dc9-8ec3-8f240933f3e5';
delete from public.cleaning_sessions where id = '975d32e4-5425-4dc9-8ec3-8f240933f3e5';
delete from public.staff_upload_hashes
 where path like '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/50ccca5a-3e59-4299-9680-837fd8d88ac4/2d40771f-49d7-4c94-96dc-4b8376c09194/%';

-- Forward check: refuse to commit unless the four lines are unpaid and free again and every test row is gone.
do $$
declare v int;
begin
  select count(*) into v from public.cleaning_sessions
   where id in ('0f88c251-b901-4e89-bded-28bd92b69288', '768aabea-13b6-4758-ae17-1d3fd7eb6eb5')
     and pay_request_id is null and fee_paid_at is null and fee_txn_id is null;
  if v <> 2 then raise exception 'the two cleans are not unpaid and free: %', v; end if;
  select count(*) into v from public.cleaning_expense_claims
   where id in ('5c64d9d6-93c0-47b4-b7c2-abb7b5526930', 'd3bf2dd1-9272-40da-8e37-10d5069369ff')
     and pay_request_id is null and status = 'pending_review';
  if v <> 2 then raise exception 'the two claims are not pending and free: %', v; end if;
  select count(*) into v from public.transactions
   where external_ref in ('cleanfee:0f88c251-b901-4e89-bded-28bd92b69288', 'cleanfee:768aabea-13b6-4758-ae17-1d3fd7eb6eb5',
                          'claim:5c64d9d6-93c0-47b4-b7c2-abb7b5526930', 'claim:d3bf2dd1-9272-40da-8e37-10d5069369ff') and status <> 'void';
  if v <> 0 then raise exception 'a ledger row for these lines survived: %', v; end if;
  select count(*) into v from public.staff_pay_requests where id = '5f955045-c66a-42d7-8618-04620c859249';
  if v <> 0 then raise exception 'request 5F955045 survived'; end if;
  select count(*) into v from public.cleaning_sessions where id = '975d32e4-5425-4dc9-8ec3-8f240933f3e5';
  if v <> 0 then raise exception 'test session survived'; end if;
  select count(*) into v from public.staff_upload_hashes
   where path like '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/50ccca5a-3e59-4299-9680-837fd8d88ac4/2d40771f-49d7-4c94-96dc-4b8376c09194/%'
      or path like '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/0017d405-bc68-4190-bdab-366d7adea4e0/20a53f35-df27-431d-a498-d52bfe94ad0c/%';
  if v <> 0 then raise exception 'upload hashes survived: %', v; end if;
  raise notice 'undone: request 5F955045 and its 4 ledger rows; Honey''s 2 cleans and 2 sugar claims are unpaid again; test clean 975d32e4 with its reading, diagnostics and 19 upload hashes deleted';
end $$;

insert into public.admin_audit_log(property_id, entity_table, entity_id, action, before_state, after_state, reason, undo_of)
select property_id, 'staff_pay_requests', entity_id, 'undo', after_state, null, current_setting('cascade.audit_reason', true), id
  from public.admin_audit_log
 where entity_table = 'staff_pay_requests' and entity_id = '5f955045-c66a-42d7-8618-04620c859249' and after_state->>'status' = 'paid'
 order by created_at limit 1;

commit;
