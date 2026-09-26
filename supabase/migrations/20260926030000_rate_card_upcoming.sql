-- 20260926030000_rate_card_upcoming.sql
-- Session 55 (Opus 5): release rate_card_upcoming_20260926 - SPEC-34 review finding 1.
--
-- get_rate_card_v1 returned only the card in force TODAY, so a card published to start on a later date did not price
-- stays after that date until the day came (a stay booked today for December was quoted on today's card). The card now
-- also lists the versions scheduled after today (`upcoming`: effective_from, base, tiers, deposit_pct), and pricing.ts
-- quote() prices a stay with the version in force on its CHECK-IN date. Same signature, same grants; readers that
-- ignore `upcoming` behave exactly as before. open_booking_hold_v1 stamps the version in force on the check-in date.

begin;

create or replace function public.get_rate_card_v1(p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with today as (select (now() at time zone 'Asia/Manila')::date d),
  v as (
    select r.* from public.booking_rate_policy_versions r, today
    where r.property_id = p_property_id and r.effective_from <= today.d and (r.effective_to is null or r.effective_to >= today.d)
    order by r.effective_from desc limit 1
  )
  select jsonb_build_object(
    'base', v.nightly_rate,
    'currency', v.currency,
    'deposit_pct', coalesce((v.terms ->> 'deposit_pct')::numeric, 50),
    'tiers', coalesce(v.terms -> 'tiers', '[]'::jsonb),
    'version_id', v.id,
    'effective_from', v.effective_from,
    'upcoming', coalesce((
      select jsonb_agg(jsonb_build_object('effective_from', u.effective_from, 'base', u.nightly_rate,
        'deposit_pct', coalesce((u.terms ->> 'deposit_pct')::numeric, 50), 'tiers', coalesce(u.terms -> 'tiers', '[]'::jsonb), 'version_id', u.id)
        order by u.effective_from)
      from public.booking_rate_policy_versions u, today
      where u.property_id = p_property_id and u.effective_from > today.d), '[]'::jsonb),
    'promotions', coalesce((
      select jsonb_agg(jsonb_build_object('name', p.name, 'first_night', p.first_night, 'last_night', p.last_night, 'nightly_rate', p.nightly_rate) order by p.first_night)
      from public.rate_promotions p, today
      where p.property_id = p_property_id and p.active and p.last_night >= today.d), '[]'::jsonb))
  from v;
$function$;

revoke all on function public.get_rate_card_v1(uuid) from public;
grant execute on function public.get_rate_card_v1(uuid) to anon, authenticated, service_role;

-- The hold records the card version in force on the stay's check-in date (the one its quote used).
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
  insert into public.booking_holds (property_id, booking_id, checkin_date, checkout_date, expires_at, status, idempotency_key, rate_policy_version_id)
  values (b.property_id, b.id, b.checkin_date, b.checkout_date, v_exp, 'active', 'hold:' || b.id::text,
          (select r.id from public.booking_rate_policy_versions r
            where r.property_id = b.property_id and r.effective_from <= b.checkin_date and (r.effective_to is null or r.effective_to >= b.checkin_date)
            order by r.effective_from desc limit 1))
  on conflict (idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select id, expires_at into v_id, v_exp from public.booking_holds where idempotency_key = 'hold:' || b.id::text;
  end if;
  return jsonb_build_object('ok', true, 'hold_id', v_id, 'expires_at', v_exp);
end $function$;

commit;
