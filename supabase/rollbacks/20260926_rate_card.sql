-- Compensating rollback for release rate_card_20260926 (SPEC-34).
-- Roll the functions back FIRST (submit-booking, rate-card, messenger-concierge, telegram-cassy to their previous
-- commits) or they fall back to the seed card baked into pricing.ts and log rate_card_fallback on every quote.
-- Stored booking amounts are untouched either way. Promotions and card versions are lost: export them first
-- (select * from public.rate_promotions; select * from public.booking_rate_policy_versions) if Lloyd edited any.
begin;
drop function if exists public.get_rate_card_v1(uuid);
drop function if exists public.publish_rate_card_v1(numeric, jsonb, date, text, text, numeric, uuid);
drop function if exists public.save_rate_promotion_v1(uuid, text, date, date, numeric, text, uuid);
drop function if exists public.end_rate_promotion_v1(uuid, text);

-- open_booking_hold_v1 as before the release (no rate_policy_version_id stamp).
create or replace function public.open_booking_hold_v1(p_booking_id uuid, p_hours integer default 24)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare b public.booking_inquiries%rowtype; v_exp timestamptz; v_id uuid;
begin
  select * into b from public.booking_inquiries where id = p_booking_id;
  if b.id is null or b.source <> 'direct' or b.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_pending_direct');
  end if;
  v_exp := now() + make_interval(hours => greatest(1, least(p_hours, 168)));
  insert into public.booking_holds (property_id, booking_id, checkin_date, checkout_date, expires_at, status, idempotency_key)
  values (b.property_id, b.id, b.checkin_date, b.checkout_date, v_exp, 'active', 'hold:' || b.id::text)
  on conflict (idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select id, expires_at into v_id, v_exp from public.booking_holds where idempotency_key = 'hold:' || b.id::text;
  end if;
  return jsonb_build_object('ok', true, 'hold_id', v_id, 'expires_at', v_exp);
end $function$;

update public.booking_holds set rate_policy_version_id = null where rate_policy_version_id is not null;
delete from public.booking_lifecycle_events where event_type in ('rate_policy_published', 'rate_promotion_saved', 'rate_promotion_ended');
delete from public.booking_rate_policy_versions;
drop table if exists public.rate_promotions;

alter table public.booking_lifecycle_events drop constraint booking_lifecycle_events_event_type_check;
alter table public.booking_lifecycle_events add constraint booking_lifecycle_events_event_type_check check (event_type = any (array[
  'hold_created', 'hold_expired', 'amended', 'cancelled', 'no_show', 'refund_authorized', 'calendar_reconciled',
  'rate_policy_published']));
commit;
