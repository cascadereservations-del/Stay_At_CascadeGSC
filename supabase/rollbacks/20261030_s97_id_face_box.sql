-- Compensating rollback for release s97_id_face_box_20261030 (session 97).
-- Puts staff_photo_rotation_v1 back to the s91 body (md5 ab62dcfe266d9a252eea95b732a2cff2, columns path and rotation only), drops the id-face-locate-10m job and heartbeat,
-- id_face_todo_v1, set_id_face_box_v1, the reset trigger and its function, the CHECK and the column guest_companions.id_face_box (DATA LOSS by design: the stored face boxes;
-- the cron job refills them if the release is applied again). Nothing else changed in the release.
-- Roll the Staff app back first, or let it fall back: it falls back to the fixed crop when id_face_box is missing. Disable or undeploy id-face-locate first (its calls fail once the functions are gone).
-- Apply with run-sql-on-host.sh.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_photo_rotation_v1(text[])');
  if v_got is distinct from '08dffb41ea2d405560338896c6606b6b' then
    raise exception 's97 rollback: staff_photo_rotation_v1 is not the s97 body (md5 %): check what changed it before rolling back', v_got using errcode = '55000';
  end if;
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'id-face-locate-10m';
  end if;
end $$;
delete from public.job_heartbeats where job_name = 'id-face-locate';

drop function public.staff_photo_rotation_v1(text[]);
create function public.staff_photo_rotation_v1(p_paths text[])
returns table(path text, rotation smallint)
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
    select c.id_photo_path, max(c.id_photo_rotation)::smallint
      from public.guest_companions c
     where c.id_photo_path = any(p_paths)
       and (public.current_staff_authorized('manage_operations', c.property_id) or public.staff_can_view_guest_id_object_v1(c.id_photo_path))
     group by c.id_photo_path;
end $$;
revoke all on function public.staff_photo_rotation_v1(text[]) from public, anon;
grant execute on function public.staff_photo_rotation_v1(text[]) to authenticated, service_role;

drop trigger if exists guest_companions_reset_face_box on public.guest_companions;
drop function public.guest_companions_reset_face_box();
drop function public.set_id_face_box_v1(uuid, text, jsonb);
drop function public.id_face_todo_v1(integer);
alter table public.guest_companions drop constraint id_face_box_shape;
alter table public.guest_companions drop column id_face_box;

do $$
begin
  if md5(replace((select prosrc from pg_proc where oid = 'public.staff_photo_rotation_v1(text[])'::regprocedure), chr(13), '')) <> 'ab62dcfe266d9a252eea95b732a2cff2' then raise exception 'staff_photo_rotation_v1 not restored'; end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.guest_companions'::regclass and attname = 'id_face_box' and not attisdropped) then raise exception 'id_face_box survived the rollback'; end if;
  if to_regprocedure('public.id_face_todo_v1(integer)') is not null or to_regprocedure('public.set_id_face_box_v1(uuid,text,jsonb)') is not null
     or to_regprocedure('public.guest_companions_reset_face_box()') is not null then raise exception 'a face box function survived the rollback'; end if;
  if exists (select 1 from public.job_heartbeats where job_name = 'id-face-locate') then raise exception 'the heartbeat survived the rollback'; end if;
  if has_function_privilege('anon', 'public.staff_photo_rotation_v1(text[])', 'execute') or not has_function_privilege('authenticated', 'public.staff_photo_rotation_v1(text[])', 'execute') then
    raise exception 'staff_photo_rotation_v1 grants not restored'; end if;
end $$;

commit;
