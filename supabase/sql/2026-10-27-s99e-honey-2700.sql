-- 2026-10-27 (session 99e, lane sql): record Honey's PHP 2,700 payment. NOT a migration; Lloyd's block runs it with scripts/migrations/run-sql-on-host.sh AFTER release
-- s99e_missed_and_pay_20261102 is applied (the 21 Oct checkout is only a payable "no report yet" date once get_missed_cleanings stops hiding it behind her late reports).
--
-- The money: BPI InstaPay 2026-10-27 12:40:39 Manila (04:40:39 UTC), confirmation 1630012121203, transaction reference 929016, PHP 2,700, paid by Lloyd.
--   Proof screenshot: docs/s99e/bpi-2700-20261027.png (126,104 bytes), sha256 d4e372ecc4955399b744c9acaa36ce4903750ce1cbd2e692c9ffc329164250c4.
--   = four turnovers, each 500 base + 150 transport = 650:
--       21 Oct (Ysabel)  no report yet  -> advance line
--       22 Oct (James)   no report yet  -> advance line
--       24 Oct (Francis) report filed   -> her unpaid cleaning_sessions row (checkout_date 2026-10-24) as a clean line
--       25 Oct (Dale)    no report yet  -> advance line
--   + her pending expense claim "2pcs KitKat" dated 2026-10-24, CORRECTED from PHP 50.00 to PHP 100.00 (Lloyd 2026-10-27: 2 pcs x 50) before it is paid.
--   Total 4 x 650 + 100 = 2,700.00; any other total aborts.
-- Same method as 2026-10-20-s94-honey-3250.sql: one transaction, acting as Lloyd (request.jwt.claims sub), staff_pay_admin_create_v2 with the session, the claim and the advance
-- dates, telegram_staff_pay_step_v1 'pay', staff_pay_settle_v1 with the BPI proof (writes cleanfee:, cleanadv: and claim: expense rows), then paid_at and the session's fee_paid_at set to
-- the real payment time. No storage object is needed (s94 needed none: the paid constraint wants proof_file_unique_id, proof_sha256, verdict, paid_at, paid_by_name).
-- KitKat correction: there is no admin edit path for a claim amount in the migrations (staff submit claims; finance only approves/pays them inside a request), so this is an audited
-- direct update in the same transaction: amount 100.00, review_note, and one admin_audit_log row (before/after, reason 'Lloyd 2026-10-27: 2 pcs x 50', actor Lloyd). Settling the
-- request then marks the claim paid (its review_note becomes the "Paid in request" line; the audit row keeps the correction).
--
-- Refuses (raises, nothing written):
--   * release s99e not applied (get_missed_cleanings is not the s99e body, md5 def6d3ea1ae7c3c05bc2ae178df2d0aa)
--   * request 520B672A missing, or not Honey's
--   * Honey has any non-cancelled request created after 520B672A (she may have filed one herself)
--   * a live advance line (any non-cancelled request) already holds 21, 22, 24 or 25 Oct, or a report already exists for 21, 22 or 25 Oct
--   * the 24 Oct report is not exactly one session of hers, unpaid and on no request
--   * the KitKat claim is not exactly one claim of hers, dated 2026-10-24, pending/approved, on no request, PHP 50.00 (or already 100.00)
--   * this proof (confirmation / reference / sha256) is already on another request
--   * the new request does not total 2,700.00 over 5 lines, or any after-check fails
-- IDEMPOTENT: the request key is s99e-honey-2700-20261027. When that request already exists, paid and 2,700, a second run changes nothing (raises a notice).
--
-- Side effects after commit (not done by this file; fired by the existing trigger staff_pay_notify_paid -> notify-cleaner-payment 'paid', pg_net, once):
--   * OPS Telegram group: ONE "paid" message (paid_by_tg is null, so the Staff-app path): Honey's first name, the work range Oct 21 to Oct 25, the bank reference, and
--     "Paid ahead - please still send the cleaning report for 21 Oct, 22 Oct and 25 Oct." It carries the OPS keyboard of the Finance card.
--   * Finance card: edited to the paid state only if the request has a Finance Telegram card; a request made by SQL has none, so normally nothing is edited or posted there.
--   * Honey's phone: a web push (title "Your payment has been sent", no amount) to each phone with the "tell me when I am paid" switch on; none if she never turned it on.
--   No Telegram DM goes to Honey, and the notice is claimed once (a retry does not repeat it).

begin;
do $$
declare
  c_lloyd constant uuid := 'fea44ac5-61b0-41a6-8616-d7823e99151b';
  c_prop  constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  c_key   constant text := 's99e-honey-2700-20261027';
  c_paid  constant timestamptz := '2026-10-27 12:40:39+08';
  c_conf  constant text := 'bpi:1630012121203';
  c_refno constant text := '929016';
  c_sha   constant text := 'd4e372ecc4955399b744c9acaa36ce4903750ce1cbd2e692c9ffc329164250c4';
  c_reason constant text := 'Lloyd 2026-10-27: 2 pcs x 50';
  v_honey uuid; v_name text; v_old_created timestamptz;
  v_sess uuid; v_claim public.cleaning_expense_claims%rowtype; v_after jsonb;
  v_id uuid; v_res jsonb; n integer; v_d date; v_refs text[];
begin
  -- who is paid: the payee of request 520B672A
  select payee_user_id, payee_name, created_at into v_honey, v_name, v_old_created from public.staff_pay_requests where ref = '520B672A' and property_id = c_prop;
  if v_honey is null then raise exception 'request 520B672A not found; nothing changed'; end if;
  if v_name is null or v_name not ilike 'honey%' then raise exception 'request 520B672A is not Honey''s (payee %); nothing changed', v_name; end if;

  -- a second run is a no-op
  select id into v_id from public.staff_pay_requests where payee_user_id = v_honey and idempotency_key = c_key;
  if v_id is not null then
    if exists (select 1 from public.staff_pay_requests where id = v_id and status = 'paid' and total_amount = 2700) then
      raise notice 'already recorded: request % is paid for 2,700; nothing changed', v_id;
      return;
    end if;
    raise exception 'request % with key % exists but is not paid for 2,700 (resolve it by hand); nothing changed', v_id, c_key;
  end if;

  ---------------------------------------------------------------- guards (before anything is written)
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = to_regprocedure('public.get_missed_cleanings(uuid,integer)')) is distinct from 'def6d3ea1ae7c3c05bc2ae178df2d0aa' then
    raise exception 'release s99e_missed_and_pay_20261102 is not applied (get_missed_cleanings is not the s99e body); nothing changed';
  end if;
  if to_regprocedure('public.staff_pay_admin_create_v2(uuid,jsonb,uuid[],jsonb,text)') is null then raise exception 'staff_pay_admin_create_v2 missing; nothing changed'; end if;

  select string_agg(ref, ', ') into v_name from public.staff_pay_requests
   where payee_user_id = v_honey and property_id = c_prop and status <> 'cancelled' and created_at > v_old_created and idempotency_key is distinct from c_key;
  if v_name is not null then raise exception 'Honey has request(s) % created after 520B672A; nothing changed (settle or cancel them first, then re-cut)', v_name; end if;

  foreach v_d in array array[date '2026-10-21', date '2026-10-22', date '2026-10-24', date '2026-10-25'] loop
    if exists (select 1 from public.staff_pay_requests q, jsonb_array_elements(q.lines) l
                where q.property_id = c_prop and q.status <> 'cancelled' and l ->> 'kind' = 'advance' and l ->> 'checkout_date' = v_d::text) then
      raise exception 'a live advance line already holds %; nothing changed', v_d;
    end if;
  end loop;
  foreach v_d in array array[date '2026-10-21', date '2026-10-22', date '2026-10-25'] loop
    if exists (select 1 from public.cleaning_sessions cs where cs.property_id = c_prop and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
                and (cs.checkout_date = v_d or (cs.checkout_date is null and (cs.cleaned_at at time zone 'Asia/Manila')::date between v_d and v_d + 1))) then
      raise exception 'a cleaning report already exists for % (it is no longer "no report yet"); nothing changed', v_d;
    end if;
  end loop;

  select count(*) into n from public.cleaning_sessions cs
   where cs.property_id = c_prop and cs.checkout_date = date '2026-10-24' and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay';
  if n <> 1 then raise exception '% reports exist for the 24 Oct checkout, expected exactly 1; nothing changed', n; end if;
  select cs.id into v_sess from public.cleaning_sessions cs
   where cs.property_id = c_prop and cs.checkout_date = date '2026-10-24' and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
     and cs.submitted_by_user_id = v_honey and cs.fee_paid_at is null and cs.pay_request_id is null and cs.fee_txn_id is null;
  if v_sess is null then raise exception 'the 24 Oct report is not Honey''s unpaid, unrequested session; nothing changed'; end if;
  if exists (select 1 from public.transactions t where t.external_ref = 'cleanfee:' || v_sess and t.status <> 'void') then raise exception 'the 24 Oct session already has a fee transaction; nothing changed'; end if;

  select count(*) into n from public.cleaning_expense_claims k
   where k.property_id = c_prop and k.submitted_by_user_id = v_honey and k.expense_date = date '2026-10-24' and k.description ilike '%kitkat%';
  if n <> 1 then raise exception '% KitKat claims dated 2026-10-24 for Honey, expected exactly 1; nothing changed', n; end if;
  select * into v_claim from public.cleaning_expense_claims k
   where k.property_id = c_prop and k.submitted_by_user_id = v_honey and k.expense_date = date '2026-10-24' and k.description ilike '%kitkat%';
  if v_claim.status not in ('pending_review', 'approved') or v_claim.pay_request_id is not null or v_claim.amount not in (50.00, 100.00)
     or exists (select 1 from public.transactions t where t.external_ref = 'claim:' || v_claim.id and t.status <> 'void') then
    raise exception 'the KitKat claim % is not an unpaid, unrequested PHP 50.00 claim (status %, amount %, request %); nothing changed', v_claim.id, v_claim.status, v_claim.amount, v_claim.pay_request_id;
  end if;

  if exists (select 1 from public.staff_pay_requests where proof_reference = c_refno or proof_file_unique_id = c_conf or proof_sha256 = c_sha) then
    raise exception 'before: this payment proof is already recorded on another request; nothing changed';
  end if;

  ---------------------------------------------------------------- KitKat 50.00 -> 100.00, audited
  if v_claim.amount = 50.00 then
    update public.cleaning_expense_claims
       set amount = 100.00, updated_at = now(),
           review_note = 'Amount corrected PHP 50.00 to 100.00 by Lloyd 2026-10-27: 2 pcs x 50'
     where id = v_claim.id;
    select to_jsonb(k) into v_after from public.cleaning_expense_claims k where k.id = v_claim.id;
    insert into public.admin_audit_log(property_id, entity_table, entity_id, action, before_state, after_state, reason, actor_user_id)
    values (c_prop, 'cleaning_expense_claims', v_claim.id, 'update', to_jsonb(v_claim), v_after, c_reason, c_lloyd);
  end if;
  if (select amount from public.cleaning_expense_claims where id = v_claim.id) <> 100.00 then raise exception 'the KitKat claim is not 100.00 after the correction'; end if;

  ---------------------------------------------------------------- act as Lloyd
  perform set_config('request.jwt.claims', json_build_object('sub', c_lloyd, 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
  perform set_config('cascade.audit_reason', 'session 99e: Lloyd paid Honey 2,700 by BPI InstaPay 2026-10-27 (confirmation 1630012121203)', true);

  -- 1. the request: 1 report + 3 paid-ahead checkouts, all with transport, + the corrected claim
  v_res := public.staff_pay_admin_create_v2(v_honey,
    jsonb_build_array(jsonb_build_object('id', v_sess, 'transport', true)),
    array[v_claim.id],
    jsonb_build_array(jsonb_build_object('checkout_date', '2026-10-21', 'transport', true), jsonb_build_object('checkout_date', '2026-10-22', 'transport', true),
                      jsonb_build_object('checkout_date', '2026-10-25', 'transport', true)),
    c_key);
  if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'create_v2 refused: %; nothing changed', v_res; end if;
  v_id := (v_res ->> 'id')::uuid;
  if (v_res ->> 'total')::numeric <> 2700 or jsonb_array_length(v_res -> 'lines') <> 5 then
    raise exception 'new request is % over % lines, expected 2700 over 5; nothing changed', v_res ->> 'total', jsonb_array_length(v_res -> 'lines');
  end if;

  -- 2. Lloyd is paying it (what the Staff app's Pay button does)
  v_res := public.telegram_staff_pay_step_v1(v_id, 'pay', null, 'Lloyd', null);
  if v_res ->> 'status' is distinct from 'paying' then raise exception 'pay step failed: %', v_res; end if;
  update public.staff_pay_requests set paying_by_user_id = c_lloyd, sent_said_at = coalesce(sent_said_at, c_paid) where id = v_id;

  -- 3. settle with the BPI screenshot read
  v_res := public.staff_pay_settle_v1(v_id, null, 'Lloyd', 'match', jsonb_build_object(
    'file_unique_id', c_conf, 'sha256', c_sha, 'amount', 2700, 'reference', c_refno,
    'read', jsonb_build_object('source', 'bpi_screenshot', 'sha256_of', 'BPI InstaPay screenshot Lloyd sent in chat 2026-10-27 (126,104 bytes, docs/s99e/bpi-2700-20261027.png)',
                               'confirmation', '1630012121203', 'note', '2026.10.27 Cascade Payment Honey')));
  if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'settle refused: %', v_res; end if;

  -- 4. the real payment time, not the time this block ran
  update public.staff_pay_requests set paid_at = c_paid, paid_by_user_id = coalesce(paid_by_user_id, c_lloyd) where id = v_id;
  update public.cleaning_sessions set fee_paid_at = c_paid where pay_request_id = v_id and fee_paid_at is not null;

  ---------------------------------------------------------------- checks after
  if not exists (select 1 from public.staff_pay_requests where id = v_id and status = 'paid' and total_amount = 2700 and proof_amount = 2700 and proof_reference = c_refno
                    and proof_file_unique_id = c_conf and proof_sha256 = c_sha and paid_at = c_paid and proof_verdict = 'match' and payee_user_id = v_honey) then
    raise exception 'after: the new request is not paid 2,700 with the BPI proof and the real payment time';
  end if;
  v_refs := array['cleanfee:' || v_sess, 'cleanadv:' || v_id || ':2026-10-21', 'cleanadv:' || v_id || ':2026-10-22', 'cleanadv:' || v_id || ':2026-10-25', 'claim:' || v_claim.id];
  select count(*) into n from public.transactions
   where external_ref = any (v_refs) and txn_type = 'expense' and status = 'confirmed' and source = 'cleaner_fee' and logged_by = 'Lloyd' and property_id = c_prop
     and ((external_ref like 'claim:%' and category = 'supplies' and gross_amount = 100) or (external_ref not like 'claim:%' and category = 'cleaning' and gross_amount = 650));
  if n <> 5 then raise exception 'after: % of 5 expected transactions (4 x 650 cleaning, 1 x 100 supplies) exist', n; end if;
  if (select sum(gross_amount) from public.transactions where external_ref = any (v_refs) and status <> 'void') <> 2700 then raise exception 'after: the five transactions do not total 2,700'; end if;
  if (select count(*) from public.transactions where external_ref like 'cleanadv:' || v_id || ':%') <> 3 then raise exception 'after: expected exactly 3 cleanadv rows'; end if;
  select count(*) into n from public.cleaning_sessions cs
   where cs.id = v_sess and cs.pay_request_id = v_id and cs.fee_paid_at = c_paid and cs.fee_amount = 650
     and cs.fee_txn_id = (select t.id from public.transactions t where t.external_ref = 'cleanfee:' || cs.id and t.status <> 'void');
  if n <> 1 then raise exception 'after: the 24 Oct session is not stamped paid with its transaction'; end if;
  if not exists (select 1 from public.cleaning_expense_claims where id = v_claim.id and status = 'paid' and amount = 100.00 and pay_request_id = v_id) then
    raise exception 'after: the KitKat claim is not paid at 100.00 on the new request';
  end if;
  if public.s_advance_session_v1(v_id, date '2026-10-21') is not null or public.s_advance_session_v1(v_id, date '2026-10-22') is not null
     or public.s_advance_session_v1(v_id, date '2026-10-25') is not null then
    raise exception 'after: a paid-ahead date already has a session (reports are still owed for 21, 22 and 25 Oct)';
  end if;
  raise notice 'Honey 2,700 recorded: request % paid, 5 transactions (4 x 650 + 100), KitKat corrected to 100, reports still owed 21, 22 and 25 Oct', v_id;
end $$;
commit;

-- Forward checks (all true):
-- select status = 'paid' and total_amount = 2700 and proof_reference = '929016' and proof_file_unique_id = 'bpi:1630012121203' and paid_at = '2026-10-27 04:40:39+00' from public.staff_pay_requests where idempotency_key = 's99e-honey-2700-20261027';
-- select count(*) = 5 and sum(gross_amount) = 2700 from public.transactions t join public.staff_pay_requests r on r.idempotency_key = 's99e-honey-2700-20261027' where t.status = 'confirmed' and (t.external_ref like 'cleanadv:' || r.id || ':%' or t.external_ref = 'claim:' || (select k.id from public.cleaning_expense_claims k where k.pay_request_id = r.id) or t.external_ref in (select 'cleanfee:' || cs.id from public.cleaning_sessions cs where cs.pay_request_id = r.id));
-- select amount = 100.00 and status = 'paid' from public.cleaning_expense_claims where description ilike '%kitkat%' and expense_date = '2026-10-24' and submitted_by_user_id = (select payee_user_id from public.staff_pay_requests where ref = '520B672A');
-- select count(*) = 1 from public.admin_audit_log where entity_table = 'cleaning_expense_claims' and reason = 'Lloyd 2026-10-27: 2 pcs x 50';
