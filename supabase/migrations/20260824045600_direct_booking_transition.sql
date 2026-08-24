create or replace function public.apply_direct_booking_transition(p_booking_id uuid, p_action text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare bk public.booking_inquiries%rowtype; reservation_id uuid; calendar_id uuid; target_status text; operation text; sync_hash text;
begin
  if p_action not in ('confirm','cancel') then raise exception 'invalid_action'; end if;
  select * into bk from public.booking_inquiries where id=p_booking_id for update;
  if not found then raise exception 'booking_not_found'; end if;
  target_status := case when p_action='confirm' then 'confirmed' else 'cancelled' end;
  operation := case when p_action='confirm' then 'upsert' else 'cancel' end;
  update public.booking_inquiries set status=target_status where id=bk.id and status is distinct from target_status;
  insert into public.airbnb_reservations (property_id,confirmation_code,source,status,guest_id,guest_name,guest_count,checkin_date,checkout_date,guest_paid,cancelled_at)
  values (bk.property_id,'DIRECT:'||bk.id::text,'direct',target_status,bk.guest_id,bk.guest_name,bk.pax,bk.checkin_date,bk.checkout_date,bk.total_amount,case when target_status='cancelled' then now() else null end)
  on conflict (confirmation_code) do update set status=excluded.status, guest_id=excluded.guest_id, guest_name=excluded.guest_name, guest_count=excluded.guest_count, checkin_date=excluded.checkin_date, checkout_date=excluded.checkout_date, cancelled_at=excluded.cancelled_at
  returning id into reservation_id;
  update public.calendar_events set uid='cascade-direct-'||bk.id::text, status=case when target_status='confirmed' then 'confirmed' else 'cancelled' end, linked_reservation_id=reservation_id, recon_status='matched', updated_at=now()
  where property_id=bk.property_id and uid in ('direct:'||bk.id::text,'cascade-direct-'||bk.id::text)
  returning id into calendar_id;
  if calendar_id is null then
    insert into public.calendar_events (property_id,uid,source,status,checkin_date,checkout_date,guest_name,guest_phone,linked_reservation_id,recon_status)
    values (bk.property_id,'cascade-direct-'||bk.id::text,'direct',case when target_status='confirmed' then 'confirmed' else 'cancelled' end,bk.checkin_date,bk.checkout_date,bk.guest_name,bk.guest_phone,reservation_id,'matched') returning id into calendar_id;
  end if;
  update public.transactions set status=case when target_status='confirmed' then 'confirmed' else 'void' end where external_ref=bk.id::text;
  sync_hash := encode(extensions.digest(concat_ws('|',bk.id::text,target_status,bk.checkin_date::text,bk.checkout_date::text),'sha256'),'hex');
  insert into public.automation_outbox (event_type,aggregate_type,aggregate_id,idempotency_key,payload)
  values ('calendar.projection_requested','calendar_event',calendar_id,'calendar.projection_requested:'||calendar_id::text||':'||sync_hash,jsonb_build_object('schema_version',1,'booking_type','direct','booking_id',bk.id,'calendar_event_id',calendar_id,'operation',operation,'sync_hash',sync_hash))
  on conflict (idempotency_key) do nothing;
  return calendar_id;
end $$;
revoke all on function public.apply_direct_booking_transition(uuid,text) from public,anon,authenticated;
grant execute on function public.apply_direct_booking_transition(uuid,text) to service_role;
