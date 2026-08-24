create or replace function public.enqueue_booking_outbox_event()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare
  event_name text;
  event_key text;
  event_payload jsonb;
begin
  if tg_op = 'INSERT' and new.source = 'direct' then
    event_name := 'booking.requested';
    event_key := 'booking.requested:' || new.id::text;
  elsif tg_op = 'UPDATE' and old.receipt_image_path is null and new.receipt_image_path is not null then
    event_name := 'booking.receipt_uploaded';
    event_key := 'booking.receipt_uploaded:' || new.id::text || ':' || new.receipt_image_path;
  elsif tg_op = 'UPDATE' and new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    event_name := 'booking.confirmed';
    event_key := 'booking.confirmed:' || new.id::text;
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    event_name := 'booking.cancelled';
    event_key := 'booking.cancelled:' || new.id::text;
  else
    return new;
  end if;
  event_payload := jsonb_build_object(
    'schema_version', 1,
    'booking_id', new.id,
    'booking_ref', upper(left(new.id::text, 8)),
    'status', new.status,
    'checkin_date', new.checkin_date,
    'checkout_date', new.checkout_date,
    'total_amount', new.total_amount,
    'deposit_amount', new.deposit_amount
  );
  insert into public.automation_outbox (event_type, aggregate_type, aggregate_id, idempotency_key, payload)
  values (event_name, 'booking_inquiry', new.id, event_key, event_payload)
  on conflict (idempotency_key) do nothing;
  return new;
end $$;

drop trigger if exists booking_outbox_events on public.booking_inquiries;
create trigger booking_outbox_events
after insert or update of receipt_image_path, status on public.booking_inquiries
for each row execute function public.enqueue_booking_outbox_event();
