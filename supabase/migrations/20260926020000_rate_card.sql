-- 20260926020000_rate_card.sql
-- Session 55 (Opus 5): release rate_card_20260926 - SPEC-34 rate settings and promotions (D-259, D-261, D-262).
--
-- One stored rate card that every module reads: the base nightly rate and the length-of-stay tiers live in the
-- existing booking_rate_policy_versions (terms.tiers, terms.deposit_pct); dated promotions live in rate_promotions.
-- get_rate_card_v1() is the one public read (prices only - the card is on the booking site anyway). Writes go only
-- through publish_rate_card_v1 / save_rate_promotion_v1 / end_rate_promotion_v1 (staff permission
-- publish_rate_policy = owner/admin), each audited in booking_lifecycle_events. Seed = today's card (PHP 1,780;
-- 5/10/15/20/25% at 2/5/7/14/28 nights; 50% fee) and the Anniversary Promotion (PHP 1,543 a night, nights
-- 2026-10-11..2026-10-17). PHP 1,929 is stored nowhere (D-262: poster only). No stored booking amount changes.

begin;

-- The audit log names the two promotion events.
alter table public.booking_lifecycle_events drop constraint booking_lifecycle_events_event_type_check;
alter table public.booking_lifecycle_events add constraint booking_lifecycle_events_event_type_check check (event_type = any (array[
  'hold_created', 'hold_expired', 'amended', 'cancelled', 'no_show', 'refund_authorized', 'calendar_reconciled',
  'rate_policy_published', 'rate_promotion_saved', 'rate_promotion_ended']));

-- Seed version 1 = today's card, open-ended from 2025-01-01, approved by the owner.
insert into public.booking_rate_policy_versions (property_id, effective_from, effective_to, nightly_rate, currency, terms, approved_by, idempotency_key)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2025-01-01', null, 1780, 'PHP',
       '{"tiers":[{"min_nights":2,"pct":5},{"min_nights":5,"pct":10},{"min_nights":7,"pct":15},{"min_nights":14,"pct":20},{"min_nights":28,"pct":25}],"deposit_pct":50}'::jsonb,
       (select user_id from public.staff_access_profiles where role = 'owner' and disabled_at is null order by user_id limit 1),
       'seed:rate-card-v1-20260926'
where not exists (select 1 from public.booking_rate_policy_versions where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');

create table if not exists public.rate_promotions (
  id           uuid primary key default gen_random_uuid(),
  property_id  uuid not null references public.properties(id) on delete restrict,
  name         text not null check (char_length(btrim(name)) between 3 and 80),
  first_night  date not null,
  last_night   date not null,
  nightly_rate numeric not null check (nightly_rate > 0 and nightly_rate < 100000),
  active       boolean not null default true,
  created_by   uuid references auth.users(id) on delete restrict,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (last_night >= first_night),
  -- ponytail: one property, so the range alone is exclusive; add property_id (btree_gist) for a second property.
  constraint rate_promotions_no_overlap exclude using gist (daterange(first_night, last_night, '[]') with &&) where (active)
);

alter table public.rate_promotions enable row level security;
revoke all on table public.rate_promotions from public, anon, authenticated;
grant select on table public.rate_promotions to authenticated;
grant select, insert, update on table public.rate_promotions to service_role;
drop policy if exists rate_promotions_staff_read on public.rate_promotions;
create policy rate_promotions_staff_read on public.rate_promotions for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

insert into public.rate_promotions (property_id, name, first_night, last_night, nightly_rate, created_by)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Anniversary Promotion', date '2026-10-11', date '2026-10-17', 1543,
       (select user_id from public.staff_access_profiles where role = 'owner' and disabled_at is null order by user_id limit 1)
where not exists (select 1 from public.rate_promotions where name = 'Anniversary Promotion' and first_night = date '2026-10-11');

-- The public card: the version in force today (Manila) and every active promotion not yet over.
-- ponytail: a version scheduled from a later date is not quoted until its day comes; quote by stay date if that matters.
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
    'promotions', coalesce((
      select jsonb_agg(jsonb_build_object('name', p.name, 'first_night', p.first_night, 'last_night', p.last_night, 'nightly_rate', p.nightly_rate) order by p.first_night)
      from public.rate_promotions p, today
      where p.property_id = p_property_id and p.active and p.last_night >= today.d), '[]'::jsonb))
  from v;
$function$;

-- A new base / tiers from a date: closes the open version the day before and opens the next, in one transaction.
-- Same start date as the open version = a correction of it in place (the audit keeps the old terms).
create or replace function public.publish_rate_card_v1(p_base numeric, p_tiers jsonb, p_effective_from date, p_reason text,
  p_idempotency_key text, p_deposit_pct numeric default 50, p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_open public.booking_rate_policy_versions%rowtype;
  v_id uuid;
  v_terms jsonb;
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  if auth.uid() is null or not public.current_staff_authorized('publish_rate_policy', p_property_id) then
    raise exception using errcode = '42501', message = 'rate card publication denied';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
    or p_effective_from is null or p_effective_from < v_today
    or p_base is null or p_base <= 0 or p_base >= 100000
    or p_deposit_pct is null or p_deposit_pct <= 0 or p_deposit_pct > 100
    or jsonb_typeof(p_tiers) is distinct from 'array'
    or exists (select 1 from jsonb_array_elements(p_tiers) t
               where jsonb_typeof(t -> 'min_nights') is distinct from 'number' or jsonb_typeof(t -> 'pct') is distinct from 'number'
                  or (t ->> 'min_nights')::numeric <> trunc((t ->> 'min_nights')::numeric)
                  or (t ->> 'min_nights')::numeric < 2 or (t ->> 'pct')::numeric <= 0 or (t ->> 'pct')::numeric >= 100)
    or (select count(distinct (t ->> 'min_nights')::numeric) from jsonb_array_elements(p_tiers) t) <> jsonb_array_length(p_tiers) then
    raise exception using errcode = '22023', message = 'invalid rate card';
  end if;

  v_terms := jsonb_build_object('deposit_pct', p_deposit_pct, 'tiers', coalesce((
    select jsonb_agg(jsonb_build_object('min_nights', (t ->> 'min_nights')::int, 'pct', (t ->> 'pct')::numeric) order by (t ->> 'min_nights')::int)
    from jsonb_array_elements(p_tiers) t), '[]'::jsonb));

  perform pg_advisory_xact_lock(hashtextextended('cascade-rate-policy:' || p_property_id::text, 0));
  select id into v_id from public.booking_rate_policy_versions where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;

  select * into v_open from public.booking_rate_policy_versions where property_id = p_property_id and effective_to is null;
  if v_open.id is not null and v_open.effective_from > p_effective_from then
    raise exception using errcode = '22023', message = 'a later rate card is already scheduled';
  elsif v_open.id is not null and v_open.effective_from = p_effective_from then
    update public.booking_rate_policy_versions set nightly_rate = p_base, terms = v_terms, approved_by = auth.uid(), approved_at = now()
    where id = v_open.id returning id into v_id;
  else
    if v_open.id is not null then
      update public.booking_rate_policy_versions set effective_to = p_effective_from - 1 where id = v_open.id;
    end if;
    insert into public.booking_rate_policy_versions (property_id, effective_from, effective_to, nightly_rate, currency, terms, approved_by, idempotency_key)
    values (p_property_id, p_effective_from, null, p_base, 'PHP', v_terms, auth.uid(), p_idempotency_key)
    returning id into v_id;
  end if;

  insert into public.booking_lifecycle_events (property_id, booking_id, event_type, actor_user_id, reason, idempotency_key, before_state, after_state)
  values (p_property_id, null, 'rate_policy_published', auth.uid(), btrim(p_reason), 'audit:' || p_idempotency_key,
          coalesce(to_jsonb(v_open), '{}'::jsonb),
          jsonb_build_object('rate_policy_version_id', v_id, 'base', p_base, 'terms', v_terms, 'effective_from', p_effective_from));
  return v_id;
end;
$function$;

-- Create (p_id null) or edit an active promotion. Overlap with another active promotion is refused (23P01).
create or replace function public.save_rate_promotion_v1(p_id uuid, p_name text, p_first_night date, p_last_night date,
  p_nightly_rate numeric, p_reason text, p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_before jsonb;
  v_id uuid;
begin
  if auth.uid() is null or not public.current_staff_authorized('publish_rate_policy', p_property_id) then
    raise exception using errcode = '42501', message = 'rate promotion denied';
  end if;
  if p_name is null or char_length(btrim(p_name)) not between 3 and 80
    or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
    or p_first_night is null or p_last_night is null or p_last_night < p_first_night
    or p_last_night < (now() at time zone 'Asia/Manila')::date
    or p_nightly_rate is null or p_nightly_rate <= 0 or p_nightly_rate >= 100000 then
    raise exception using errcode = '22023', message = 'invalid rate promotion';
  end if;

  if p_id is null then
    insert into public.rate_promotions (property_id, name, first_night, last_night, nightly_rate, created_by)
    values (p_property_id, btrim(p_name), p_first_night, p_last_night, p_nightly_rate, auth.uid())
    returning id into v_id;
  else
    select to_jsonb(p) into v_before from public.rate_promotions p where p.id = p_id and p.property_id = p_property_id and p.active;
    if v_before is null then
      raise exception using errcode = 'P0002', message = 'no active promotion with that id';
    end if;
    update public.rate_promotions set name = btrim(p_name), first_night = p_first_night, last_night = p_last_night,
      nightly_rate = p_nightly_rate, updated_at = now()
    where id = p_id returning id into v_id;
  end if;

  insert into public.booking_lifecycle_events (property_id, booking_id, event_type, actor_user_id, reason, idempotency_key, before_state, after_state)
  select p_property_id, null, 'rate_promotion_saved', auth.uid(), btrim(p_reason), 'promo:' || gen_random_uuid()::text,
         coalesce(v_before, '{}'::jsonb), to_jsonb(p)
  from public.rate_promotions p where p.id = v_id;
  return v_id;
end;
$function$;

-- End a promotion: it stops being quoted at once (stored bookings keep what they were quoted).
create or replace function public.end_rate_promotion_v1(p_id uuid, p_reason text)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_row public.rate_promotions%rowtype;
begin
  select * into v_row from public.rate_promotions where id = p_id;
  if auth.uid() is null or v_row.id is null or not public.current_staff_authorized('publish_rate_policy', v_row.property_id) then
    raise exception using errcode = '42501', message = 'rate promotion denied';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000 then
    raise exception using errcode = '22023', message = 'invalid rate promotion';
  end if;
  if not v_row.active then return false; end if;
  update public.rate_promotions set active = false, updated_at = now() where id = p_id;
  insert into public.booking_lifecycle_events (property_id, booking_id, event_type, actor_user_id, reason, idempotency_key, before_state, after_state)
  values (v_row.property_id, null, 'rate_promotion_ended', auth.uid(), btrim(p_reason), 'promo:' || gen_random_uuid()::text,
          to_jsonb(v_row), jsonb_build_object('id', p_id, 'active', false));
  return true;
end;
$function$;

-- A hold records the card it was opened under (the column and FK existed; the hold RPC in use never set it).
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
          (public.get_rate_card_v1(b.property_id) ->> 'version_id')::uuid)
  on conflict (idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select id, expires_at into v_id, v_exp from public.booking_holds where idempotency_key = 'hold:' || b.id::text;
  end if;
  return jsonb_build_object('ok', true, 'hold_id', v_id, 'expires_at', v_exp);
end $function$;

revoke all on function public.get_rate_card_v1(uuid) from public;
grant execute on function public.get_rate_card_v1(uuid) to anon, authenticated, service_role;
revoke all on function public.publish_rate_card_v1(numeric, jsonb, date, text, text, numeric, uuid) from public, anon;
grant execute on function public.publish_rate_card_v1(numeric, jsonb, date, text, text, numeric, uuid) to authenticated;
revoke all on function public.save_rate_promotion_v1(uuid, text, date, date, numeric, text, uuid) from public, anon;
grant execute on function public.save_rate_promotion_v1(uuid, text, date, date, numeric, text, uuid) to authenticated;
revoke all on function public.end_rate_promotion_v1(uuid, text) from public, anon;
grant execute on function public.end_rate_promotion_v1(uuid, text) to authenticated;

-- app_settings nightly_rate_php / deposit_percent stay as inert rows: an expand release deletes nothing, and once
-- submit-booking reads terms.deposit_pct nothing reads either. Retire them in a later contract release.

commit;
