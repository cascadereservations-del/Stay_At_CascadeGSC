-- Sprint 0 (2026-09-16, D-160): Today's "Messenger handoffs need a human reply" action never
-- fired because get_admin_overview_v1 filtered concierge_handoffs on status = 'pending', a value
-- the table's check constraint forbids (open | sent | dismissed). Seven cards were open and
-- invisible. One literal changed; run_health_checks_v1 gains an open-handoff check so the next
-- drift is visible in Settings -> System health. Read-only functions; no data changes.
begin;

create or replace function public.get_admin_overview_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date; v_fin boolean; v_manage boolean; v_current jsonb; v_arrivals jsonb; v_departures jsonb; v_next jsonb;
  v_readiness jsonb; v_blockers jsonb; v_stock jsonb; v_followups jsonb; v_handoffs jsonb; v_finance jsonb; v_actions jsonb := '[]'::jsonb;
  v_notices jsonb; v_asof timestamptz; v_sync jsonb; v_next_checkin date; v_last_checkout date; v_clean jsonb; v_review jsonb; v_missed_days integer;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  v_manage := public.current_staff_authorized('manage_operations', p_property_id);
  v_today := public.manila_today();

  select coalesce(jsonb_agg(jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights, 'actualState', 'unknown')), '[]'::jsonb) into v_current
  from public.admin_stays_v1(p_property_id) s where s.status in ('confirmed','completed') and s.checkin <= v_today and s.checkout > v_today;
  select coalesce(jsonb_agg(jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights) order by s.checkin), '[]'::jsonb) into v_arrivals
  from public.admin_stays_v1(p_property_id) s where s.status = 'confirmed' and s.checkin = v_today;
  select coalesce(jsonb_agg(jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout) order by s.checkout), '[]'::jsonb) into v_departures
  from public.admin_stays_v1(p_property_id) s where s.status in ('confirmed','completed') and s.checkout = v_today;
  select jsonb_build_object('kind', s.stay_kind, 'id', s.stay_id, 'code', s.code, 'guest', s.guest_name, 'guestId', s.guest_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights, 'daysUntil', s.checkin - v_today), s.checkin
    into v_next, v_next_checkin
  from public.admin_stays_v1(p_property_id) s where s.status = 'confirmed' and s.checkin > v_today order by s.checkin limit 1;
  select max(s.checkout) into v_last_checkout from public.admin_stays_v1(p_property_id) s where s.status in ('confirmed','completed') and s.checkout <= v_today;

  -- Readiness: latest cleaning since the last checkout, latest human review for the next arrival, open blocking work.
  select jsonb_build_object('id', c.id, 'cleanedAt', c.cleaned_at, 'cleaner', c.cleaner_name, 'complete', c.is_complete, 'completionPct', c.completion_pct, 'issues', c.issue_count, 'meterPhotos', c.meter_photo_count) into v_clean
  from public.cleaning_sessions c where c.property_id = p_property_id and (v_last_checkout is null or c.cleaned_at::date >= v_last_checkout) order by c.cleaned_at desc limit 1;
  select jsonb_build_object('id', r.id, 'outcome', r.outcome, 'reason', r.reason, 'reviewedAt', r.reviewed_at, 'forCheckin', r.for_checkin_date) into v_review
  from public.readiness_reviews r where r.property_id = p_property_id and r.for_checkin_date = coalesce(v_next_checkin, v_today) order by r.reviewed_at desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'title', w.title, 'priority', w.priority, 'status', w.status, 'dueAt', w.due_at, 'assignee', w.assignee_user_id) order by w.due_at nulls last), '[]'::jsonb) into v_blockers
  from public.work_orders w where w.property_id = p_property_id and w.blocks_arrival and w.status not in ('resolved','cancelled');

  -- Same threshold as get_missed_cleanings/missed-cleaning-alert: only relevant when
  -- readiness would otherwise be 'unknown' (v_clean is null), so a checkout with a real
  -- report never gets flagged just because it happens to also appear in the lookback.
  select mc.days_overdue into v_missed_days
  from public.get_missed_cleanings(p_property_id, 14) mc
  where mc.checkout_date = v_last_checkout
  order by mc.days_overdue desc
  limit 1;

  v_readiness := jsonb_build_object(
    'state', case when v_review->>'outcome' in ('ready','override_ready') and jsonb_array_length(v_blockers) = 0 then 'ready'
                  when v_review->>'outcome' = 'not_ready' or jsonb_array_length(v_blockers) > 0 then 'not_ready'
                  when v_clean is null and v_missed_days is not null then 'overdue'
                  when v_clean is null then 'unknown' else 'awaiting_review' end,
    'lastCleaning', v_clean, 'review', v_review, 'blockingWorkOrders', jsonb_array_length(v_blockers), 'lastCheckout', v_last_checkout, 'nextCheckin', v_next_checkin,
    'daysOverdue', v_missed_days);

  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'qty', i.qty_on_hand, 'unit', i.unit, 'reorderBelow', i.reorder_below, 'out', i.qty_on_hand <= 0) order by i.qty_on_hand), '[]'::jsonb) into v_stock
  from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below;
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'title', f.title, 'purpose', f.purpose, 'priority', f.priority, 'dueAt', f.due_at, 'guestId', f.guest_id, 'status', f.status) order by f.due_at nulls last), '[]'::jsonb) into v_followups
  from public.follow_up_tasks f where f.property_id = p_property_id and f.status in ('open','in_progress');
  if v_manage then
    select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'guest', h.guest_name, 'risk', h.risk, 'status', h.status, 'createdAt', h.created_at, 'excerpt', left(h.guest_text, 120)) order by h.created_at desc), '[]'::jsonb) into v_handoffs
    from public.concierge_handoffs h where h.status = 'open';
  else
    v_handoffs := null;
  end if;
  if v_fin then
    select jsonb_build_object(
      'pendingReviewCount', (select count(*) from public.transactions t where t.property_id = p_property_id and t.status = 'pending_review'),
      'pendingReviewAmount', (select coalesce(sum(gross_amount), 0)::text from public.transactions t where t.property_id = p_property_id and t.status = 'pending_review'),
      'paymentReviewCount', (select count(*) from public.payment_evidence_comparisons c where c.property_id = p_property_id and not exists (select 1 from public.payment_finance_reviews r where r.comparison_id = c.id)),
      'unpaidCleanerFees', (select count(*) from public.cleaning_sessions c where c.property_id = p_property_id and c.fee_amount > 0 and c.fee_paid_at is null)
    ) into v_finance;
  else
    v_finance := null; -- never "all clear"; the client renders "not available for this role"
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.notice_type, 'title', n.title, 'effectiveDate', n.effective_date, 'expiresAt', n.expires_at, 'audience', n.audience) order by n.effective_date), '[]'::jsonb) into v_notices
  from public.ops_notices n where n.property_id = p_property_id and n.is_active and (n.expires_at is null or n.expires_at > now()) and n.effective_date >= v_today - 1;
  select jsonb_build_object('syncedAt', l.synced_at, 'status', l.status, 'error', l.error_msg) into v_sync from public.calendar_sync_log l where l.property_id = p_property_id order by l.synced_at desc limit 1;
  select greatest((select max(updated_at) from public.airbnb_reservations where property_id = p_property_id), (select max(cleaned_at) from public.cleaning_sessions where property_id = p_property_id), (select max(updated_at) from public.inventory_items where property_id = p_property_id)) into v_asof;

  -- Action queue (TOD02): 1 arrival blocked / long-overdue missing report, 2 overdue work / recent missing report, 3 pending decisions, 4 follow-ups, 5 stock/admin.
  if v_next_checkin is not null and v_next_checkin - v_today <= 2 and v_readiness->>'state' <> 'ready' then
    v_actions := v_actions || jsonb_build_object('priority', 1, 'kind', 'arrival_readiness', 'title', 'Arrival on ' || v_next_checkin::text || ' is not confirmed ready', 'reason', 'Readiness state is ' || replace(v_readiness->>'state', '_', ' '), 'href', '/operations', 'dueAt', v_next_checkin, 'sourceKind', 'readiness', 'sourceId', null);
  end if;
  if v_missed_days is not null then
    v_actions := v_actions || jsonb_build_object('priority', case when v_missed_days >= 3 then 1 else 2 end, 'kind', 'missed_cleaning', 'title', 'No cleaning report filed, ' || v_missed_days::text || ' day' || case when v_missed_days = 1 then '' else 's' end || ' overdue', 'reason', 'Checkout ' || v_last_checkout::text || ' has no matching cleaning session', 'href', '/operations', 'dueAt', v_last_checkout, 'sourceKind', 'cleaning_session', 'sourceId', null);
  end if;
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', case when w.blocks_arrival then 1 else 2 end, 'kind', 'work_order', 'title', w.title, 'reason', case when w.blocks_arrival then 'Blocks the next arrival' when w.due_at < now() then 'Overdue' else 'Open ' || w.priority || ' work' end, 'href', '/operations/work-orders?id=' || w.id::text, 'dueAt', w.due_at, 'assignee', w.assignee_user_id, 'sourceKind', 'work_order', 'sourceId', w.id))
    from public.work_orders w where w.property_id = p_property_id and w.status not in ('resolved','cancelled') and (w.blocks_arrival or w.due_at < now() or w.priority in ('high','urgent'))), '[]'::jsonb);
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', 3, 'kind', 'inquiry', 'title', 'Decide inquiry from ' || s.guest_name, 'reason', 'Direct booking request for ' || s.checkin::text, 'href', '/bookings/inquiries', 'dueAt', s.checkin, 'sourceKind', 'booking_inquiry', 'sourceId', s.stay_id))
    from public.admin_stays_v1(p_property_id) s where s.status = 'inquiry' and s.checkin >= v_today), '[]'::jsonb);
  if v_fin and (v_finance->>'pendingReviewCount')::int > 0 then
    v_actions := v_actions || jsonb_build_object('priority', 3, 'kind', 'finance_review', 'title', (v_finance->>'pendingReviewCount') || ' transactions await finance review', 'reason', 'Displayed totals exclude them', 'href', '/finance', 'dueAt', null, 'sourceKind', 'transactions', 'sourceId', null);
  end if;
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', 4, 'kind', 'follow_up', 'title', f.title, 'reason', replace(f.purpose, '_', ' ') || case when f.due_at < now() then ' (overdue)' else '' end, 'href', '/guests/' || coalesce(f.guest_id::text, '') || '?task=' || f.id::text, 'dueAt', f.due_at, 'assignee', f.assignee_user_id, 'sourceKind', 'follow_up_task', 'sourceId', f.id))
    from public.follow_up_tasks f where f.property_id = p_property_id and f.status in ('open','in_progress')), '[]'::jsonb);
  if v_handoffs is not null and jsonb_array_length(v_handoffs) > 0 then
    v_actions := v_actions || jsonb_build_object('priority', 4, 'kind', 'concierge_handoff', 'title', jsonb_array_length(v_handoffs)::text || ' Messenger handoffs need a human reply', 'reason', 'Concierge escalated to staff', 'href', '/guests?handoffs=1', 'dueAt', null, 'sourceKind', 'concierge_handoffs', 'sourceId', null);
  end if;
  v_actions := v_actions || coalesce((select jsonb_agg(jsonb_build_object('priority', 5, 'kind', 'low_stock', 'title', i.name || ' is ' || case when i.qty_on_hand <= 0 then 'out of stock' else 'low (' || i.qty_on_hand::text || ' ' || i.unit || ')' end, 'reason', 'Below reorder level ' || i.reorder_below::text, 'href', '/inventory?attention=low', 'dueAt', null, 'sourceKind', 'inventory_item', 'sourceId', i.id))
    from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below), '[]'::jsonb);

  return jsonb_build_object('today', v_today, 'sourceAsOf', v_asof, 'calendarSync', v_sync, 'currentStays', v_current, 'arrivals', v_arrivals, 'departures', v_departures, 'nextArrival', v_next,
    'readiness', v_readiness, 'blockingWorkOrders', v_blockers, 'lowStock', v_stock, 'followUps', v_followups, 'handoffs', v_handoffs, 'finance', v_finance, 'notices', v_notices,
    'actions', (select coalesce(jsonb_agg(a order by (a->>'priority')::int, a->>'dueAt' nulls last), '[]'::jsonb) from jsonb_array_elements(v_actions) a));
end;
$$;

create or replace function public.run_health_checks_v1(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_today date; v_fin boolean; v_hc record; v_out jsonb := '[]'::jsonb; v_checks jsonb := '[]'::jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
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

commit;
