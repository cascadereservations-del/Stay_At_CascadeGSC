-- 20261031000000_s98_face_queue_today_first.sql
-- Session 98, lane SQL: release s98_face_queue_today_first_20261031. SPEC-47c (contract: Cascade/docs/s95/CONTRACT-spec47c-today-layout.md).
-- The face locator drains 20 photos per run, newest photo first. A guest who is in the house or arrives this week must not wait behind a backlog of other photos,
-- so id_face_todo_v1 now lists first the companions of guests with a stay in progress or a check-in within the next 7 days (Manila date), soonest check-in first,
-- then everything else in the existing s97 order (never tried first, newest photo first).
-- ONE function is replaced: public.id_face_todo_v1(integer). Same signature, VOLATILE, same eligibility (photo, null box, not handed out in the last hour), same cap 20,
-- same stamping of id_face_tried_at, same grants (service_role only, restated, ML-21). No table, column, trigger or other function is touched.
-- Stay rule reused (ML-10, nothing new invented): the stay source of staff_current_next_stays_v1 (calendar_events status 'confirmed', check-out after today, Manila date),
-- the guest of each stay resolved by the SAME helper staff_stay_guest_id_v1 that staff_home_v1 uses for current_guest / next_guest.
-- Guard: the live id_face_todo_v1 must be the s97 body (md5 of prosrc, CR stripped). To undo apply supabase/rollbacks/20261031_s98_face_queue_today_first.sql.
begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.id_face_todo_v1(integer)');
  if v_got is distinct from '1476750c20ccbbc6c6f3f6ca9941c4f4' then
    raise exception 's98 face queue: id_face_todo_v1 is not the s97 body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
  if to_regprocedure('public.staff_stay_guest_id_v1(uuid,text,uuid,date,date)') is null then
    raise exception 's98 face queue: staff_stay_guest_id_v1 is missing' using errcode = '55000';
  end if;
end $$;

create or replace function public.id_face_todo_v1(p_limit integer default 20)
returns jsonb
language sql volatile security definer set search_path = '' as $$
  with t as (select (now() at time zone 'Asia/Manila')::date d),
  soon as (
    -- guests with a stay in progress (check-in on or before today, check-out after today) or a check-in within the next 7 days
    select s.guest_id, min(s.checkin_date) first_in
      from (select e.checkin_date,
                   public.staff_stay_guest_id_v1(e.property_id, e.uid, e.linked_reservation_id, e.checkin_date, e.checkout_date) guest_id
              from public.calendar_events e, t
             where e.status = 'confirmed' and e.checkout_date > t.d and e.checkin_date <= t.d + 7) s
     where s.guest_id is not null
     group by s.guest_id),
  picked as (
    select c.id, c.id_photo_path, c.id_face_tried_at, c.created_at, w.first_in
      from public.guest_companions c
      left join soon w on w.guest_id = c.guest_id
     where c.id_photo_path is not null and c.id_face_box is null
       and (c.id_face_tried_at is null or c.id_face_tried_at < now() - interval '1 hour')
     order by (w.first_in is null), w.first_in, c.id_face_tried_at nulls first, c.created_at desc, c.id
     limit greatest(least(coalesce(p_limit, 20), 20), 0)
       for update of c skip locked),
  stamped as (
    update public.guest_companions u set id_face_tried_at = now() from picked p where u.id = p.id returning u.id)
  select coalesce(jsonb_agg(jsonb_build_object('companion_id', p.id, 'path', p.id_photo_path)
                            order by (p.first_in is null), p.first_in, p.id_face_tried_at nulls first, p.created_at desc, p.id), '[]'::jsonb)
    from picked p;
$$;

-- grants (restated in full, ML-21)
revoke all on function public.id_face_todo_v1(integer) from public, anon, authenticated;
grant execute on function public.id_face_todo_v1(integer) to service_role;

comment on function public.id_face_todo_v1(integer) is 'S98: hands out (and stamps id_face_tried_at on) up to 20 {companion_id, path} whose ID photo has no face box and was not handed out in the last hour; companions of guests in the house or arriving within 7 days (Manila date) first, soonest check-in first, then never-tried first and newest photo first. service_role only (id-face-locate).';

do $$
begin
  if has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') or has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where a.grantee = 0 and p.oid = 'public.id_face_todo_v1(integer)'::regprocedure) then
    raise exception 'id_face_todo_v1 grants are wrong';
  end if;
  if (select provolatile from pg_proc where oid = 'public.id_face_todo_v1(integer)'::regprocedure) <> 'v' then raise exception 'id_face_todo_v1 must stay VOLATILE'; end if;
end $$;

commit;
