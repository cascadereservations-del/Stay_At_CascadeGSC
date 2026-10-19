-- 2026-10-20 (session 94, lane sql): record Honey's PHP 3,250 payment. NOT a migration; Lloyd's block runs it with scripts/migrations/run-sql-on-host.sh AFTER release
-- s94_pay_ahead_20261027 is applied (it needs staff_pay_admin_create_v2 and the cleanadv settle).
--
-- The money: BPI InstaPay 2026-10-19 18:11:45 Manila (10:11:45 UTC), confirmation 1629218520037, reference 123160, "2026.10.19 Cascade Payment Honey", PHP 3,250.
--   = Angeleen 10-11 + Rohamidin 10-13 (cleaning sessions 0f88c251 / 768aabea, today in request 46F3E098 which is 'paying' for 1,300)
--   + Shasha 10-14, Abe 10-17, Shaneen 10-19 (checkouts with no report yet: paid ahead), each 650 (500 + 150 transport).
-- Steps, one transaction, as Lloyd (request.jwt.claims sub = Lloyd): cancel 46F3E098 (its two sessions are released); staff_pay_admin_create_v2 with the 2 sessions + 3 advance
-- dates, all with transport (total must be 3,250); step to paying; staff_pay_settle_v1(id, null, 'Lloyd', 'match', proof) which writes 2 cleanfee: and 3 cleanadv: expense rows;
-- paid_at and the sessions' fee_paid_at set to the real payment time; the photo follow-ups of Ermann (a381f7fd, unreadable) and Rohamidin (768aabea, not_a_meter) resolved.
-- The two 20-peso sugar claims are left alone (asserted unchanged). The paid notice to Honey goes out by the normal trigger after commit ("Paid ahead - please still send
-- the report for 14 Oct, 17 Oct, 19 Oct").
-- Self-checking: every count and amount below is asserted; any mismatch raises and the whole block rolls back, so nothing changes.

begin;
do $$
declare
  c_lloyd constant uuid := 'fea44ac5-61b0-41a6-8616-d7823e99151b';
  c_honey constant uuid := '50ccca5a-3e59-4299-9680-837fd8d88ac4';
  c_prop  constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  c_s_ang constant uuid := '0f88c251-b901-4e89-bded-28bd92b69288';
  c_s_roh constant uuid := '768aabea-13b6-4758-ae17-1d3fd7eb6eb5';
  c_s_erm constant uuid := 'a381f7fd-6ba3-4622-aa9b-6ec925cea3d6';
  c_paid  constant timestamptz := '2026-10-19 10:11:45+00';
  c_note  constant text := 'Settled: paid in full, photo follow-up cleared by Lloyd 2026-10-20';
  v_old uuid; v_id uuid; v_res jsonb; n integer; v_claims_before integer; v_refs text[];
begin
  if to_regprocedure('public.staff_pay_admin_create_v2(uuid,jsonb,uuid[],jsonb,text)') is null then
    raise exception 'release s94_pay_ahead_20261027 is not applied (staff_pay_admin_create_v2 missing); nothing changed';
  end if;

  -- before: 46F3E098 is Honey's open request for exactly the two sessions, 1,300, and nothing else is paid yet
  select id into v_old from public.staff_pay_requests
   where ref = '46F3E098' and payee_user_id = c_honey and status = 'paying' and total_amount = 1300 and sent_said_at is null and proof_file_unique_id is null;
  if v_old is null then raise exception 'before: request 46F3E098 is not Honey''s paying 1,300 request any more; nothing changed'; end if;
  select count(*) into n from public.cleaning_sessions where pay_request_id = v_old and id in (c_s_ang, c_s_roh) and fee_paid_at is null;
  if n <> 2 then raise exception 'before: % of 2 sessions are on 46F3E098 unpaid; nothing changed', n; end if;
  if exists (select 1 from public.staff_pay_requests where proof_reference = '123160' or proof_file_unique_id = 'bpi:1629218520037') then
    raise exception 'before: this payment proof is already recorded; nothing changed';
  end if;
  select count(*) into v_claims_before from public.cleaning_expense_claims where submitted_by_user_id = c_honey and status in ('pending_review', 'approved') and pay_request_id is null;

  -- act as Lloyd
  perform set_config('request.jwt.claims', json_build_object('sub', c_lloyd, 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);

  -- 1. cancel the 1,300 request (releases its sessions)
  v_res := public.telegram_staff_pay_step_v1(v_old, 'cancel', null, 'Lloyd', null);
  if v_res ->> 'status' is distinct from 'cancelled' then raise exception 'cancel failed: %', v_res; end if;
  if exists (select 1 from public.cleaning_sessions where pay_request_id = v_old) then raise exception 'cancel left sessions on 46F3E098; nothing changed'; end if;

  -- 2. the new request: 2 sessions + 3 paid-ahead checkouts, all with transport
  v_res := public.staff_pay_admin_create_v2(c_honey,
    jsonb_build_array(jsonb_build_object('id', c_s_ang, 'transport', true), jsonb_build_object('id', c_s_roh, 'transport', true)),
    '{}'::uuid[],
    jsonb_build_array(jsonb_build_object('checkout_date', '2026-10-14', 'transport', true), jsonb_build_object('checkout_date', '2026-10-17', 'transport', true),
                      jsonb_build_object('checkout_date', '2026-10-19', 'transport', true)),
    's94-honey-3250-20261020');
  if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'create_v2 refused: %', v_res; end if;
  v_id := (v_res ->> 'id')::uuid;
  if (v_res ->> 'total')::numeric <> 3250 or jsonb_array_length(v_res -> 'lines') <> 5 then raise exception 'new request is % over % lines, expected 3250 over 5; nothing changed', v_res ->> 'total', jsonb_array_length(v_res -> 'lines'); end if;

  -- 3. Lloyd is paying it (what the Staff app's Pay button does)
  v_res := public.telegram_staff_pay_step_v1(v_id, 'pay', null, 'Lloyd', null);
  if v_res ->> 'status' is distinct from 'paying' then raise exception 'pay step failed: %', v_res; end if;
  update public.staff_pay_requests set paying_by_user_id = c_lloyd, sent_said_at = coalesce(sent_said_at, c_paid) where id = v_id;

  -- 4. settle with the BPI screenshot read
  v_res := public.staff_pay_settle_v1(v_id, null, 'Lloyd', 'match', jsonb_build_object(
    'file_unique_id', 'bpi:1629218520037', 'sha256', null, 'amount', 3250, 'reference', '123160',
    'read', jsonb_build_object('source', 'bpi_screenshot', 'confirmation', '1629218520037', 'note', '2026.10.19 Cascade Payment Honey')));
  if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'settle refused: %', v_res; end if;

  -- 5. the real payment time, not the time this block ran
  update public.staff_pay_requests set paid_at = c_paid, paid_by_user_id = coalesce(paid_by_user_id, c_lloyd) where id = v_id;
  update public.cleaning_sessions set fee_paid_at = c_paid where pay_request_id = v_id and fee_paid_at is not null;

  -- 6. photo follow-ups of the two settled sessions
  update public.meter_readings set vision_resolved_at = now(), vision_resolved_by = c_lloyd, vision_resolved_note = c_note
   where session_id in (c_s_erm, c_s_roh) and vision_resolved_at is null;
  get diagnostics n = row_count;
  if n <> 2 then raise exception 'resolved % meter rows, expected 2 (Ermann a381f7fd, Rohamidin 768aabea); nothing changed', n; end if;

  ---------------------------------------------------------------- checks after
  if not exists (select 1 from public.staff_pay_requests where id = v_old and status = 'cancelled') then raise exception 'after: 46F3E098 is not cancelled'; end if;
  if not exists (select 1 from public.staff_pay_requests where id = v_id and status = 'paid' and total_amount = 3250 and proof_amount = 3250 and proof_reference = '123160'
                    and proof_file_unique_id = 'bpi:1629218520037' and paid_at = c_paid and proof_verdict = 'match' and payee_user_id = c_honey) then
    raise exception 'after: the new request is not paid 3,250 with the BPI proof and the real payment time';
  end if;
  v_refs := array['cleanfee:' || c_s_ang, 'cleanfee:' || c_s_roh, 'cleanadv:' || v_id || ':2026-10-14', 'cleanadv:' || v_id || ':2026-10-17', 'cleanadv:' || v_id || ':2026-10-19'];
  select count(*) into n from public.transactions
   where external_ref = any (v_refs) and txn_type = 'expense' and category = 'cleaning' and status = 'confirmed' and source = 'cleaner_fee' and gross_amount = 650
     and logged_by = 'Lloyd' and property_id = c_prop;
  if n <> 5 then raise exception 'after: % of 5 expected cleaning transactions of 650 exist', n; end if;
  if (select sum(gross_amount) from public.transactions where external_ref = any (v_refs)) <> 3250 then raise exception 'after: the five transactions do not total 3,250'; end if;
  if (select count(*) from public.transactions where external_ref like 'cleanadv:' || v_id || ':%') <> 3 then raise exception 'after: expected exactly 3 cleanadv rows'; end if;
  select count(*) into n from public.cleaning_sessions cs
   where cs.id in (c_s_ang, c_s_roh) and cs.pay_request_id = v_id and cs.fee_paid_at = c_paid and cs.fee_amount = 650
     and cs.fee_txn_id = (select t.id from public.transactions t where t.external_ref = 'cleanfee:' || cs.id and t.status <> 'void');
  if n <> 2 then raise exception 'after: % of 2 sessions are stamped paid with their transaction', n; end if;
  select count(*) into n from public.meter_readings where session_id in (c_s_erm, c_s_roh) and vision_resolved_at is not null and vision_resolved_note = c_note and vision_resolved_by = c_lloyd;
  if n <> 2 then raise exception 'after: % of 2 meter rows are resolved with the settled note', n; end if;
  if (select count(*) from public.get_meter_photo_followups(c_prop, 30) f where f.session_id in (c_s_erm, c_s_roh)) <> 0 then raise exception 'after: a settled session is still in the photo follow-ups'; end if;
  if (select count(*) from public.cleaning_expense_claims where submitted_by_user_id = c_honey and status in ('pending_review', 'approved') and pay_request_id is null) <> v_claims_before then
    raise exception 'after: Honey''s open claims changed (the two 20-peso sugar claims must stay as they were)';
  end if;
  if public.s_advance_session_v1(v_id, date '2026-10-14') is not null or public.s_advance_session_v1(v_id, date '2026-10-17') is not null
     or public.s_advance_session_v1(v_id, date '2026-10-19') is not null then
    raise exception 'after: a paid-ahead date already has a session (reports are still owed for 14, 17 and 19 Oct)';
  end if;
  raise notice 'Honey 3,250 recorded: request % paid, 5 transactions, 2 follow-ups resolved', v_id;
end $$;
commit;

-- Forward checks (all true):
-- select status = 'paid' and total_amount = 3250 and proof_reference = '123160' and paid_at = '2026-10-19 10:11:45+00' from public.staff_pay_requests where idempotency_key = 's94-honey-3250-20261020';
-- select count(*) = 5 and sum(gross_amount) = 3250 from public.transactions where external_ref ~ '^clean(fee:(0f88c251-b901-4e89-bded-28bd92b69288|768aabea-13b6-4758-ae17-1d3fd7eb6eb5)|adv:)' and status = 'confirmed';
-- select count(*) = 0 from public.get_meter_photo_followups('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 30) where session_id in ('a381f7fd-6ba3-4622-aa9b-6ec925cea3d6', '768aabea-13b6-4758-ae17-1d3fd7eb6eb5');
