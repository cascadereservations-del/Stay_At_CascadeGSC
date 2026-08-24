create or replace function public.upsert_guest_for_booking(
  p_property_id uuid,
  p_booking_id uuid,
  p_guest_name text,
  p_phone_e164 text,
  p_email_normalized text,
  p_source text default 'direct'
) returns table (guest_id uuid, match_basis text, previous_completed_stays integer, total_completed_nights integer, is_returning boolean)
language plpgsql security definer set search_path = '' as $$
declare phone_guest public.guests%rowtype; email_guest public.guests%rowtype; resolved_id uuid; basis text;
begin
  if p_phone_e164 is not null then select * into phone_guest from public.guests where property_id=p_property_id and phone_e164=p_phone_e164 for update; end if;
  if p_email_normalized is not null then select * into email_guest from public.guests where property_id=p_property_id and email_normalized=p_email_normalized for update; end if;
  if phone_guest.id is not null and email_guest.id is not null and phone_guest.id <> email_guest.id then
    insert into public.guest_identity_conflicts (booking_key,phone_guest_id,email_guest_id,match_bases)
    values (p_booking_id::text,phone_guest.id,email_guest.id,array['phone','email']) on conflict (booking_key) where status='open' do nothing;
    return query select null::uuid,'conflict'::text,0,0,false; return;
  end if;
  if phone_guest.id is not null then resolved_id:=phone_guest.id; basis:='phone';
  elsif p_phone_e164 is null and email_guest.id is not null then resolved_id:=email_guest.id; basis:='email';
  else
    insert into public.guests (property_id,name,phone,email,phone_e164,email_normalized,source,transactional_email_allowed)
    values (p_property_id,p_guest_name,p_phone_e164,p_email_normalized,p_phone_e164,p_email_normalized,p_source,p_email_normalized is not null)
    returning id into resolved_id; basis:='new';
  end if;
  update public.booking_inquiries set guest_id=resolved_id where id=p_booking_id;
  return query select resolved_id,basis,0,0,false;
end $$;
revoke all on function public.upsert_guest_for_booking(uuid,uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.upsert_guest_for_booking(uuid,uuid,text,text,text,text) to service_role;
