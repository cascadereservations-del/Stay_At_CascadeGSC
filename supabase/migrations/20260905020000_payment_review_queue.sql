-- Module D local candidate: named Finance review queue.
-- This RPC is read-only. Booking decisions continue through the reviewed
-- decide_direct_booking transaction exposed by approve-booking.

create or replace function public.get_payment_review_queue(
  p_property_id uuid,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_items jsonb;
begin
  if p_property_id is null or p_limit not between 1 and 100 then
    raise exception using errcode = '22023', message = 'invalid review queue request';
  end if;
  if not public.current_staff_authorized('read_finance', p_property_id) then
    raise exception using errcode = '42501', message = 'Finance review queue denied';
  end if;

  with latest as (
    select distinct on (comparison.booking_id) comparison.*
    from public.payment_evidence_comparisons comparison
    where comparison.property_id = p_property_id
    order by comparison.booking_id, comparison.created_at desc, comparison.id desc
  ), queue as (
    select
      latest.created_at as queue_created_at,
      jsonb_build_object(
        'booking_id', booking.id,
        'booking_ref', upper(left(booking.id::text, 8)),
        'guest_name', booking.guest_name,
        'checkin_date', booking.checkin_date,
        'checkout_date', booking.checkout_date,
        'booking_status', booking.status,
        'expected_amount', latest.expected_amount,
        'expected_currency', latest.expected_currency,
        'comparison', jsonb_build_object(
          'id', latest.id,
          'outcome', latest.comparison_outcome,
          'amount_delta', latest.amount_delta,
          'reference_match', latest.reference_match,
          'reason_codes', latest.reason_codes,
          'algorithm_version', latest.algorithm_version,
          'created_at', latest.created_at
        ),
        'evidence', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', evidence.id,
            'source_type', evidence.source_type,
            'source_artifact_id', evidence.source_artifact_id,
            'parser_version', evidence.parser_version,
            'observed_at', evidence.observed_at,
            'parsed_at', evidence.parsed_at,
            'amount', evidence.normalized_amount,
            'currency', evidence.normalized_currency,
            'reference', evidence.normalized_reference,
            'advisory_confidence', evidence.advisory_confidence,
            'advisory_labels', evidence.advisory_labels,
            'source_admissibility', evidence.source_admissibility,
            'failure_code', evidence.failure_code,
            'candidate_status', evidence.candidate_status,
            'duplicate_of_candidate_id', evidence.duplicate_of_candidate_id
          ) order by evidence.observed_at, evidence.id)
          from public.payment_evidence_candidates evidence
          where evidence.id = any(latest.evidence_candidate_ids)
        ), '[]'::jsonb),
        'review_history', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', review.id,
            'reviewer_user_id', review.reviewer_user_id,
            'outcome', review.outcome,
            'reason', review.reason,
            'reviewed_at', review.reviewed_at
          ) order by review.reviewed_at, review.id)
          from public.payment_finance_reviews review
          where review.comparison_id = latest.id
        ), '[]'::jsonb),
        'review_state', coalesce((
          select review.outcome
          from public.payment_finance_reviews review
          where review.comparison_id = latest.id
            and review.outcome in ('approved', 'rejected')
          order by review.reviewed_at desc, review.id desc
          limit 1
        ), 'needs_review')
      ) as item
    from latest
    join public.booking_inquiries booking on booking.id = latest.booking_id
    order by latest.created_at desc, latest.id desc
    limit p_limit
  )
  select coalesce(jsonb_agg(item order by queue_created_at desc), '[]'::jsonb)
    into v_items from queue;

  return jsonb_build_object(
    'property_id', p_property_id,
    'generated_at', now(),
    'items', v_items
  );
end;
$$;

revoke all on function public.get_payment_review_queue(uuid,integer)
  from public, anon, service_role;
grant execute on function public.get_payment_review_queue(uuid,integer)
  to authenticated;

comment on function public.get_payment_review_queue(uuid,integer) is
  'Finance-only, AAL2, property-scoped review queue. Read-only and unavailable to OPS/service integrations.';

-- Route booking events at creation time. Finance events may contain expected
-- amounts; guest events contain stay state only. OPS is never a booking-event
-- recipient and receives separate post-confirmation operational events later.
create or replace function public.enqueue_booking_outbox_event()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare
  v_event_name text;
  v_event_key text;
  v_route_class text;
  v_template_key text;
  v_payload jsonb;
begin
  if tg_op = 'INSERT' and new.source = 'direct' then
    v_event_name := 'booking.requested';
    v_event_key := 'booking.requested:' || new.id::text;
    v_route_class := 'finance';
    v_template_key := 'finance.booking_requested';
  elsif tg_op = 'UPDATE' and old.receipt_image_path is null and new.receipt_image_path is not null then
    v_event_name := 'booking.receipt_uploaded';
    v_event_key := 'booking.receipt_uploaded:' || new.id::text || ':' || new.receipt_image_path;
    v_route_class := 'finance';
    v_template_key := 'finance.payment_evidence_received';
  elsif tg_op = 'UPDATE' and new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    v_event_name := 'booking.confirmed';
    v_event_key := 'booking.confirmed:' || new.id::text;
    v_route_class := 'guest';
    v_template_key := 'guest.booking_confirmed';
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    v_event_name := 'booking.cancelled';
    v_event_key := 'booking.cancelled:' || new.id::text;
    v_route_class := 'guest';
    v_template_key := 'guest.booking_cancelled';
  else
    return new;
  end if;

  v_payload := jsonb_build_object(
    'schema_version', 1,
    'booking_id', new.id,
    'booking_ref', upper(left(new.id::text, 8)),
    'status', new.status,
    'checkin_date', new.checkin_date,
    'checkout_date', new.checkout_date
  );
  if v_route_class = 'finance' then
    v_payload := v_payload || jsonb_build_object(
      'total_amount', new.total_amount,
      'deposit_amount', new.deposit_amount
    );
  end if;

  insert into public.automation_outbox (
    event_type, aggregate_type, aggregate_id, idempotency_key, payload,
    route_class, template_key
  ) values (
    v_event_name, 'booking_inquiry', new.id, v_event_key, v_payload,
    v_route_class, v_template_key
  ) on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

alter table public.automation_delivery_log
  add column callback_id text
    check (callback_id is null or callback_id ~ '^[A-Za-z0-9][A-Za-z0-9:_-]{15,159}$');
create unique index automation_delivery_callback_id_unique_idx
  on public.automation_delivery_log(callback_id)
  where callback_id is not null;

create or replace function public.record_automation_delivery_callback(
  p_callback_id text,
  p_outbox_id uuid,
  p_workflow_id text,
  p_channel text,
  p_status text,
  p_recipient_hash text default null,
  p_provider_message_id text default null,
  p_error_code text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted_id uuid;
  v_outbox_status text;
begin
  if p_callback_id is null or p_callback_id !~ '^[A-Za-z0-9][A-Za-z0-9:_-]{15,159}$'
    or p_workflow_id not in ('CH-S01','CH-W01','CH-W02','CH-W03','CH-W04','CH-W05','CH-W06','CH-W07','CH-W08','CH-W09','CH-W10','CH-W11','CH-W12')
    or p_channel not in ('email','telegram','whatsapp','internal')
    or p_status not in ('sent','failed','skipped')
    or (p_error_code is not null and p_error_code !~ '^[A-Za-z0-9_]{1,64}$') then
    raise exception using errcode = '22023', message = 'invalid delivery callback';
  end if;

  insert into public.automation_delivery_log (
    callback_id, outbox_id, workflow_id, channel, status, recipient_hash,
    provider_message_id, error_code, completed_at
  ) values (
    p_callback_id, p_outbox_id, p_workflow_id, p_channel, p_status,
    left(p_recipient_hash, 128), left(p_provider_message_id, 256), p_error_code,
    case when p_status in ('sent','skipped') then now() else null end
  ) on conflict (callback_id) where callback_id is not null do nothing
  returning id into v_inserted_id;

  if v_inserted_id is null then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  v_outbox_status := case
    when p_status = 'failed' then 'failed'
    when p_channel = 'internal' then 'completed'
    else 'dispatched'
  end;
  update public.automation_outbox
  set status = v_outbox_status,
      completed_at = case when v_outbox_status = 'completed' then now() else completed_at end,
      last_error_code = p_error_code,
      attempt_count = attempt_count + 1
  where id = p_outbox_id and status <> 'completed';
  if not found then
    perform 1 from public.automation_outbox where id = p_outbox_id;
    if not found then raise exception using errcode = '22023', message = 'outbox event not found'; end if;
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'outbox_status', v_outbox_status);
end;
$$;

revoke all on function public.record_automation_delivery_callback(text,uuid,text,text,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.record_automation_delivery_callback(text,uuid,text,text,text,text,text,text)
  to service_role;

comment on function public.record_automation_delivery_callback(text,uuid,text,text,text,text,text,text) is
  'Idempotent delivery-only callback. It cannot update booking, payment, calendar, or Finance review state.';
