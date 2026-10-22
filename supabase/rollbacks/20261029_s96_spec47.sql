-- Compensating rollback for release s96_spec47_20261029 (session 96).
-- Puts staff_guest_card_v1 back byte for byte to the s95 body (md5 e6423d7cbf16752a779f48774e765ffd, no notable key), drops the guest-retention-nightly cron job and heartbeat,
-- guest_retention_nightly_v1, purge_guest_topics_v1, record_guest_topic_v1 and the guest_topics table (DATA LOSS by design: the recorded topic keys). Nothing else changed in the release, so nothing else is undone.
-- Roll the Staff app back first if it shows the Asked about line (it hides it when notable is missing, so it is safe either way), and stop the waves writers (airbnb-email-sync,
-- messenger-concierge: their record_guest_topic_v1 calls fail quietly once the function is gone). Apply with run-sql-on-host.sh.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_guest_card_v1(uuid,uuid,date)');
  if v_got is distinct from 'c0b8c068b8fffb86e0e812b7207d96a6' then
    raise exception 's96 rollback: staff_guest_card_v1 is not the s96 body (md5 %): check what changed it before rolling back', v_got using errcode = '55000';
  end if;
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'guest-retention-nightly';
  end if;
end $$;
delete from public.job_heartbeats where job_name = 'guest-retention-nightly';
drop function public.guest_retention_nightly_v1();

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
                          else public.guest_tier_line_v1(g.tier, (select count(*) from earlier)::int) end)
  from (select 1) o
  left join public.guests g on g.id = p_guest_id and g.property_id = p_property_id
  left join public.guest_profile_details d on d.guest_id = g.id;
$$;
revoke all on function public.staff_guest_card_v1(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.staff_guest_card_v1(uuid, uuid, date) to service_role;

drop function public.purge_guest_topics_v1();
drop function public.record_guest_topic_v1(uuid, uuid, text, text);
drop table public.guest_topics;

do $$
begin
  if md5(replace((select prosrc from pg_proc where oid = 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure), chr(13), '')) <> 'e6423d7cbf16752a779f48774e765ffd' then raise exception 'staff_guest_card_v1 not restored'; end if;
  if to_regclass('public.guest_topics') is not null or to_regprocedure('public.record_guest_topic_v1(uuid,uuid,text,text)') is not null
     or to_regprocedure('public.purge_guest_topics_v1()') is not null then raise exception 'a topics object survived the rollback'; end if;
  if exists (select 1 from public.job_heartbeats where job_name = 'guest-retention-nightly') then raise exception 'the heartbeat survived the rollback'; end if;
end $$;

commit;
