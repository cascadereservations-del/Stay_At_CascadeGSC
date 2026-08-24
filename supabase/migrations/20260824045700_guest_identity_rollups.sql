-- Derive return status from the canonical guest ID, never from a name supplied
-- by the browser. This replaces the initial resolver with a version that also
-- records one idempotent host-alert event per eligible booking.
create or replace function public.upsert_guest_for_booking(
  p_property_id uuid,
  p_booking_id uuid,
  p_guest_name text,
  p_phone_e164 text,
  p_email_normalized text,
  p_source text default 'direct'
) returns table (guest_id uuid, match_basis text, previous_completed_stays integer, total_completed_nights integer, is_returning boolean)
language plpgsql security definer set search_path = '' as $$
declare
  phone_guest public.guests%rowtype;
  email_guest public.guests%rowtype;
  booking public.booking_inquiries%rowtype;
  resolved_id uuid;
  basis text;
  previous_stays integer := 0;
  previous_nights integer := 0;
begin
  select * into booking from public.booking_inquiries where id = p_booking_id for update;
  if not found or booking.property_id <> p_property_id then
    raise exception 'booking_not_found';
  end if;

  if p_phone_e164 is not null then
    select * into phone_guest from public.guests where property_id = p_property_id and phone_e164 = p_phone_e164 for update;
  end if;
  if p_email_normalized is not null then
    select * into email_guest from public.guests where property_id = p_property_id and email_normalized = p_email_normalized for update;
  end if;
  if phone_guest.id is not null and email_guest.id is not null and phone_guest.id <> email_guest.id then
    insert into public.guest_identity_conflicts (booking_key,phone_guest_id,email_guest_id,match_bases)
    values (p_booking_id::text,phone_guest.id,email_guest.id,array['phone','email'])
    on conflict (booking_key) where status = 'open' do nothing;
    return query select null::uuid,'conflict'::text,0,0,false;
    return;
  end if;
  if phone_guest.id is not null then
    resolved_id := phone_guest.id;
    basis := 'phone';
  elsif p_phone_e164 is null and email_guest.id is not null then
    resolved_id := email_guest.id;
    basis := 'email';
  else
    insert into public.guests (property_id,name,phone,email,phone_e164,email_normalized,source,transactional_email_allowed)
    values (p_property_id,p_guest_name,p_phone_e164,p_email_normalized,p_phone_e164,p_email_normalized,p_source,p_email_normalized is not null)
    returning id into resolved_id;
    basis := 'new';
  end if;

  update public.booking_inquiries set guest_id = resolved_id where id = p_booking_id;
  select count(*)::integer, coalesce(sum(nights), 0)::integer
    into previous_stays, previous_nights
    from public.airbnb_reservations as reservation
   where reservation.property_id = p_property_id
     and reservation.guest_id = resolved_id
     and reservation.status in ('confirmed','completed')
     and reservation.checkout_date < booking.checkin_date;

  if previous_stays > 0 then
    insert into public.automation_outbox (event_type,aggregate_type,aggregate_id,idempotency_key,payload)
    values (
      'guest.returning_detected',
      'guest',
      resolved_id,
      'guest.returning_detected:' || p_booking_id::text,
      jsonb_build_object('schema_version',1,'booking_type','direct','booking_id',p_booking_id,'guest_id',resolved_id,'previous_completed_stays',previous_stays,'total_completed_nights',previous_nights)
    ) on conflict (idempotency_key) do nothing;
  end if;

  return query select resolved_id,basis,previous_stays,previous_nights,previous_stays > 0;
end $$;

revoke all on function public.upsert_guest_for_booking(uuid,uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.upsert_guest_for_booking(uuid,uuid,text,text,text,text) to service_role;
