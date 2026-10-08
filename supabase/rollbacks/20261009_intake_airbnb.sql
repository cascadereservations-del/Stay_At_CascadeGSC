-- Compensating rollback for 20261009060000_intake_airbnb.sql (session 79, D-323): intake_resolve_v1 back to the direct-only body of
-- 20261007130000_guest_intake.sql. Airbnb tokens already minted then open nothing (neutral 404); companions and photos they saved stay.
begin;
create or replace function public.intake_resolve_v1(p_token_hash text)
returns table (booking_id uuid, property_id uuid, guest_id uuid, ref text, checkin_date date, checkout_date date, pax integer, guest_name text)
language sql stable security definer set search_path = '' as $$
  select b.id, b.property_id, b.guest_id, upper(left(b.id::text, 8)), b.checkin_date, b.checkout_date, b.pax::integer, g.name
    from public.guest_access_tokens t
    join public.booking_inquiries b on b.id = t.booking_id and b.source = 'direct'
    left join public.guests g on g.id = b.guest_id
   where p_token_hash ~ '^[a-f0-9]{64}$'
     and t.token_hash = p_token_hash and t.booking_type = 'direct' and t.revoked_at is null and t.expires_at > now()
     and b.status = 'confirmed'
     and b.checkout_date >= (now() at time zone 'Asia/Manila')::date;
$$;
revoke all on function public.intake_resolve_v1(text) from public, anon, authenticated, service_role;
comment on function public.intake_resolve_v1(text) is 'SPEC-42 s4b: token hash -> the one confirmed direct booking it opens (not revoked, expired, cancelled or past check-out). Internal.';
commit;
