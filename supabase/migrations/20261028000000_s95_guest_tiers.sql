-- 20261028000000_s95_guest_tiers.sql
-- Session 95, lane SQL: release s95_guest_tiers_20261028 (SPEC-46 returning-guest tiers; contract: Cascade/docs/s95/CONTRACT-tiers.md; D-342, D-344).
-- Four tiers on guests.tier: NULL, returning (2+ completed stays), regular (4+ stays or 10+ nights), vip (7+ stays or 20+ nights). guests.tier is the EFFECTIVE tier
-- = coalesce(guests.tier_manual, computed). "Completed" = an Airbnb reservation that is completed, or confirmed with a checkout before today (Manila), excluding the
-- DIRECT:% mirrors, plus confirmed direct bookings (booking_inquiries) whose checkout is before today. Upcoming stays never count toward a tier.
-- (1) guests.tier_manual, guests.tier_changed_at, CHECKs on tier and tier_manual (the tier CHECK goes on after the backfill).
-- (2) refresh_guest_stats(uuid) replaced, same signature: total_stays / total_nights_stayed / first / last exactly as before (upcoming confirmed stays still count there),
--     tier from the rule above; on a change of the effective tier it stamps tier_changed_at and writes ONE guest_profile_history row. It is now SECURITY DEFINER (it must
--     write the history table, which service_role cannot) so it is revoked from anon and authenticated; service_role (airbnb-email-sync) and the definer merge functions keep it.
--     updated_at now moves only when a stored value changes (the nightly job must not touch every guest every night).
-- (3) guest_tier_v1, guest_ordinal_v1, guest_completed_stats_v1 (internal helpers), guest_tier_line_v1 (staff-facing benefits line).
-- (4) staff_guest_card_v1: two new keys, tier and tier_line; nothing else changes (same grants as today).
-- (5) admin_set_guest_tier_v1 (owner/admin): set or clear the manual tier with a required reason.
-- (6) refresh_all_guest_tiers_v1 + job_heartbeats seed + pg_cron guest-tiers-nightly (10 16 * * * = 00:10 Manila).
-- (7) backfill: every guest refreshed once, the tier CHECK then added.
-- Guards: the two replaced bodies must be the live ones this was cut from (md5 of prosrc, CR stripped), else 55000 and nothing changes.
-- To undo apply supabase/rollbacks/20261028_s95_guest_tiers.sql.

begin;

do $$
declare v_got text; r record;
begin
  for r in select * from (values
      ('public.refresh_guest_stats(uuid)', '4c2739962ed0dbd0bc240756df488e93'),
      ('public.staff_guest_card_v1(uuid,uuid,date)', '9fae8f114017a3a98f0bd02541a7e0af')) v(sig, md) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v_got is distinct from r.md then
      raise exception 's95 guest tiers: % is not the body this release was cut from (md5 %): re-cut it from the live body', r.sig, v_got using errcode = '55000';
    end if;
  end loop;
end $$;

-- 1. columns and checks ------------------------------------------------------------------------------------------------------------------------
alter table public.guests add column tier_manual text null;
alter table public.guests add column tier_changed_at timestamptz null;
alter table public.guests add constraint guests_tier_manual_check check (tier_manual in ('returning', 'regular', 'vip'));
comment on column public.guests.tier is 'S95: EFFECTIVE tier = coalesce(tier_manual, computed). NULL, returning, regular or vip. Written only by refresh_guest_stats.';
comment on column public.guests.tier_manual is 'S95: tier set by hand by the owner or an admin (admin_set_guest_tier_v1); NULL = automatic.';
comment on column public.guests.tier_changed_at is 'S95: when the effective tier last changed.';

-- 2. helpers ------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.guest_tier_v1(p_stays integer, p_nights integer)
returns text language sql immutable set search_path = '' as $$
  select case
    when coalesce(p_stays, 0) >= 7 or coalesce(p_nights, 0) >= 20 then 'vip'
    when coalesce(p_stays, 0) >= 4 or coalesce(p_nights, 0) >= 10 then 'regular'
    when coalesce(p_stays, 0) >= 2 then 'returning'
  end;
$$;

create or replace function public.guest_ordinal_v1(p_n integer)
returns text language sql immutable set search_path = '' as $$
  select p_n::text || case
    when p_n % 100 in (11, 12, 13) then 'th'
    when p_n % 10 = 1 then 'st'
    when p_n % 10 = 2 then 'nd'
    when p_n % 10 = 3 then 'rd'
    else 'th' end;
$$;

-- completed stays and nights of one guest (the tier rule); the DIRECT:% mirrors are skipped because the same stay is counted from booking_inquiries (B192)
create or replace function public.guest_completed_stats_v1(p_guest_id uuid)
returns table (stays integer, nights integer)
language sql stable set search_path = '' as $$
  with s as (
    select a.nights from public.airbnb_reservations a
     where a.guest_id = p_guest_id and a.confirmation_code not like 'DIRECT:%'
       and (a.status = 'completed' or (a.status = 'confirmed' and a.checkout_date < (now() at time zone 'Asia/Manila')::date))
    union all
    select b.nights from public.booking_inquiries b
     where b.guest_id = p_guest_id and b.status = 'confirmed' and b.checkout_date < (now() at time zone 'Asia/Manila')::date)
  select count(*)::integer, coalesce(sum(s.nights), 0)::integer from s;
$$;

-- staff-facing benefits line for the stay being prepared (completed stays so far + 1); no contact data. Same wording is kept in the admin dashboard constant.
create or replace function public.guest_tier_line_v1(p_tier text, p_completed_stays integer)
returns text language sql stable set search_path = '' as $$
  select case p_tier
    when 'returning' then 'Returning guest (' || public.guest_ordinal_v1(coalesce(p_completed_stays, 0) + 1) || ' stay): welcome treat (local coffee sachets + snack); first hour of early check-in or late check-out free if the calendar allows.'
    when 'regular'   then 'Regular guest (' || public.guest_ordinal_v1(coalesce(p_completed_stays, 0) + 1) || ' stay): welcome treat (local coffee sachets + snack); up to 2 hours early check-in or late check-out free if the calendar allows; set up their saved preferences.'
    when 'vip'       then 'VIP guest (' || public.guest_ordinal_v1(coalesce(p_completed_stays, 0) + 1) || ' stay): welcome treat (local coffee sachets + snack) and a handwritten welcome note; up to 2 hours early or late free if the calendar allows; mid-stay refresh at any stay length; set up their saved preferences.'
  end;
$$;

-- 3. refresh_guest_stats ------------------------------------------------------------------------------------------------------------------------
-- admin_set_guest_tier_v1 hands its actor and reason to this function through the transaction-local settings cascade.tier_actor / cascade.tier_reason.
create or replace function public.refresh_guest_stats(p_guest_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stays  integer; v_nights integer; v_first date; v_last date;
  v_cs integer; v_cn integer;
  v_old text; v_manual text; v_new text;
  v_actor uuid := nullif(current_setting('cascade.tier_actor', true), '')::uuid;
  v_reason text := nullif(current_setting('cascade.tier_reason', true), '');
begin
  select tier, tier_manual into v_old, v_manual from public.guests where id = p_guest_id for update;
  if not found then return; end if;

  select
    count(*) filter (where status in ('completed','confirmed')),
    coalesce(sum(nights) filter (where status = 'completed'), 0),
    min(checkin_date) filter (where status in ('completed','confirmed')),
    max(checkin_date) filter (where status in ('completed','confirmed'))
  into v_stays, v_nights, v_first, v_last
  from public.airbnb_reservations
  where guest_id = p_guest_id;

  select s.stays, s.nights into v_cs, v_cn from public.guest_completed_stats_v1(p_guest_id) s;
  v_new := coalesce(v_manual, public.guest_tier_v1(v_cs, v_cn));

  update public.guests set
    total_stays = v_stays,
    total_nights_stayed = v_nights,
    first_stay_date = v_first,
    last_stay_date = v_last,
    tier = v_new,
    tier_changed_at = case when v_new is distinct from v_old then now() else tier_changed_at end,
    updated_at = now()
  where id = p_guest_id
    and (total_stays, total_nights_stayed, first_stay_date, last_stay_date, tier)
        is distinct from (v_stays, v_nights, v_first, v_last, v_new);

  if v_new is distinct from v_old then
    insert into public.guest_profile_history (guest_id, changed_by, before_state, after_state, reason)
    values (p_guest_id, v_actor, jsonb_build_object('tier', v_old),
            jsonb_build_object('tier', v_new, 'completed_stays', v_cs, 'completed_nights', v_cn),
            coalesce(v_reason, case
              when v_new is null then 'Tier: none (fewer than 2 completed stays)'
              else 'Tier: ' || case v_new when 'vip' then 'VIP' else initcap(v_new) end
                   || ' (' || public.guest_ordinal_v1(v_cs) || ' completed stay)' end));
  end if;
end;
$$;

-- 4. staff_guest_card_v1: the live body plus the two tier keys ---------------------------------------------------------------------------------
create or replace function public.staff_guest_card_v1(p_property_id uuid, p_guest_id uuid, p_checkin date)
returns jsonb language sql stable security definer set search_path to '' as $$
  with earlier as (
    select distinct s.checkin_date, s.checkout_date, s.nights from (
      select a.checkin_date, a.checkout_date, coalesce(a.nights, a.checkout_date - a.checkin_date) nights from public.airbnb_reservations a
       where a.guest_id = p_guest_id and a.status <> 'cancelled'
      union all
      select b.checkin_date, b.checkout_date, coalesce(b.nights, b.checkout_date - b.checkin_date) nights from public.booking_inquiries b
       where b.guest_id = p_guest_id and b.status = 'confirmed') s
     where s.checkout_date <= p_checkin and s.checkin_date < p_checkin),
  last3 as (select * from earlier order by checkout_date desc limit 3)
  select jsonb_build_object(
    'repeat',        case when p_guest_id is null then null else (select count(*) from earlier) >= 1 end,
    'stay_count',    case when p_guest_id is null then null else (select count(*) from earlier) + 1 end,
    'earlier_stays', case when p_guest_id is null then null
                          else coalesce((select jsonb_agg(jsonb_build_object('month', to_char(l.checkout_date, 'YYYY-MM'), 'nights', l.nights)
                                                          order by l.checkout_date desc) from last3 l), '[]'::jsonb) end,
    'notes',         public.staff_redact_v1(nullif(btrim(concat_ws(' || ',
                        nullif(btrim(d.stay_preferences), ''),
                        case when nullif(btrim(d.vip_reason), '') is not null then 'VIP - ' || btrim(d.vip_reason) end,
                        nullif(btrim(g.notes), ''))), '')),
    'id_photo_path', case when p_guest_id is not null and public.staff_may_see_guest_id_v1(p_property_id)
                          then public.staff_primary_id_path_v1(p_guest_id) end,
    'tier',          g.tier,
    'tier_line',     case when g.tier is null then null
                          else public.guest_tier_line_v1(g.tier, (select cs.stays from public.guest_completed_stats_v1(p_guest_id) cs)) end)
  from (select 1) o
  left join public.guests g on g.id = p_guest_id and g.property_id = p_property_id
  left join public.guest_profile_details d on d.guest_id = g.id;
$$;

-- 5. admin_set_guest_tier_v1 --------------------------------------------------------------------------------------------------------------------
create or replace function public.admin_set_guest_tier_v1(p_guest_id uuid, p_tier text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := btrim(p_reason);
  v_before text; v_after text; v_manual text; v_cs integer; v_cn integer;
begin
  if not public.current_staff_active(array['owner', 'admin']) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_tier is not null and p_tier not in ('returning', 'regular', 'vip') then
    return jsonb_build_object('ok', false, 'reason', 'bad_tier');
  end if;
  if v_reason is null or char_length(v_reason) not between 3 and 200 then
    return jsonb_build_object('ok', false, 'reason', 'bad_reason');
  end if;
  select tier into v_before from public.guests where id = p_guest_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'guest_not_found');
  end if;

  update public.guests set tier_manual = p_tier where id = p_guest_id;
  perform set_config('cascade.tier_actor', auth.uid()::text, true);
  perform set_config('cascade.tier_reason', 'Manual tier: ' || coalesce(p_tier, 'cleared') || ' - ' || v_reason, true);
  perform public.refresh_guest_stats(p_guest_id);
  perform set_config('cascade.tier_actor', '', true);
  perform set_config('cascade.tier_reason', '', true);

  select tier, tier_manual into v_after, v_manual from public.guests where id = p_guest_id;
  select s.stays, s.nights into v_cs, v_cn from public.guest_completed_stats_v1(p_guest_id) s;
  -- the effective tier did not move, but the hand-set value did: keep the audit row
  if v_after is not distinct from v_before then
    insert into public.guest_profile_history (guest_id, changed_by, before_state, after_state, reason)
    values (p_guest_id, auth.uid(), jsonb_build_object('tier', v_before),
            jsonb_build_object('tier', v_after, 'completed_stays', v_cs, 'completed_nights', v_cn),
            'Manual tier: ' || coalesce(p_tier, 'cleared') || ' - ' || v_reason);
  end if;
  return jsonb_build_object('ok', true, 'tier', v_after, 'computed', public.guest_tier_v1(v_cs, v_cn), 'manual', v_manual);
end;
$$;

-- 6. nightly refresh ----------------------------------------------------------------------------------------------------------------------------
create or replace function public.refresh_all_guest_tiers_v1()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_id uuid; v_n integer := 0;
begin
  perform public.record_job_heartbeat('guest-tiers-nightly', 'started');
  begin
    for v_id in select g.id from public.guests g where g.property_id = c_prop order by g.id loop
      perform public.refresh_guest_stats(v_id);
      v_n := v_n + 1;
    end loop;
  exception when others then
    perform public.record_job_heartbeat('guest-tiers-nightly', 'failed', 'TIER_REFRESH_FAILED');
    raise;
  end;
  perform public.record_job_heartbeat('guest-tiers-nightly', 'succeeded');
  return v_n;
end;
$$;

-- record_job_heartbeat refuses an unknown job: seeded as succeeded now, expected every day, no ops risk.
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('guest-tiers-nightly', 86400, false, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - guest-tiers-nightly wiring skipped';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'guest-tiers-nightly';
  perform cron.schedule('guest-tiers-nightly', '10 16 * * *', $cmd$select public.refresh_all_guest_tiers_v1();$cmd$);
  if (select count(*) from cron.job where jobname = 'guest-tiers-nightly' and active and schedule = '10 16 * * *'
        and command like '%refresh_all_guest_tiers_v1%') <> 1 then
    raise exception 'guest-tiers-nightly not scheduled';
  end if;
end $$;

-- 7. grants -------------------------------------------------------------------------------------------------------------------------------------
-- The prod default privileges hand service_role every new function: each internal one is revoked from it explicitly (s94 lesson).
revoke all on function public.guest_tier_v1(integer, integer) from public, anon, authenticated, service_role;
revoke all on function public.guest_ordinal_v1(integer) from public, anon, authenticated, service_role;
revoke all on function public.guest_completed_stats_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.guest_tier_line_v1(text, integer) from public, anon, authenticated, service_role;
revoke all on function public.refresh_all_guest_tiers_v1() from public, anon, authenticated, service_role;
revoke all on function public.refresh_guest_stats(uuid) from public, anon, authenticated;
grant execute on function public.refresh_guest_stats(uuid) to service_role;
revoke all on function public.admin_set_guest_tier_v1(uuid, text, text) from public, anon, service_role;
grant execute on function public.admin_set_guest_tier_v1(uuid, text, text) to authenticated;

comment on function public.guest_tier_v1(integer, integer) is 'S95: the tier rule. vip 7+ stays or 20+ nights; regular 4+ or 10+; returning 2+; else NULL.';
comment on function public.refresh_all_guest_tiers_v1() is 'S95: nightly (pg_cron guest-tiers-nightly) refresh of every guest of the property; returns rows refreshed.';
comment on function public.admin_set_guest_tier_v1(uuid, text, text) is 'S95: owner/admin set (or clear with NULL) a guest''s manual tier with a reason; the effective tier is recomputed and the change is written to guest_profile_history.';

-- 8. backfill: every guest once, then the CHECK on the effective tier ---------------------------------------------------------------------------
select public.refresh_all_guest_tiers_v1();
alter table public.guests add constraint guests_tier_check check (tier in ('returning', 'regular', 'vip'));

do $$
begin
  if exists (select 1 from public.guests where tier is not null and tier not in ('returning', 'regular', 'vip')) then raise exception 'a tier outside the four values'; end if;
  if has_function_privilege('anon', 'public.refresh_guest_stats(uuid)', 'execute') or has_function_privilege('authenticated', 'public.refresh_guest_stats(uuid)', 'execute') then
    raise exception 'an API role can refresh guest stats';
  end if;
  if has_function_privilege('anon', 'public.admin_set_guest_tier_v1(uuid,text,text)', 'execute') then raise exception 'anon can set a guest tier'; end if;
  if has_function_privilege('authenticated', 'public.refresh_all_guest_tiers_v1()', 'execute')
     or has_function_privilege('service_role', 'public.refresh_all_guest_tiers_v1()', 'execute') then raise exception 'an API role can run the tier sweep'; end if;
end $$;

commit;
