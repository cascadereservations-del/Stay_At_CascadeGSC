-- Compensating rollback for release s97_id_face_box_20261030 (session 97).
-- Puts staff_guest_card_v1 back to the s96 body (md5 c0b8c068b8fffb86e0e812b7207d96a6, no id_face_box key) and staff_photo_rotation_v1 back to the s91 body (md5 ab62dcfe266d9a252eea95b732a2cff2, columns path and rotation only), drops the id-face-locate-10m job and heartbeat,
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
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_guest_card_v1(uuid,uuid,date)');
  if v_got is distinct from 'a747282935c256cd2f6923e45f6c9aa5' then
    raise exception 's97 rollback: staff_guest_card_v1 is not the s97 body (md5 %): check what changed it before rolling back', v_got using errcode = '55000';
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

create or replace function public.staff_guest_card_v1(p_property_id uuid, p_guest_id uuid, p_checkin date)
returns jsonb language sql stable security definer set search_path to '' as $
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
                                                       where t.guest_id = g.id order by t.topic, t.last_seen desc, t.source) one
                                        order by one.last_seen desc, one.topic limit 3) n), '[]'::jsonb))
  from (select 1) o
  left join public.guests g on g.id = p_guest_id and g.property_id = p_property_id
  left join public.guest_profile_details d on d.guest_id = g.id;
$;
revoke all on function public.staff_guest_card_v1(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.staff_guest_card_v1(uuid, uuid, date) to service_role;

drop trigger if exists guest_companions_reset_face_box on public.guest_companions;
drop function public.guest_companions_reset_face_box();
drop function public.set_id_face_box_v1(uuid, text, jsonb);
drop function public.id_face_todo_v1(integer);
alter table public.guest_companions drop constraint id_face_box_shape;
alter table public.guest_companions drop column id_face_box;

do $$
begin
  if md5(replace((select prosrc from pg_proc where oid = 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure), chr(13), '')) <> 'c0b8c068b8fffb86e0e812b7207d96a6' then raise exception 'staff_guest_card_v1 not restored'; end if;
  if md5(replace((select prosrc from pg_proc where oid = 'public.staff_photo_rotation_v1(text[])'::regprocedure), chr(13), '')) <> 'ab62dcfe266d9a252eea95b732a2cff2' then raise exception 'staff_photo_rotation_v1 not restored'; end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.guest_companions'::regclass and attname = 'id_face_box' and not attisdropped) then raise exception 'id_face_box survived the rollback'; end if;
  if to_regprocedure('public.id_face_todo_v1(integer)') is not null or to_regprocedure('public.set_id_face_box_v1(uuid,text,jsonb)') is not null
     or to_regprocedure('public.guest_companions_reset_face_box()') is not null then raise exception 'a face box function survived the rollback'; end if;
  if exists (select 1 from public.job_heartbeats where job_name = 'id-face-locate') then raise exception 'the heartbeat survived the rollback'; end if;
  if has_function_privilege('anon', 'public.staff_photo_rotation_v1(text[])', 'execute') or not has_function_privilege('authenticated', 'public.staff_photo_rotation_v1(text[])', 'execute') then
    raise exception 'staff_photo_rotation_v1 grants not restored'; end if;
end $$;

commit;
