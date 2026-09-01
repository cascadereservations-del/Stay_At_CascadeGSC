-- Wave 1 / Module B (local release candidate only).
--
-- One human-approved direct-booking decision owns the booking, reservation,
-- calendar, ledger and projection-outbox writes. Provider notifications are
-- deliberately absent: they are delivery concerns handled from the outbox.

create table if not exists public.booking_decisions (
  id uuid primary key default extensions.uuid_generate_v4(),
  -- booking_inquiries.id is not constrained unique in the legacy production
  -- schema, so this candidate keeps a logical reference rather than adding an
  -- incompatible foreign key. The decision RPC locks and validates it.
  booking_id uuid not null,
  action text not null check (action in ('confirm', 'decline')),
  outcome text not null check (outcome in ('confirmed', 'declined', 'conflict', 'invalid_state')),
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  -- calendar_events.id has the same legacy missing-unique-constraint issue.
  -- Keep this as a logical reference until the foundational key repair has its
  -- own reviewed expand/contract release.
  calendar_event_id uuid,
  created_at timestamptz not null default now()
);

create index if not exists booking_decisions_booking_created_idx
  on public.booking_decisions (booking_id, created_at desc);

alter table public.booking_decisions enable row level security;
revoke all on public.booking_decisions from anon, authenticated;
grant all on public.booking_decisions to service_role;

create or replace function public.decide_direct_booking(
  p_booking_id uuid,
  p_action text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.booking_inquiries%rowtype;
  v_existing public.booking_decisions%rowtype;
  v_reservation_id uuid;
  v_calendar_event_id uuid;
  v_conflict boolean;
  v_sync_hash text;
begin
  if p_action not in ('confirm', 'decline') then
    raise exception 'invalid_booking_decision_action';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception 'invalid_booking_decision_idempotency_key';
  end if;

  -- Serialize retries for this decision before reading or writing booking state.
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-decision:' || p_idempotency_key, 0));
  select * into v_existing
  from public.booking_decisions
  where idempotency_key = p_idempotency_key;

  if found then
    return jsonb_build_object(
      'ok', v_existing.outcome in ('confirmed', 'declined'),
      'outcome', v_existing.outcome,
      'booking_id', v_existing.booking_id,
      'calendar_event_id', v_existing.calendar_event_id,
      'already_processed', true
    );
  end if;

  select * into v_booking
  from public.booking_inquiries
  where id = p_booking_id and source = 'direct'
  for update;
  if not found then
    raise exception 'direct_booking_not_found';
  end if;

  -- A property-wide transaction lock closes the time-of-check/time-of-use gap
  -- between separate Finance approvals for the same property.
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || v_booking.property_id::text, 0));

  if v_booking.status = 'confirmed' then
    insert into public.booking_decisions (booking_id, action, outcome, idempotency_key)
    values (v_booking.id, p_action, 'invalid_state', p_idempotency_key);
    return jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'booking_id', v_booking.id, 'already_processed', false);
  end if;

  if v_booking.status = 'cancelled' then
    insert into public.booking_decisions (booking_id, action, outcome, idempotency_key)
    values (v_booking.id, p_action, 'invalid_state', p_idempotency_key);
    return jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'booking_id', v_booking.id, 'already_processed', false);
  end if;

  select id into v_calendar_event_id
  from public.calendar_events
  where property_id = v_booking.property_id
    and uid in ('direct:' || v_booking.id::text, 'cascade-direct-' || v_booking.id::text)
  order by case when uid = 'direct:' || v_booking.id::text then 0 else 1 end
  limit 1
  for update;

  if p_action = 'decline' then
    update public.booking_inquiries set status = 'cancelled' where id = v_booking.id;
    if v_calendar_event_id is not null then
      update public.calendar_events set status = 'cancelled', recon_status = 'matched', updated_at = now()
      where id = v_calendar_event_id;
    end if;
    update public.transactions set status = 'void' where external_ref = v_booking.id::text;
    insert into public.booking_decisions (booking_id, action, outcome, idempotency_key, calendar_event_id)
    values (v_booking.id, p_action, 'declined', p_idempotency_key, v_calendar_event_id);
    return jsonb_build_object('ok', true, 'outcome', 'declined', 'booking_id', v_booking.id, 'calendar_event_id', v_calendar_event_id, 'already_processed', false);
  end if;

  select exists (
    select 1
    from public.calendar_events ce
    where ce.property_id = v_booking.property_id
      and ce.status in ('confirmed', 'blocked')
      and ce.checkin_date < v_booking.checkout_date
      and ce.checkout_date > v_booking.checkin_date
      and ce.uid not in ('direct:' || v_booking.id::text, 'cascade-direct-' || v_booking.id::text)
  ) into v_conflict;

  if v_conflict then
    insert into public.booking_decisions (booking_id, action, outcome, idempotency_key, calendar_event_id)
    values (v_booking.id, p_action, 'conflict', p_idempotency_key, v_calendar_event_id);
    return jsonb_build_object('ok', false, 'outcome', 'conflict', 'booking_id', v_booking.id, 'calendar_event_id', v_calendar_event_id, 'already_processed', false);
  end if;

  update public.booking_inquiries set status = 'confirmed' where id = v_booking.id;
  insert into public.airbnb_reservations (
    property_id, confirmation_code, source, status, guest_id, guest_name,
    guest_count, checkin_date, checkout_date, guest_paid, cancelled_at
  ) values (
    v_booking.property_id, 'DIRECT:' || v_booking.id::text, 'direct', 'confirmed',
    v_booking.guest_id, v_booking.guest_name, v_booking.pax,
    v_booking.checkin_date, v_booking.checkout_date, v_booking.total_amount, null
  ) on conflict (confirmation_code) do update set
    status = excluded.status,
    guest_id = excluded.guest_id,
    guest_name = excluded.guest_name,
    guest_count = excluded.guest_count,
    checkin_date = excluded.checkin_date,
    checkout_date = excluded.checkout_date,
    guest_paid = excluded.guest_paid,
    cancelled_at = null
  returning id into v_reservation_id;

  if v_calendar_event_id is null then
    insert into public.calendar_events (
      property_id, uid, source, status, checkin_date, checkout_date,
      guest_name, guest_phone, linked_reservation_id, recon_status
    ) values (
      v_booking.property_id, 'cascade-direct-' || v_booking.id::text, 'direct', 'confirmed',
      v_booking.checkin_date, v_booking.checkout_date, v_booking.guest_name,
      v_booking.guest_phone, v_reservation_id, 'matched'
    ) returning id into v_calendar_event_id;
  else
    update public.calendar_events set
      uid = 'cascade-direct-' || v_booking.id::text,
      status = 'confirmed',
      linked_reservation_id = v_reservation_id,
      recon_status = 'matched',
      updated_at = now()
    where id = v_calendar_event_id;
  end if;

  update public.transactions set status = 'confirmed' where external_ref = v_booking.id::text;
  v_sync_hash := encode(extensions.digest(concat_ws('|', v_booking.id::text, 'confirmed', v_booking.checkin_date::text, v_booking.checkout_date::text), 'sha256'), 'hex');
  insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, payload)
  values (
    'calendar.projection_requested', 'calendar_event', v_calendar_event_id,
    'calendar.projection_requested:' || v_calendar_event_id::text || ':' || v_sync_hash,
    jsonb_build_object(
      'schema_version', 1,
      'booking_type', 'direct',
      'booking_id', v_booking.id,
      'calendar_event_id', v_calendar_event_id,
      'operation', 'upsert',
      'sync_hash', v_sync_hash
    )
  ) on conflict (idempotency_key) do nothing;

  insert into public.booking_decisions (booking_id, action, outcome, idempotency_key, calendar_event_id)
  values (v_booking.id, p_action, 'confirmed', p_idempotency_key, v_calendar_event_id);
  return jsonb_build_object('ok', true, 'outcome', 'confirmed', 'booking_id', v_booking.id, 'calendar_event_id', v_calendar_event_id, 'already_processed', false);
end;
$$;

revoke all on function public.decide_direct_booking(uuid, text, text) from public, anon, authenticated;
grant execute on function public.decide_direct_booking(uuid, text, text) to service_role;
