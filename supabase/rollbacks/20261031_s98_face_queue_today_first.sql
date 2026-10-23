-- Compensating rollback for release s98_face_queue_today_first_20261031 (session 98).
-- Restores public.id_face_todo_v1(integer) to the exact s97 body (md5 1476750c20ccbbc6c6f3f6ca9941c4f4): newest photo first, no today-first ordering.
-- Nothing else changed in the release. No data is touched. Apply with run-sql-on-host.sh.

begin;

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

revoke all on function public.id_face_todo_v1(integer) from public, anon, authenticated;
grant execute on function public.id_face_todo_v1(integer) to service_role;
comment on function public.id_face_todo_v1(integer) is 'S97: hands out (and stamps id_face_tried_at on) up to 20 {companion_id, path} whose ID photo has no face box and was not handed out in the last hour; never-tried first, newest photo first. service_role only (id-face-locate).';

do $$
begin
  if md5(replace((select prosrc from pg_proc where oid = 'public.id_face_todo_v1(integer)'::regprocedure), chr(13), '')) <> '1476750c20ccbbc6c6f3f6ca9941c4f4' then raise exception 'id_face_todo_v1 is not the s97 body after the rollback'; end if;
  if has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') or has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute') then raise exception 'id_face_todo_v1 grants not restored'; end if;
end $$;

commit;
