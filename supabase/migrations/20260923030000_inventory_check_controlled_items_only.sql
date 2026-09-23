-- 20260923030000_inventory_check_controlled_items_only.sql
-- Session 46 (Opus 5). V10:inventory_ledger_consistent went red on Liquid Hand Soap (on hand 1, last movement 0).
-- Read on production 2026-09-23: 0 of 73 active items carry movement_controlled_at; four hold one session-22
-- baseline movement each; purchases, usage, the Telegram /count and the dashboard stepper all write qty_on_hand
-- without a movement. So the first normal stock change on any of those four items read as a ledger disagreement.
-- The check's own comment says "ledger-controlled items"; this makes the code say the same. Negative stock is
-- still a problem for every item.
--
-- health_checks_core_v1 is restated in full. Its body was not retyped: a script cut it from
-- 20260923010000_money_checks_from_accounting_start.sql, asserted the cut hashes to the live md5(prosrc)
-- f54b5cb4dde2ccc2d223ae5ace8d16f3 (read 2026-09-23), then applied two exact one-hit replacements in the inventory check.
-- New md5(prosrc) 7564fc5c867a11ecc73df9ace925a018. Nothing else changes: the other ten checks, the grants and both wrappers.

begin;

create or replace function public.health_checks_core_v1(p_property_id uuid, p_fin boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_today date; v_start date; v_fin boolean; v_hc record; v_out jsonb := '[]'::jsonb; v_checks jsonb := '[]'::jsonb;
begin
  v_fin := p_fin;
  v_today := public.manila_today();
  -- D-219: money before the accounting start is historical and accepted (Lloyd 2026-09-23). No start on
  -- record means no cut-off, which is how every check behaved before this.
  v_start := coalesce((select s.accounting_start from public.acct_settings s where s.property_id = p_property_id), '-infinity'::date);

  -- Ledger ↔ reservations: every confirmed payout e-mail names its stay.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_rows_linked', 'l', 'Payout e-mails linked to a stay', 's', case when count(*) = 0 then 'pass' else 'fail' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'ref', t.external_ref, 'date', t.transaction_date, 'amount', t.gross_amount)) filter (where t.id is not null), '[]'::jsonb))
  from (select * from public.transactions where property_id = p_property_id and source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null limit 20) t);

  -- Reservations ↔ payouts: every completed stay has a confirmed payout row.
  v_checks := v_checks || (select jsonb_build_object('k', 'completed_stays_paid', 'l', 'Completed stays with a payout row', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
    coalesce(jsonb_agg(jsonb_build_object('code', rr.confirmation_code, 'guest', rr.guest_name, 'checkout', rr.checkout_date, 'payout', rr.host_payout)) filter (where rr.id is not null), '[]'::jsonb))
  from (select * from public.airbnb_reservations x where x.property_id = p_property_id and x.status = 'completed' and x.checkout_date < v_today and x.checkout_date >= v_start
        and not exists (select 1 from public.transactions t where t.reservation_id = x.id and t.source = 'airbnb_payout_email' and t.status = 'confirmed') limit 20) rr);

  -- Payout totals: Σ reservation payout_amount = Σ payout e-mails + Σ Airbnb adjustments.
  v_checks := v_checks || (select jsonb_build_object('k', 'payout_totals_agree', 'l', 'Reservation payouts equal payout e-mails plus adjustments', 's', case when abs(d.diff) < 1 then 'pass' else 'warn' end, 'n', 0, 'd',
    jsonb_build_object('reservationPayouts', d.res, 'payoutEmails', d.em, 'adjustments', d.adj, 'difference', d.diff))
  from (select res, em, adj, res - em - adj diff from (
    select (select coalesce(sum(payout_amount), 0) from public.airbnb_reservations where property_id = p_property_id and payout_amount is not null and checkout_date >= v_start) res,
           (select coalesce(sum(t.gross_amount), 0) from public.transactions t join public.airbnb_reservations r on r.id = t.reservation_id
             where t.property_id = p_property_id and t.source = 'airbnb_payout_email' and t.status = 'confirmed' and r.checkout_date >= v_start) em,
           (select coalesce(sum(gross_amount), 0) from public.transactions where property_id = p_property_id and source = 'airbnb' and txn_type = 'expense' and category = 'airbnb_adjustment' and status = 'confirmed' and transaction_date >= v_start) adj) x) d);

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
  from (select x.id, x.name, x.qty_on_hand, x.movement_controlled_at, (select quantity_after from public.inventory_stock_movements m where m.item_id = x.id order by sequence_no desc limit 1) last_after
        from public.inventory_items x where x.property_id = p_property_id and x.is_active) i
  where i.qty_on_hand < 0 or (i.movement_controlled_at is not null and i.last_after is not null and i.last_after <> i.qty_on_hand));

  if v_fin then
    -- Ledger: duplicate live rows (same date, amount, payee, type, source).
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_duplicates', 'l', 'Duplicate ledger rows', 's', case when count(*) = 0 then 'pass' else 'warn' end, 'n', count(*)::int, 'd',
      coalesce(jsonb_agg(jsonb_build_object('date', g.transaction_date, 'amount', g.gross_amount, 'payee', g.payee, 'n', g.n)), '[]'::jsonb))
    from (select transaction_date, gross_amount, coalesce(payee_name, '') payee, count(*) n from public.transactions
          where property_id = p_property_id and status <> 'void' and source not in ('airbnb','airbnb_email')
          group by transaction_date, gross_amount, coalesce(payee_name, ''), txn_type, source having count(*) > 1 limit 20) g);

    -- Ledger position: income − expenses − drawings on confirmed, non-mirror rows.
    v_checks := v_checks || (select jsonb_build_object('k', 'ledger_position', 'l', 'Cash position: income − expenses − drawings', 's', case when p.opening + p.net < 0 then 'warn' else 'pass' end, 'n', 0, 'd',
      -- D-219: income - expenses - drawings is money left over, never expected to be zero. The position is
      -- the opening cash plus what moved since the accounting start; only a position below zero is wrong.
      -- net carries the position, so the problem sentence reads the amount it is about.
      jsonb_build_object('opening', p.opening, 'income', p.inc, 'expenses', p.exp, 'drawings', p.drw, 'net', p.opening + p.net, 'since', v_start, 'asOf', v_today))
    from (select inc, exp, drw, inc - exp - drw net,
            (select coalesce(sum(l.debit - l.credit), 0) from public.acct_journal_lines l join public.acct_journals j on j.id = l.journal_id join public.acct_accounts a on a.id = l.account_id
              where j.property_id = p_property_id and j.event_kind = 'opening_balance' and j.status = 'posted' and a.is_cash) opening
          from (
      select coalesce(sum(gross_amount) filter (where txn_type = 'income'), 0) inc, coalesce(sum(gross_amount) filter (where txn_type = 'expense'), 0) exp, coalesce(sum(gross_amount) filter (where txn_type = 'drawing'), 0) drw
      from public.transactions where property_id = p_property_id and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= v_today and transaction_date >= v_start) x) p);

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

revoke all on function public.health_checks_core_v1(uuid, boolean) from public, anon, authenticated;

commit;
