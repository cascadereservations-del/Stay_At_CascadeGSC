-- Session 72, SPEC-42 s6 (H9): booking status page. A direct guest holds a capability link (guest_access_tokens, minted by
-- submit-booking, stored hashed, never the raw token). The guest-access Edge Function turns the token into one read through this
-- RPC. Why an RPC: service_role has no grant on booking_holds, so the hold deadline can only be read by a definer function.
-- The RPC is the whole data boundary: it returns ONE booking's schedule, headcount, amounts and hold deadline, and never a name,
-- phone, e-mail, address, door code, receipt path or any other guest. Invalid, revoked, expired and unknown tokens all return null.
-- Expand only: one function, one index. No data change. Rollback: supabase/rollbacks/20261006_booking_status_tokens.sql

begin;

create index if not exists guest_access_tokens_booking_id_idx on public.guest_access_tokens (booking_id);

create or replace function public.guest_booking_status_v1(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.guest_access_tokens%rowtype;
  b public.booking_inquiries%rowtype;
  h public.booking_holds%rowtype;
begin
  -- The caller supplies the SHA-256 of the token, never the token. A 64-hex check keeps junk out of the lookup.
  if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then return null; end if;
  select * into t from public.guest_access_tokens where token_hash = p_token_hash;
  if not found or t.booking_type <> 'direct' or t.revoked_at is not null or t.expires_at <= now() then return null; end if;
  select * into b from public.booking_inquiries where id = t.booking_id and source = 'direct';
  if not found then return null; end if;
  select * into h from public.booking_holds where booking_id = b.id order by created_at desc limit 1;
  update public.guest_access_tokens set last_used_at = now() where id = t.id;
  return jsonb_build_object(
    'ref', upper(left(b.id::text, 8)),
    'booking_id', b.id,
    'status', b.status,
    'checkin_date', b.checkin_date,
    'checkout_date', b.checkout_date,
    'pax', b.pax,
    'total_amount', b.total_amount,
    'deposit_amount', b.deposit_amount,
    'has_receipt', b.receipt_image_path is not null,
    'hold_status', h.status,
    'hold_expires_at', h.expires_at,
    'server_now', now()
  );
end $$;

comment on function public.guest_booking_status_v1(text) is 'Guest status page read: one booking by the SHA-256 of its capability token. Returns null for any invalid token. Never returns a name, contact, address, door code or receipt path.';

revoke all on function public.guest_booking_status_v1(text) from public, anon, authenticated;
grant execute on function public.guest_booking_status_v1(text) to service_role;

commit;
