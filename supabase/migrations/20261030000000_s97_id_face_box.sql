-- 20261030000000_s97_id_face_box.sql
-- Session 97, lane SQL: release s97_id_face_box_20261030 (SPEC-47b ID face box; contract: Cascade/docs/s95/CONTRACT-spec47b-face.md; D-346 unchanged: photos are kept).
-- The Today card shows the guest face large, cropped from the ID photo. Phones have no reliable face detector, so the edge function id-face-locate asks the vision reader
-- ONCE per photo for the face rectangle (four numbers, never text) and every phone uses it. Purpose is unchanged: recognising the guest at check-in.
-- (1) guest_companions.id_face_box jsonb null, CHECK id_face_box_shape: null, or exactly {x,y,w,h,src} with numbers 0<=x,y<1, 0<w,h<=1, x+w<=1.0001, y+h<=1.0001 and
--     src 'vision' or 'none' ('none' = no face found, do not retry). Coordinates are normalised 0-1 in the photo STORED (unrotated) frame. A BEFORE UPDATE OF id_photo_path
--     trigger sets it back to null when the path changes (same as id_photo_rotation, s91). No column ACLs: it follows id_photo_path privileges.
-- (2) id_face_todo_v1(p_limit): up to least(p_limit, 20) {companion_id, path}, photo present and face box null, oldest first. service_role only.
-- (3) set_id_face_box_v1(companion, path, box): writes only when the current path of the row is p_path (a photo replaced meanwhile = false); invalid box = false, never raises. service_role only.
-- (4) staff_photo_rotation_v1: the ONE function that carries id_photo_rotation to the app (the card and staff_home_v1 emit only id_photo_path / has_photo, so neither changes).
--     The live s91 body plus one returned column, id_face_box, under the same gate. A function cannot change its result columns in place: dropped and re-created, grants restated.
--     Old clients read rows by key name (path, rotation) and ignore the extra key.
-- (5) pg_cron id-face-locate-10m (*/10 * * * *): net.http_post to the id-face-locate function with the vault cron secret (same shape as release-expired-holds-hourly) + job_heartbeats row.
-- Guard: the live staff_photo_rotation_v1 must be the s91 body (md5 of prosrc, CR stripped). Everything below the guard is single shot. To undo apply supabase/rollbacks/20261030_s97_id_face_box.sql.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_photo_rotation_v1(text[])');
  if v_got = '08dffb41ea2d405560338896c6606b6b' then
    raise exception 's97 id face box: already applied (staff_photo_rotation_v1 already has the s97 body)' using errcode = '55000';
  end if;
  if v_got is distinct from 'ab62dcfe266d9a252eea95b732a2cff2' then
    raise exception 's97 id face box: staff_photo_rotation_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- 1. column, check, reset on photo change -----------------------------------------------------------------------------------------------------
alter table public.guest_companions add column id_face_box jsonb;
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

create or replace function public.guest_companions_reset_face_box()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.id_photo_path is distinct from old.id_photo_path then new.id_face_box := null; end if;
  return new;
end $$;
revoke all on function public.guest_companions_reset_face_box() from public, anon, authenticated, service_role;
drop trigger if exists guest_companions_reset_face_box on public.guest_companions;
create trigger guest_companions_reset_face_box before update of id_photo_path on public.guest_companions
  for each row execute function public.guest_companions_reset_face_box();

-- 2. what still needs a face box ---------------------------------------------------------------------------------------------------------------
create or replace function public.id_face_todo_v1(p_limit integer default 20)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('companion_id', t.id, 'path', t.id_photo_path) order by t.created_at, t.id), '[]'::jsonb)
    from (select c.id, c.id_photo_path, c.created_at from public.guest_companions c
           where c.id_photo_path is not null and c.id_face_box is null
           order by c.created_at, c.id
           limit greatest(least(coalesce(p_limit, 20), 20), 0)) t;
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

-- 4. staff_photo_rotation_v1: the live s91 body plus the id_face_box column ---------------------------------------------------------------------
drop function public.staff_photo_rotation_v1(text[]);
create function public.staff_photo_rotation_v1(p_paths text[])
returns table(path text, rotation smallint, id_face_box jsonb)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_pid uuid := coalesce((select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                         '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
begin
  if not public.current_staff_authorized('read_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_paths is null then return; end if;
  if cardinality(p_paths) > 50 then raise exception 'too_many_paths' using errcode = '22023'; end if;
  return query
    select c.id_photo_path, max(c.id_photo_rotation)::smallint, (array_agg(c.id_face_box) filter (where c.id_face_box is not null))[1]
      from public.guest_companions c
     where c.id_photo_path = any(p_paths)
       and (public.current_staff_authorized('manage_operations', c.property_id) or public.staff_can_view_guest_id_object_v1(c.id_photo_path))
     group by c.id_photo_path;
end $$;

-- 5. cron + heartbeat ---------------------------------------------------------------------------------------------------------------------------
-- record_job_heartbeat refuses an unknown job: seeded as succeeded now. The function runs every 10 minutes but a quiet day is fine: expected within 1 day, no ops risk.
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('id-face-locate', 86400, false, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - id-face-locate-10m wiring skipped';
    return;
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
revoke all on function public.staff_photo_rotation_v1(text[]) from public, anon;
grant execute on function public.staff_photo_rotation_v1(text[]) to authenticated, service_role;
revoke all on function public.guest_companions_reset_face_box() from public, anon, authenticated, service_role;

comment on function public.id_face_todo_v1(integer) is 'S97: up to 20 {companion_id, path} whose ID photo has no face box yet, oldest first. service_role only (id-face-locate).';
comment on function public.set_id_face_box_v1(uuid, text, jsonb) is 'S97: store the face box for a companion only while its photo path is still p_path; false when replaced, unknown or invalid. service_role only.';

do $$
begin
  if has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') or has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute') then raise exception 'id_face_todo_v1 grants are wrong'; end if;
  if has_function_privilege('anon', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') or has_function_privilege('authenticated', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') then raise exception 'set_id_face_box_v1 grants are wrong'; end if;
  if has_function_privilege('anon', 'public.staff_photo_rotation_v1(text[])', 'execute')
     or not has_function_privilege('authenticated', 'public.staff_photo_rotation_v1(text[])', 'execute')
     or not has_function_privilege('service_role', 'public.staff_photo_rotation_v1(text[])', 'execute') then raise exception 'staff_photo_rotation_v1 grants are wrong'; end if;
  if has_function_privilege('anon', 'public.guest_companions_reset_face_box()', 'execute') or has_function_privilege('authenticated', 'public.guest_companions_reset_face_box()', 'execute') then
    raise exception 'an API role can run the face box reset trigger function'; end if;
end $$;

commit;
