-- Today's readiness card and action queue currently have no time dimension: a checkout
-- with no cleaning session sits at readiness state 'unknown' forever, and the only alert
-- path (arrival_readiness) fires solely when a next arrival is within 2 days -- a missed
-- report with no imminent arrival produces zero signal on Today at all.
--
-- A separate live system already solves exactly this: get_missed_cleanings (the function
-- backing missed-cleaning-alert's daily 08:00 Manila Telegram nag) flags a checkout the
-- day after it has no matching report, within a 14-day lookback. Reusing that function's
-- own threshold here, rather than inventing a second number, keeps Today and the Telegram
-- alert as one source of truth.
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
    from public.concierge_handoffs h where h.status = 'pending';
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
revoke all on function public.get_admin_overview_v1(uuid) from public, anon, service_role;
grant execute on function public.get_admin_overview_v1(uuid) to authenticated;

commit;
