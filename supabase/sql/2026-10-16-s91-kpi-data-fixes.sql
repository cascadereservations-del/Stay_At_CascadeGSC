-- 2026-10-16 (session 91, lane kpi-sql): the two one-off data fixes from docs/s91/KPI-AUDIT.md, F4 and F5. NOT a migration; Lloyd's block runs it with
-- scripts/migrations/run-sql-on-host.sh AFTER release s91_kpi_20261026 is applied (the waves fix for F4 in airbnb-email-sync stops new ones).
--
-- F4  three confirmed airbnb_email ESTIMATE income rows survived their payout / cancellation and are counted as income twice or never received:
--       25e2a736-6004-4895-ab00-176445a984dd  HMZCDZCYZX  2026-09-13  1,561.90
--       7759538b-b079-4c37-b003-148716963d2b  HMZXZPC5MN  2026-09-15  1,537.10
--       e7d05181-ef61-4300-8644-758813dade8f  HMWA2CNM3F  2026-10-28  4,831.98
--     -> status 'void' with a note naming this fix (the admin_audit_row trigger on transactions records the update; nothing is deleted).
--     Guarded: each must still be a confirmed, estimated, airbnb_email income row whose stay is cancelled or already has a confirmed payout e-mail
--     (the kpi_recompute_v1 'confirmed_estimates_dead' predicate), and exactly 3 must match.
-- F5  four synthetic booking_inquiries (all already status cancelled) removed with everything that hangs off them, following 2026-09-28-s58-synthetic-cleanup.sql:
--       e5800000-0000-4000-8000-0000000000a0 (S58 Midstay), e5800000-0000-4000-8000-0000000000b0 (S58 Door), e5600000-0000-4000-8000-0000000000c0 (S56 Checkout),
--       1ae5902e-9701-4dc8-bb38-747fedd320f4 (guest "test", 2026-10-02).
--     Dependents handled (read live 2026-10-16): transactions.booking_id (one VOID direct_booking row on the "test" inquiry: kept, booking_id set to null, because
--     the ledger row is history), booking_holds (1), booking_lifecycle_events (1), calendar_events uid direct:<id> / cascade-direct-<id> (1, cancelled), automation_outbox
--     (5, all dead_letter). Every other booking_id table, a mirror airbnb_reservations row and any non-void transaction must be empty, else the block raises and nothing changes.
--     The guest "test" (fbb045f2-...) stays: two other cancelled "test" inquiries still use it and are not in this list.
-- Self-checking: any count that differs from the one expected raises and the whole block rolls back. Prints the proof rows first, then the checks as notices.

select id, guest_name, status, checkin_date, checkout_date, total_amount from public.booking_inquiries
 where id in ('e5800000-0000-4000-8000-0000000000a0', 'e5800000-0000-4000-8000-0000000000b0', 'e5600000-0000-4000-8000-0000000000c0', '1ae5902e-9701-4dc8-bb38-747fedd320f4') order by checkin_date;
select id, external_ref, status, income_stage, source, transaction_date, gross_amount from public.transactions
 where id in ('25e2a736-6004-4895-ab00-176445a984dd', '7759538b-b079-4c37-b003-148716963d2b', 'e7d05181-ef61-4300-8644-758813dade8f') order by transaction_date;

begin;
do $$
declare
  t_ids constant uuid[] := array['25e2a736-6004-4895-ab00-176445a984dd', '7759538b-b079-4c37-b003-148716963d2b', 'e7d05181-ef61-4300-8644-758813dade8f']::uuid[];
  i_ids constant uuid[] := array['e5800000-0000-4000-8000-0000000000a0', 'e5800000-0000-4000-8000-0000000000b0', 'e5600000-0000-4000-8000-0000000000c0', '1ae5902e-9701-4dc8-bb38-747fedd320f4']::uuid[];
  n integer;
begin
  ---------------------------------------------------------------- F4
  select count(*) into n
    from public.transactions t
    join public.airbnb_reservations r on r.property_id = t.property_id and r.confirmation_code = t.external_ref
   where t.id = any (t_ids) and t.txn_type = 'income' and t.source = 'airbnb_email' and t.income_stage = 'estimated' and t.status = 'confirmed'
     and (r.status = 'cancelled'
          or exists (select 1 from public.transactions p where p.reservation_id = r.id and p.source = 'airbnb_payout_email' and p.status = 'confirmed'));
  if n <> 3 then raise exception 'F4: % of 3 estimate rows still match (confirmed airbnb_email estimate, stay cancelled or paid); nothing changed', n; end if;

  update public.transactions
     set status = 'void', updated_at = now(),
         notes = coalesce(notes || E'\n', '') || '[s91 F4] voided 2026-10-16: the Airbnb estimate outlived its stay (payout received or booking cancelled)'
   where id = any (t_ids) and status = 'confirmed' and source = 'airbnb_email' and income_stage = 'estimated';
  get diagnostics n = row_count;
  if n <> 3 then raise exception 'F4: voided % rows, expected 3; nothing changed', n; end if;

  ---------------------------------------------------------------- F5
  select count(*) into n from public.booking_inquiries
   where id = any (i_ids) and status = 'cancelled' and (guest_name ~* '^synthetic' or guest_name = 'test');
  if n <> 4 then raise exception 'F5: % of 4 synthetic inquiries match (cancelled, synthetic or "test"); nothing changed', n; end if;

  if exists (select 1 from public.transactions where booking_id = any (i_ids) and status <> 'void')
     or exists (select 1 from public.airbnb_reservations where confirmation_code in (select 'DIRECT:' || x::text from unnest(i_ids) x))
     or exists (select 1 from public.calendar_events where public.stay_uid_inquiry_v1(uid) = any (i_ids) and status <> 'cancelled')
     or exists (select 1 from public.automation_outbox where aggregate_id = any (i_ids) and status = 'pending')
     or exists (select 1 from public.guest_conversations where booking_id = any (i_ids))
     or exists (select 1 from public.payment_evidence_candidates where booking_id = any (i_ids))
     or exists (select 1 from public.payment_evidence_comparisons where booking_id = any (i_ids))
     or exists (select 1 from public.payment_finance_reviews where booking_id = any (i_ids))
     or exists (select 1 from public.booking_refund_authorizations where booking_id = any (i_ids))
     or exists (select 1 from public.crm_lifecycle_events where booking_id = any (i_ids))
     or exists (select 1 from public.follow_up_tasks where booking_id = any (i_ids))
     or exists (select 1 from public.external_calendar_events where booking_id = any (i_ids))
     or exists (select 1 from public.guest_access_tokens where booking_id = any (i_ids))
     or exists (select 1 from public.booking_decisions where booking_id = any (i_ids)) then
    raise exception 'F5: something live still references a synthetic inquiry (non-void transaction, mirror, live calendar row, pending outbox, or a table this block does not clear); nothing changed';
  end if;

  update public.transactions set booking_id = null where booking_id = any (i_ids) and status = 'void';
  get diagnostics n = row_count; raise notice 'F5 void transactions detached: % (expected 1)', n;
  if n <> 1 then raise exception 'F5: detached % void transactions, expected 1; nothing changed', n; end if;

  delete from public.guest_message_log where booking_id = any (i_ids);
  get diagnostics n = row_count; raise notice 'F5 guest_message_log rows deleted: %', n;
  delete from public.booking_holds where booking_id = any (i_ids);
  get diagnostics n = row_count; raise notice 'F5 booking_holds deleted: % (expected 1)', n;
  if n <> 1 then raise exception 'F5: deleted % booking_holds, expected 1; nothing changed', n; end if;
  delete from public.booking_lifecycle_events where booking_id = any (i_ids);
  get diagnostics n = row_count; raise notice 'F5 booking_lifecycle_events deleted: % (expected 1)', n;
  if n <> 1 then raise exception 'F5: deleted % lifecycle events, expected 1; nothing changed', n; end if;
  delete from public.calendar_events where public.stay_uid_inquiry_v1(uid) = any (i_ids) and status = 'cancelled';
  get diagnostics n = row_count; raise notice 'F5 calendar_events deleted: % (expected 1)', n;
  if n <> 1 then raise exception 'F5: deleted % calendar rows, expected 1; nothing changed', n; end if;
  delete from public.automation_outbox where aggregate_id = any (i_ids);
  get diagnostics n = row_count; raise notice 'F5 automation_outbox deleted: % (expected 5)', n;
  if n <> 5 then raise exception 'F5: deleted % outbox rows, expected 5; nothing changed', n; end if;
  delete from public.booking_inquiries where id = any (i_ids);
  get diagnostics n = row_count;
  if n <> 4 then raise exception 'F5: deleted % inquiries, expected 4; nothing changed', n; end if;

  ---------------------------------------------------------------- the books after
  if (select count(*) from public.transactions where id = any (t_ids) and status = 'void') <> 3
     or exists (select 1 from public.booking_inquiries where id = any (i_ids))
     or exists (select 1 from public.transactions where booking_id = any (i_ids)) then
    raise exception 'post-check failed; nothing changed';
  end if;
end $$;
commit;

-- Forward checks (all true):
-- select count(*) = 3 from public.transactions where id in ('25e2a736-6004-4895-ab00-176445a984dd', '7759538b-b079-4c37-b003-148716963d2b', 'e7d05181-ef61-4300-8644-758813dade8f') and status = 'void';
-- select count(*) = 0 from public.booking_inquiries where id in ('e5800000-0000-4000-8000-0000000000a0', 'e5800000-0000-4000-8000-0000000000b0', 'e5600000-0000-4000-8000-0000000000c0', '1ae5902e-9701-4dc8-bb38-747fedd320f4');
-- select not exists (select 1 from jsonb_array_elements(public.kpi_reconcile_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '2026-10-01')) e where e ->> 'key' = 'V19:hygiene:confirmed_estimates_dead');  -- needs release s91_kpi_20261026 applied
