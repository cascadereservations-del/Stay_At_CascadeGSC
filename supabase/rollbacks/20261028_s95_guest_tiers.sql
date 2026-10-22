-- Compensating rollback for release s95_guest_tiers_20261028 (session 95).
-- Puts refresh_guest_stats (live md5 4c2739962ed0dbd0bc240756df488e93, SECURITY INVOKER, executable by anon/authenticated/service_role as before) and staff_guest_card_v1
-- (md5 9fae8f114017a3a98f0bd02541a7e0af) back byte for byte, drops the tier CHECKs, re-runs the OLD refresh for every guest (tiers return to the old two-value rule), then drops
-- admin_set_guest_tier_v1, the internal overload refresh_guest_stats(uuid, uuid, text), refresh_all_guest_tiers_v1, guest_tier_line_v1, guest_completed_stats_v1, guest_ordinal_v1, guest_tier_v1, the guest-tiers-nightly cron job and
-- heartbeat, and the columns tier_manual and tier_changed_at (DATA LOSS by design: hand-set tiers). guest_profile_history rows written by the release stay (history).
-- Roll the Staff app and the admin dashboard back first (they read tier_line and call admin_set_guest_tier_v1). Apply with run-sql-on-host.sh.

begin;

do $$
declare v_got text; r record;
begin
  for r in select * from (values
      ('public.refresh_guest_stats(uuid)', 'a6f1ed47dd79d245034104b67918510b'),
      ('public.staff_guest_card_v1(uuid,uuid,date)', 'e6423d7cbf16752a779f48774e765ffd')) v(sig, md) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v_got is distinct from r.md then
      raise exception 's95 rollback: % is not the s95 body (md5 %): check what changed it before rolling back', r.sig, v_got using errcode = '55000';
    end if;
  end loop;
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'guest-tiers-nightly';
  end if;
end $$;
delete from public.job_heartbeats where job_name = 'guest-tiers-nightly';

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
                          then public.staff_primary_id_path_v1(p_guest_id) end)
  from (select 1) o
  left join public.guests g on g.id = p_guest_id and g.property_id = p_property_id
  left join public.guest_profile_details d on d.guest_id = g.id;
$$;

create or replace function public.refresh_guest_stats(p_guest_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
DECLARE
  v_stays  INTEGER;
  v_nights INTEGER;
  v_first  DATE;
  v_last   DATE;
  v_tier   TEXT;
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE status IN ('completed','confirmed')),
    COALESCE(SUM(nights) FILTER (WHERE status = 'completed'), 0),
    MIN(checkin_date) FILTER (WHERE status IN ('completed','confirmed')),
    MAX(checkin_date) FILTER (WHERE status IN ('completed','confirmed'))
  INTO v_stays, v_nights, v_first, v_last
  FROM public.airbnb_reservations
  WHERE guest_id = p_guest_id;

  v_tier := CASE
    WHEN v_stays >= 4 OR v_nights >= 10 THEN 'vip'
    WHEN v_stays >= 2 THEN 'returning'
    ELSE NULL
  END;

  UPDATE public.guests SET
    total_stays = v_stays,
    total_nights_stayed = v_nights,
    first_stay_date = v_first,
    last_stay_date = v_last,
    tier = v_tier,
    updated_at = now()
  WHERE id = p_guest_id;
END;
$$;
grant execute on function public.refresh_guest_stats(uuid) to public, anon, authenticated, service_role;
drop function public.refresh_guest_stats(uuid, uuid, text);

drop function public.admin_set_guest_tier_v1(uuid, text, text);
drop function public.refresh_all_guest_tiers_v1();
alter table public.guests drop constraint guests_tier_check;
alter table public.guests drop constraint guests_tier_manual_check;
select public.refresh_guest_stats(g.id) from public.guests g;
drop function public.guest_tier_line_v1(text, integer);
drop function public.guest_completed_stats_v1(uuid);
drop function public.guest_ordinal_v1(integer);
drop function public.guest_tier_v1(integer, integer);
alter table public.guests drop column tier_manual;
alter table public.guests drop column tier_changed_at;
comment on column public.guests.tier is null;

do $$
begin
  if md5(replace((select prosrc from pg_proc where oid = 'public.refresh_guest_stats(uuid)'::regprocedure), chr(13), '')) <> '4c2739962ed0dbd0bc240756df488e93' then raise exception 'refresh_guest_stats not restored'; end if;
  if md5(replace((select prosrc from pg_proc where oid = 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure), chr(13), '')) <> '9fae8f114017a3a98f0bd02541a7e0af' then raise exception 'staff_guest_card_v1 not restored'; end if;
  if to_regprocedure('public.refresh_guest_stats(uuid,uuid,text)') is not null then raise exception 'the internal refresh overload survived'; end if;
  if (select prosecdef from pg_proc where oid = 'public.refresh_guest_stats(uuid)'::regprocedure) then raise exception 'refresh_guest_stats is still SECURITY DEFINER'; end if;
  if exists (select 1 from public.guests where tier = 'regular') then raise exception 'a regular tier survived the rollback'; end if;
end $$;

commit;
