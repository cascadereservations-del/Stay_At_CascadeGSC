-- Rollback for s116_guest_photo_name_20261115: puts staff_guest_card_v1 back to the s115 body (md5 4405ec514a941053bd25160936fc0926, CR stripped).
-- Guard: refuses (55000) unless the live body is the s116 one, so it never overwrites a later change.
begin;

do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.staff_guest_card_v1(uuid,uuid,date)')) is distinct from '8b40e8c8533f8c8960094365aba034ac' then
    raise exception 's116 rollback: public.staff_guest_card_v1(uuid,uuid,date) is not the s116 body: resolve by hand' using errcode = '55000';
  end if;
end $$;

create or replace function public.staff_guest_card_v1(p_property_id uuid, p_guest_id uuid, p_checkin date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $body$
  with earlier as (
    select distinct s.checkin_date, s.checkout_date, s.nights from (
      select a.checkin_date, a.checkout_date, coalesce(a.nights, a.checkout_date - a.checkin_date) nights from public.airbnb_reservations a
       where a.guest_id = p_guest_id and a.status <> 'cancelled'
      union all
      select b.checkin_date, b.checkout_date, coalesce(b.nights, b.checkout_date - b.checkin_date) nights from public.booking_inquiries b
       where b.guest_id = p_guest_id and b.status = 'confirmed') s
     where s.checkout_date <= p_checkin and s.checkin_date < p_checkin),
  last3 as (select * from earlier order by checkout_date desc limit 3),
  -- s115: what the cleaner reported at the turnover after each earlier stay (urgent pre-clean notes), newest 5, derived live from cleaning_sessions
  tr as (select string_agg(to_char(x.checkout_date, 'YYYY-MM-DD') || ': Turnover report: ' || x.t, ' || ' order by x.checkout_date desc) as txt
           from (select distinct on (e.checkout_date, a.t) e.checkout_date, a.t
                   from earlier e
                   join public.cleaning_sessions cs on cs.property_id = p_property_id and cs.checkout_date = e.checkout_date
                    and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay' and cs.issue_count > 0
                   cross join lateral (select public.turnover_issue_text_v1(cs.notes) as t) a
                  where a.t is not null
                  order by e.checkout_date desc, a.t limit 5) x)
  select jsonb_build_object(
    'repeat',        case when p_guest_id is null then null else (select count(*) from earlier) >= 1 end,
    'stay_count',    case when p_guest_id is null then null else (select count(*) from earlier) + 1 end,
    'earlier_stays', case when p_guest_id is null then null
                          else coalesce((select jsonb_agg(jsonb_build_object('month', to_char(l.checkout_date, 'YYYY-MM'), 'nights', l.nights)
                                                          order by l.checkout_date desc) from last3 l), '[]'::jsonb) end,
    'notes',         public.staff_redact_v1(nullif(btrim(concat_ws(' || ',
                        nullif(btrim(d.stay_preferences), ''),
                        case when nullif(btrim(d.vip_reason), '') is not null then 'VIP - ' || btrim(d.vip_reason) end,
                        nullif(btrim(g.notes), ''),
                        (select tr.txt from tr))), '')),
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
$body$
;
revoke all on function public.staff_guest_card_v1(uuid,uuid,date) from public, anon, authenticated;
grant execute on function public.staff_guest_card_v1(uuid,uuid,date) to service_role;

commit;
