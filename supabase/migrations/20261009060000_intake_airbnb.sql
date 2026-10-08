-- Session 79, D-323: the "Before you arrive" intake link for a confirmed Airbnb stay. Owners/admins make it from Telegram /intake (Finance
-- group only) and the host shares it by hand; Cassy's Airbnb drafts never carry a link. intake_resolve_v1 now also resolves a
-- booking_type 'airbnb' token to ONE airbnb_reservations row with source 'airbnb' (never a DIRECT:<uuid> mirror row) that is confirmed (status 'confirmed', no cancelled_at), has a guest_id and
-- has not checked out (Manila date). ref = confirmation_code. Same eight columns, so intake_guest_context_v1 and both save RPCs work
-- unchanged (they key on guest_id and property_id). The direct branch is the 20261007130000 text, unchanged.
-- guest_access_tokens_booking_type_check already allows 'airbnb' (checked live 2026-10-09), so no constraint change.
-- Replace only: one function body, same signature, owner, grants and comment shape. Rollback: supabase/rollbacks/20261009_intake_airbnb.sql

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
     and b.checkout_date >= (now() at time zone 'Asia/Manila')::date
  union all
  select a.id, a.property_id, a.guest_id, a.confirmation_code, a.checkin_date, a.checkout_date, a.guest_count, g.name
    from public.guest_access_tokens t
    join public.airbnb_reservations a on a.id = t.booking_id and a.source = 'airbnb'
    join public.guests g on g.id = a.guest_id
   where p_token_hash ~ '^[a-f0-9]{64}$'
     and t.token_hash = p_token_hash and t.booking_type = 'airbnb' and t.revoked_at is null and t.expires_at > now()
     and a.status = 'confirmed' and a.cancelled_at is null
     and a.checkout_date >= (now() at time zone 'Asia/Manila')::date;
$$;

revoke all on function public.intake_resolve_v1(text) from public, anon, authenticated, service_role;
comment on function public.intake_resolve_v1(text) is 'SPEC-42 s4b + D-323: token hash -> the one confirmed direct booking or confirmed Airbnb reservation (with a guest) it opens (not revoked, expired, cancelled or past check-out). Internal.';

commit;
