-- 20260921020000_health_checks_core.sql
-- SPEC-11 session 1 step 1, deliberately held back from phase 1 (D-208).
--
-- THE ENTIRE CONTENT OF THIS MIGRATION IS ONE MOVE. The body of
-- run_health_checks_v1 - ten checks, four of them financial - becomes
-- health_checks_core_v1(p_property_id, p_fin). run_health_checks_v1 keeps its
-- gate and calls the core. run_health_checks_service_v1 calls the core with
-- true, so the daily verifier reads the same ten checks the dashboard button
-- shows. No check is edited, no literal is retuned, no grant is widened.
--
-- HOW THE BODY GOT HERE, AND HOW TO PROVE IT DID NOT DRIFT. It was not
-- retyped. It was taken byte-for-byte from
-- 20260916150000_admin_overview_handoffs_open.sql lines 111-198, which was
-- first verified identical to the live function: md5(prosrc) =
-- 527fb1e6054d4858310f2c32d0493f33, 9982 bytes, both sides, read from
-- production 2026-09-21. Two lines then came out and one went in by sed, and
-- that is the whole diff:
--
--   -   perform public.admin_require('read_operations', p_property_id);
--   -   v_fin := public.current_staff_authorized('read_finance', p_property_id);
--   +   v_fin := p_fin;
--
-- The declaration of v_fin stays, so all three of its later uses are untouched
-- and the diff is two lines rather than a global rename. The result hashes to
-- f169d017fa1a9a9d768dd495d7219caf (9859 bytes), which the release contract
-- asserts as a forward check. THAT is the proof, not the equality test between
-- the two wrappers: a mistyped copy would pass the equality test, because both
-- wrappers would be reading the same mistyped body.

begin;

-- 1. The core ----------------------------------------------------------------
-- Everything run_health_checks_v1 did except decide who is allowed to ask.
-- p_fin is the finance flag the gate used to compute; the caller now supplies
-- it. Not callable by public, anon or authenticated: anon has to be revoked BY
-- NAME, because Supabase's default privileges grant EXECUTE on every new
-- function to it and a revoke from public does not take that away.
create or replace function public.health_checks_core_v1(p_property_id uuid, p_fin boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_today date; v_fin boolean; v_hc record; v_out jsonb := '[]'::jsonb; v_checks jsonb := '[]'::jsonb;
begin
  v_fin := p_fin;
  v_today := public.manila_today();

  -- Ledger ↔ reservations: every confirmed payout e-mail names its stay.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_rows_linked', 'l', 'Payout e-mails linked to a stay', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'ref', t.external_ref, 'date', t.transaction_date, 'amount', t.gross_amount)) filter (where t.id is not null), '[]'::jsonb))
  from (select * from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null limit 20) t);

  -- Reservations ↔ payouts: every completed stay has a confirmed payout row.
  v_checks := v_checks || (select jsonb_build_object('k', 'completed_stays_paid', 'l', 'Completed stays with a payout row', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', rr.confirmation_code, 'guest', rr.guest_name, 'checkout', rr.checkout_date, 'payout', rr.host_payout)) filter (where rr.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date < v_today
        and not exists (select 1 from public.transactions t where t.reservation_id = x.id and t.source = 'airbnb_payout_email' and t.status = 'confirmed') limit 20) rr);

  -- Payout totals: Σ reservation payout_amount = Σ payout e-mails + Σ Airbnb adjustments.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_totals_agree', 'l', 'Reservation payouts equal payout e-mails plus adjustments', 's', case when abs(d.diff) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
    jsonb_build_object('reservationPayouts', d.res, 'payoutEmails', d.em, 'adjustments', d.adj, 'difference', d.diff))
  from (select res, em, adj, res - em - adj diff from (
    select (select coalesce(sum(payout_amount), 0) from public.airbnb_reservations where property_id = p_property_id and payout_amount is not null) res,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed') em,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb' and txn_type = 'expense' and category = 'airbnb_adjustment' and status = 'confirmed') adj) x) d);

  -- Cleaning log ↔ stays: a checkout in the last 90 days has a cleaning within three days.
  v_checks := v_checks || (select jsonb_build_object('k', 'checkouts_cleaned', 'l', 'Checkouts (90 days) followed by a cleaning', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', s.confirmation_code, 'guest', s.guest_name, 'checkout', s.checkout_date)) filter (where s.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date >= v_today - 90 and x.checkout_date < v_today
        and not exists (select 1 from public.cleaning_sessions c where c.property_id = p_property_id and (c.checkout_date = x.checkout_date or (c.cleaned_at::date between x.checkout_date and x.checkout_date + 3))) limit 20) s);

  -- Cleaning log ↔ ledger: every fee owed is settled by a live transaction.
  if v_fin then
    v_checks := v_checks || (select jsonb_build_object('k', 'cleaner_fees_settled', 'l', 'Cleaning fees settled in the ledger', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('session', c.id, 'guest', c.last_guest_name, 'cleaned', c.cleaned_at::date, 'fee', c.fee_amount)) filter (where c.id is not null), '[]'::jsonb))
    from (select * from public.cleaning_sessions x where x.property_id = p_property_id and coalesce(x.fee_amount, 0) > 0
          and (x.fee_paid_at is null or x.fee_txn_id is null or not exists (select 1 from public.transactions t where t.id = x.fee_txn_id and t.status <> 'void')) limit 20) c);
  end if;

  -- Meter readings: first entries and negative re-entries carry a review flag.
  v_checks := v_checks || (select jsonb_build_object('k', 'meter_readings_reviewed', 'l', 'Odd meter readings reviewed', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'session', m.session_id, 'recorded', m.recorded_at::date, 'electricDelta', m.electric_delta, 'waterDelta', m.water_delta)) filter (where m.id is not null), '[]'::jsonb))
  from (select * from public.meter_readings x where x.property_id = p_property_id and x.meter_flag is null
        and (coalesce(x.electric_prev, 0) = 0 or coalesce(x.water_prev, 0) = 0 or coalesce(x.electric_delta, 0) < 0 or coalesce(x.water_delta, 0) < 0) limit 20) m);

  -- Inventory: ledger-controlled items agree with their last movement; nothing negative.
  v_checks := v_checks || (select jsonb_build_object('k', 'inventory_ledger_consistent', 'l', 'Inventory quantities agree with movements', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('item', i.name, 'onHand', i.qty_on_hand, 'lastMovement', i.last_after)) filter (where i.id is not null), '[]'::jsonb))
  from (select x.id, x.name, x.qty_on_hand, (select quantity_after from public.inventory_stock_movements m where m.item_id = x.id order by sequence_no desc limit 1) last_after
        from public.inventory_items x where x.property_id = p_property_id and x.is_active) i
  where i.qty_on_hand < 0 or (i.last_after is not null and i.last_after <> i.qty_on_hand));

  if v_fin then
    -- Ledger: duplicate live rows (same date, amount, payee, type, source).
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_duplicates', 'l', 'Duplicate ledger rows', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('date', g.transaction_date, 'amount', g.gross_amount, 'payee', g.payee, 'n', g.n)), '[]'::jsonb))
    from (select transaction_date, gross_amount, coalesce(payee_name, '') payee, count(*) n from public.transactions
          where property_id = p_property_id and status <> 'void' and source not in ('airbnb','airbnb_email')
          group by transaction_date, gross_amount, coalesce(payee_name, ''), txn_type, source having count(*) > 1 limit 20) g);

    -- Ledger position: income − expenses − drawings on confirmed, non-mirror rows.
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_position', 'l', 'Cash position: income − expenses − drawings', 's', case when abs(p.net) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
      jsonb_build_object('income', p.inc, 'expenses', p.exp, 'drawings', p.drw, 'net', p.net, 'asOf', v_today))
    from (select inc, exp, drw, inc - exp - drw net from (
      select coalesce(sum(gross_amount) filter (where txn_type = 'income'), 0) inc, coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) exp, coalesce(sum(gross_amount) filter (where txn_type = 'drawing'), 0) drw
      from public.transactions where property_id = p_property_id and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= v_today) x) p);

    -- Journals: every posted journal balances.
    v_checks := v_checks || (select jsonb_build_object('k', 'journals_balanced', 'l', 'Posted journals balance', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('journalNo', j.journal_no, 'debits', j.d, 'credits', j.c)), '[]'::jsonb))
    from (select j.journal_no, sum(l.debit) d, sum(l.credit) c from public.acct_journals j join public.acct_journal_lines l on l.journal_id = j.id
          where j.property_id = p_property_id and j.status = 'posted' group by j.journal_no having sum(l.debit) <> sum(l.credit) limit 20) j);
  end if;

  -- Messenger handoffs (Sprint 0, 2026-09-16): open cards a human has not answered. Counted here
  -- so a status-literal drift (the 'pending' bug fixed in this release) shows up in System health.
  v_checks := v_checks || (select jsonb_build_object('k', 'concierge_handoffs_open', 'l', 'Messenger handoffs awaiting a human reply', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'guest', h.guest_name, 'risk', h.risk, 'created', h.created_at)) filter (where h.id is not null), '[]'::jsonb))
  from (select * from public.concierge_handoffs x where x.status = 'open' order by x.created_at desc limit 20) h);

  for v_hc in select e->>'k' k, e->>'l' l, e->>'s' s, (e->>'n')::int n, e->'d' d from jsonb_array_elements(v_checks) e loop
    insert into public.admin_health_check_runs(property_id, check_key, label, status, count, detail, ran_at, ran_by)
    values (p_property_id, v_hc.k, v_hc.l, v_hc.s, v_hc.n, v_hc.d, now(), auth.uid())
    on conflict (property_id, check_key) do update set label = excluded.label, status = excluded.status, count = excluded.count, detail = excluded.detail, ran_at = excluded.ran_at, ran_by = excluded.ran_by;
  end loop;
  select coalesce(jsonb_agg(to_jsonb(h) order by h.check_key), '[]'::jsonb) into v_out from public.admin_health_check_runs h where h.property_id = p_property_id and (v_fin or h.check_key not in ('cleaner_fees_settled','ledger_duplicates','ledger_position','journals_balanced'));
  return jsonb_build_object('ranAt', now(), 'checks', v_out);
end;
$$;

revoke all on function public.health_checks_core_v1(uuid, boolean) from public;
revoke all on function public.health_checks_core_v1(uuid, boolean) from anon;
revoke all on function public.health_checks_core_v1(uuid, boolean) from authenticated;

comment on function public.health_checks_core_v1(uuid, boolean) is
  'SPEC-11: the ten System health checks, with no authorisation of their own. Callers gate first. Reachable only through run_health_checks_v1 and run_health_checks_service_v1, both definer-owned by postgres.';

-- 2. The dashboard button, unchanged in behaviour ----------------------------
-- Same name, same signature, same gate, same two auth calls in the same order.
-- authenticated keeps EXECUTE; a cleaner still gets 42501 out of admin_require.
create or replace function public.run_health_checks_v1(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_fin boolean;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  return public.health_checks_core_v1(p_property_id, v_fin);
end;
$$;

revoke all on function public.run_health_checks_v1(uuid) from public;
revoke all on function public.run_health_checks_v1(uuid) from anon;
grant execute on function public.run_health_checks_v1(uuid) to authenticated;

-- 3. The same ten checks for a scheduled job ---------------------------------
-- A cron job has no staff row to gate on, so it asks with the finance flag
-- already true and the grant does the gating instead. service_role only.
create or replace function public.run_health_checks_service_v1(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return public.health_checks_core_v1(p_property_id, true);
end;
$$;

revoke all on function public.run_health_checks_service_v1(uuid) from public;
revoke all on function public.run_health_checks_service_v1(uuid) from anon;
revoke all on function public.run_health_checks_service_v1(uuid) from authenticated;
grant execute on function public.run_health_checks_service_v1(uuid) to service_role;

comment on function public.run_health_checks_service_v1(uuid) is
  'SPEC-11 V10: refreshes admin_health_check_runs from a scheduled job, with finance included. Same body as the dashboard button. service_role only.';

commit;
