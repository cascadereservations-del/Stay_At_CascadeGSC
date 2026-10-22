-- 20261029000000_s96_spec47.sql
-- Session 96, lane SQL: release s96_spec47_20261029 (SPEC-47 notable topics; contract: Cascade/docs/s95/CONTRACT-spec47.md; D-346).
-- Owner decision D-346 (final): guest ID photos are KEPT until staff delete them by hand. Nothing here touches guest_companions or the SPEC-40 photo pipeline.
-- (1) guest_topics: topic KEYS only a guest asked about (never message text); one row per guest, topic and source. RLS on, no grants to any API role.
-- (2) record_guest_topic_v1: upsert for the message readers (service_role only). Unknown topic, source or guest, or a null guest = silent no-op (a writer must never fail a reply).
-- (3) purge_guest_topics_v1: deletes rows whose last_seen is older than 365 days (a returning guest keeps topics for a year of silence). Closed to every API role.
-- (4) pg_cron guest-retention-nightly (20 16 * * * = 00:20 Manila) + job_heartbeats row: purge, then heartbeat succeeded (one cron command, so a failed purge records no success and the monitor reports it).
-- (5) staff_guest_card_v1: the live (s95) body plus ONE key, notable: up to 3 {topic, last_seen, source}, newest first, one per topic, [] when none. Every other key is byte for byte as before.
-- To undo apply supabase/rollbacks/20261029_s96_spec47.sql.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_guest_card_v1(uuid,uuid,date)');
  if v_got is distinct from 'e6423d7cbf16752a779f48774e765ffd' then
    raise exception 's96 spec47: staff_guest_card_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- 1. table ---------------------------------------------------------------------------------------------------------------------------------------
create table public.guest_topics (
  id bigint generated always as identity primary key,
  guest_id uuid not null references public.guests(id) on delete cascade,
  booking_id uuid null,
  topic text not null check (topic in ('directions','links','wifi','brownout','guest_count','early_checkin','late_checkout','parking','pets','id','complaint')),
  source text not null check (source in ('airbnb','messenger','staff')),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  hits integer not null default 1,
  unique (guest_id, topic, source)
);
comment on table public.guest_topics is 'S96 (SPEC-47): topic keys a guest asked about, never message text. Written only by record_guest_topic_v1, read only by staff_guest_card_v1, trimmed by purge_guest_topics_v1 (365 days since last_seen). No grants.';
alter table public.guest_topics enable row level security;
revoke all on public.guest_topics from public, anon, authenticated, service_role;

-- 2. writer --------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.record_guest_topic_v1(p_guest_id uuid, p_booking_id uuid, p_topic text, p_source text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_guest_id is null
     or p_topic is null or p_topic not in ('directions','links','wifi','brownout','guest_count','early_checkin','late_checkout','parking','pets','id','complaint')
     or p_source is null or p_source not in ('airbnb','messenger','staff') then
    return;
  end if;
  insert into public.guest_topics (guest_id, booking_id, topic, source)
  values (p_guest_id, p_booking_id, p_topic, p_source)
  on conflict (guest_id, topic, source) do update
    set last_seen = now(), hits = public.guest_topics.hits + 1, booking_id = coalesce(excluded.booking_id, public.guest_topics.booking_id);
exception when foreign_key_violation then
  return; -- unknown (or just merged-away) guest: never fail the caller's reply
end;
$$;

-- 3. retention -----------------------------------------------------------------------------------------------------------------------------------
create or replace function public.purge_guest_topics_v1()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare n integer;
begin
  delete from public.guest_topics where last_seen < now() - interval '365 days';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- 4. nightly job ---------------------------------------------------------------------------------------------------------------------------------
-- record_job_heartbeat refuses an unknown job: seeded as succeeded now, expected within 2 days, no ops risk.
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('guest-retention-nightly', 172800, false, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - guest-retention-nightly wiring skipped';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'guest-retention-nightly';
  perform cron.schedule('guest-retention-nightly', '20 16 * * *',
    $cmd$select public.purge_guest_topics_v1(); select public.record_job_heartbeat('guest-retention-nightly', 'succeeded');$cmd$);
  if (select count(*) from cron.job where jobname = 'guest-retention-nightly' and active and schedule = '20 16 * * *'
        and command like '%purge_guest_topics_v1%') <> 1 then
    raise exception 'guest-retention-nightly not scheduled';
  end if;
end $$;

-- 5. staff_guest_card_v1: the s95 body plus the notable key -------------------------------------------------------------------------------------
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
                          else public.guest_tier_line_v1(g.tier, (select count(*) from earlier)::int) end,
    'notable',       coalesce((select jsonb_agg(jsonb_build_object('topic', n.topic, 'last_seen', n.last_seen, 'source', n.source) order by n.last_seen desc, n.topic)
                                 from (select * from (select distinct on (t.topic) t.topic, t.last_seen, t.source from public.guest_topics t
                                                       where t.guest_id = g.id order by t.topic, t.last_seen desc) one
                                        order by one.last_seen desc, one.topic limit 3) n), '[]'::jsonb))
  from (select 1) o
  left join public.guests g on g.id = p_guest_id and g.property_id = p_property_id
  left join public.guest_profile_details d on d.guest_id = g.id;
$$;

-- 6. grants (restated in full, ML-21) ------------------------------------------------------------------------------------------------------------
revoke all on function public.record_guest_topic_v1(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.record_guest_topic_v1(uuid, uuid, text, text) to service_role;
revoke all on function public.purge_guest_topics_v1() from public, anon, authenticated, service_role;
-- the card: postgres and service_role only (the Staff edge function needs service_role)
revoke all on function public.staff_guest_card_v1(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.staff_guest_card_v1(uuid, uuid, date) to service_role;

comment on function public.record_guest_topic_v1(uuid, uuid, text, text) is 'S96: upsert one topic key for a guest (bumps last_seen and hits); unknown topic, source or guest is a silent no-op. service_role only.';
comment on function public.purge_guest_topics_v1() is 'S96: nightly (pg_cron guest-retention-nightly) deletes guest_topics rows with last_seen older than 365 days; returns rows deleted.';

do $$
begin
  if has_function_privilege('anon', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute') or has_function_privilege('authenticated', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute')
     or not has_function_privilege('service_role', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute') then raise exception 'record_guest_topic_v1 grants are wrong'; end if;
  if has_function_privilege('anon', 'public.purge_guest_topics_v1()', 'execute') or has_function_privilege('authenticated', 'public.purge_guest_topics_v1()', 'execute')
     or has_function_privilege('service_role', 'public.purge_guest_topics_v1()', 'execute') then raise exception 'an API role can purge topics'; end if;
  if has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') or has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') then
    raise exception 'an API role can read the staff guest card'; end if;
  if has_table_privilege('anon', 'public.guest_topics', 'select') or has_table_privilege('authenticated', 'public.guest_topics', 'select') or has_table_privilege('service_role', 'public.guest_topics', 'select') then
    raise exception 'an API role can read guest_topics'; end if;
end $$;

commit;
