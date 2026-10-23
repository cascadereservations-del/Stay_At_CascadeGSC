-- 20261030000000_s97_id_face_box.sql
-- Session 97, lane SQL: release s97_id_face_box_20261030 (SPEC-47b ID face box; contract: Cascade/docs/s95/CONTRACT-spec47b-face.md; D-346 unchanged: photos are kept).
-- The Today card shows the guest face large, cropped from the ID photo. Phones have no reliable face detector, so the edge function id-face-locate asks the vision reader
-- ONCE per photo for the face rectangle (four numbers, never text) and every phone uses it. Purpose is unchanged: recognising the guest at check-in.
-- (1) guest_companions.id_face_box jsonb null, CHECK id_face_box_shape: null, or exactly {x,y,w,h,src} with numbers 0<=x,y<1, 0<w,h<=1, x+w<=1.0001, y+h<=1.0001 and
--     src 'vision' or 'none' ('none' = no face found, do not retry). Coordinates are normalised 0-1 in the photo STORED (unrotated) frame. guest_companions.id_face_tried_at
--     timestamptz null: when id_face_todo_v1 last handed the photo out. A BEFORE UPDATE OF id_photo_path trigger sets BOTH back to null when the path changes (same as
--     id_photo_rotation, s91). No column ACLs: they follow id_photo_path privileges.
-- (2) id_face_todo_v1(p_limit): VOLATILE. Up to least(p_limit, 20) {companion_id, path}: photo present, face box null, and not handed out in the last hour; never-tried first,
--     then newest photo first (Today guests are recent), and it stamps id_face_tried_at on the rows it returns so a photo that keeps failing cannot starve the queue. service_role only.
-- (3) set_id_face_box_v1(companion, path, box): writes only when the current path of the row is p_path (a photo replaced meanwhile = false); invalid box = false, never raises. service_role only.
-- (4) staff_guest_card_v1: the live s96 body plus ONE key, id_face_box, beside id_photo_path under the same gate (the box of the companion whose photo is the primary path).
--     staff_home_v1 merges the card with ||, so current_guest / next_guest carry it; staff_home_v1 itself is unchanged. staff_photo_rotation_v1 is NOT touched (the app reads the box from the card).
-- (5) pg_cron id-face-locate-10m (*/10 * * * *): net.http_post to the id-face-locate function with the vault cron secret (same shape and guard as 20261007150000) + job_heartbeats row.
-- Guard: the live staff_guest_card_v1 must be the s96 body (md5 of prosrc, CR stripped). Everything below the guard is single shot. To undo apply supabase/rollbacks/20261030_s97_id_face_box.sql.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_guest_card_v1(uuid,uuid,date)');
  if v_got = '2132ec407c3c1459a777c9c87ef2d8cc' then
    raise exception 's97 id face box: already applied (staff_guest_card_v1 already has the s97 body)' using errcode = '55000';
  end if;
  if v_got is distinct from 'c0b8c068b8fffb86e0e812b7207d96a6' then
    raise exception 's97 id face box: staff_guest_card_v1 is not the s96 body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- 1. columns, check, reset on photo change ----------------------------------------------------------------------------------------------------
alter table public.guest_companions add column id_face_box jsonb;
alter table public.guest_companions add column id_face_tried_at timestamptz;
alter table public.guest_companions add constraint id_face_box_shape check (
  id_face_box is null or (
    jsonb_typeof(id_face_box) = 'object'
    and id_face_box ?& array['x', 'y', 'w', 'h', 'src']
    and id_face_box - 'x' - 'y' - 'w' - 'h' - 'src' = '{}'::jsonb
    and jsonb_typeof(id_face_box -> 'x') = 'number' and jsonb_typeof(id_face_box -> 'y') = 'number'
    and jsonb_typeof(id_face_box -> 'w') = 'number' and jsonb_typeof(id_face_box -> 'h') = 'number'
    and jsonb_typeof(id_face_box -> 'src') = 'string' and (id_face_box ->> 'src') in ('vision', 'none')
    and case when jsonb_typeof(id_face_box -> 'x') = 'number' and jsonb_typeof(id_face_box -> 'y') = 'number'
              and jsonb_typeof(id_face_box -> 'w') = 'number' and jsonb_typeof(id_face_box -> 'h') = 'number'
             then (id_face_box ->> 'x')::numeric >= 0 and (id_face_box ->> 'x')::numeric < 1
              and (id_face_box ->> 'y')::numeric >= 0 and (id_face_box ->> 'y')::numeric < 1
              and (id_face_box ->> 'w')::numeric > 0 and (id_face_box ->> 'w')::numeric <= 1
              and (id_face_box ->> 'h')::numeric > 0 and (id_face_box ->> 'h')::numeric <= 1
              and (id_face_box ->> 'x')::numeric + (id_face_box ->> 'w')::numeric <= 1.0001
              and (id_face_box ->> 'y')::numeric + (id_face_box ->> 'h')::numeric <= 1.0001
             else false end));
comment on column public.guest_companions.id_face_box is 'S97: face rectangle {x,y,w,h,src} normalised 0-1 in the stored (unrotated) photo frame, found once by id-face-locate; src none = no face found (not retried); null = not looked at yet. Reset to null when id_photo_path changes.';
comment on column public.guest_companions.id_face_tried_at is 'S97: when id_face_todo_v1 last handed this photo to id-face-locate (a photo is not handed out again within an hour). Reset to null when id_photo_path changes.';

create or replace function public.guest_companions_reset_face_box()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.id_photo_path is distinct from old.id_photo_path then new.id_face_box := null; new.id_face_tried_at := null; end if;
  return new;
end $$;
revoke all on function public.guest_companions_reset_face_box() from public, anon, authenticated, service_role;
drop trigger if exists guest_companions_reset_face_box on public.guest_companions;
create trigger guest_companions_reset_face_box before update of id_photo_path on public.guest_companions
  for each row execute function public.guest_companions_reset_face_box();

-- 2. what still needs a face box (hands out and stamps) -----------------------------------------------------------------------------------------
create or replace function public.id_face_todo_v1(p_limit integer default 20)
returns jsonb
language sql volatile security definer set search_path = '' as $$
  with picked as (
    select c.id, c.id_photo_path, c.id_face_tried_at, c.created_at
      from public.guest_companions c
     where c.id_photo_path is not null and c.id_face_box is null
       and (c.id_face_tried_at is null or c.id_face_tried_at < now() - interval '1 hour')
     order by c.id_face_tried_at nulls first, c.created_at desc, c.id
     limit greatest(least(coalesce(p_limit, 20), 20), 0)
       for update skip locked),
  stamped as (
    update public.guest_companions u set id_face_tried_at = now() from picked p where u.id = p.id returning u.id)
  select coalesce(jsonb_agg(jsonb_build_object('companion_id', p.id, 'path', p.id_photo_path)
                            order by p.id_face_tried_at nulls first, p.created_at desc, p.id), '[]'::jsonb)
    from picked p;
$$;

-- 3. store one face box -------------------------------------------------------------------------------------------------------------------------
create or replace function public.set_id_face_box_v1(p_companion_id uuid, p_path text, p_box jsonb)
returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare v_n integer;
begin
  if p_companion_id is null or p_path is null or p_box is null then return false; end if;
  begin
    update public.guest_companions c set id_face_box = p_box
     where c.id = p_companion_id and c.id_photo_path = p_path;
    get diagnostics v_n = row_count;
  exception when check_violation then
    return false;   -- the table CHECK is the single definition of a valid box
  end;
  return v_n = 1;
end $$;

-- 4. staff_guest_card_v1: the s96 body plus the id_face_box key beside id_photo_path -----------------------------------------------------------
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
    'id_face_box',   case when p_guest_id is not null and public.staff_may_see_guest_id_v1(p_property_id)
                          then (select c.id_face_box from public.guest_companions c
                                 where c.guest_id = p_guest_id and c.id_photo_path = public.staff_primary_id_path_v1(p_guest_id) limit 1) end,
    'tier',          g.tier,
    'tier_line',     case when g.tier is null then null
                          else public.guest_tier_line_v1(g.tier, (select count(*) from earlier)::int) end,
    'notable',       coalesce((select jsonb_agg(jsonb_build_object('topic', n.topic, 'last_seen', n.last_seen, 'source', n.source) order by n.last_seen desc, n.topic)
                                 from (select * from (select distinct on (t.topic) t.topic, t.last_seen, t.source from public.guest_topics t
                                                       where t.guest_id = g.id order by t.topic, t.last_seen desc, t.source) one
                                        order by one.last_seen desc, one.topic limit 3) n), '[]'::jsonb))
  from (select 1) o
  left join public.guests g on g.id = p_guest_id and g.property_id = p_property_id
  left join public.guest_profile_details d on d.guest_id = g.id;
$$;

-- 5. cron + heartbeat ---------------------------------------------------------------------------------------------------------------------------
-- record_job_heartbeat refuses an unknown job: seeded as succeeded now. The function runs every 10 minutes but a quiet day is fine: expected within 1 day, no ops risk.
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('id-face-locate', 86400, false, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

-- guard and call shape copied from 20261007150000_cron_secret_three_jobs.sql: skipped where pg_cron, pg_net or the vault is absent (a rehearsal copy); stops when the secret is missing.
do $$
begin
  if to_regclass('cron.job') is null or to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then
    raise notice 'pg_cron, pg_net or vault absent (rehearsal copy) - id-face-locate-10m wiring skipped';
    return;
  end if;
  if coalesce((select length(decrypted_secret) from vault.decrypted_secrets where name = 'cascade_cron_shared_secret'), 0) < 1 then
    raise exception 'vault secret cascade_cron_shared_secret is missing or too short - the job would send an empty header';
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'id-face-locate-10m';
  perform cron.schedule('id-face-locate-10m', '*/10 * * * *', $cmd$
    select net.http_post(
      url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/id-face-locate',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj',
        'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
      ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 300000
    ) as request_id;
  $cmd$);
  if (select count(*) from cron.job where jobname = 'id-face-locate-10m' and active and schedule = '*/10 * * * *'
        and command like '%id-face-locate%' and command like '%x-cascade-cron-secret%' and command like '%cascade_cron_shared_secret%') <> 1 then
    raise exception 'id-face-locate-10m not scheduled';
  end if;
end $$;

-- 6. grants (restated in full, ML-21) ------------------------------------------------------------------------------------------------------------
revoke all on function public.id_face_todo_v1(integer) from public, anon, authenticated;
grant execute on function public.id_face_todo_v1(integer) to service_role;
revoke all on function public.set_id_face_box_v1(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.set_id_face_box_v1(uuid, text, jsonb) to service_role;
revoke all on function public.staff_guest_card_v1(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.staff_guest_card_v1(uuid, uuid, date) to service_role;
revoke all on function public.guest_companions_reset_face_box() from public, anon, authenticated, service_role;

comment on function public.id_face_todo_v1(integer) is 'S97: hands out (and stamps id_face_tried_at on) up to 20 {companion_id, path} whose ID photo has no face box and was not handed out in the last hour; never-tried first, newest photo first. service_role only (id-face-locate).';
comment on function public.set_id_face_box_v1(uuid, text, jsonb) is 'S97: store the face box for a companion only while its photo path is still p_path; false when replaced, unknown or invalid. service_role only.';

do $$
begin
  if has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') or has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute') then raise exception 'id_face_todo_v1 grants are wrong'; end if;
  if has_function_privilege('anon', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') or has_function_privilege('authenticated', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') then raise exception 'set_id_face_box_v1 grants are wrong'; end if;
  if has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') or has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute')
     or not has_function_privilege('service_role', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') then raise exception 'staff_guest_card_v1 grants are wrong'; end if;
  if has_function_privilege('anon', 'public.guest_companions_reset_face_box()', 'execute') or has_function_privilege('authenticated', 'public.guest_companions_reset_face_box()', 'execute') then
    raise exception 'an API role can run the face box reset trigger function'; end if;
end $$;

commit;
