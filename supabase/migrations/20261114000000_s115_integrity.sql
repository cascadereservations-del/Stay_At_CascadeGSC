-- 20261114000000_s115_integrity.sql
-- Session 115, lane S (SQL): release s115_integrity_20261114. docs/s115/PLAN.md sections 2, 4, 5.
-- 1. get_missed_cleanings counts only a CONFIRMED calendar row (was: anything not cancelled). A blocked row (maintenance, "not available", a cancelled guest's name kept by
--    calendar-sync) is not a stay, so it is no longer a "missed cleaning", a payable advance (staff_pay_candidates_v1 / staff_pay_request_create_v2 / staff_pay_admin_create_v2),
--    a readiness warning or an OPS alert. Everything else in the body is unchanged.
-- 2. turnover_issue_text_v1 (new, internal): the Pre-Clean Condition segment of a cleaning report as one plain line. staff_guest_card_v1 appends it to the guest's notes as
--    "YYYY-MM-DD: Turnover report: <text>" for each earlier stay whose turnover had issue_count > 0 (newest 5, derived live, nothing stored, staff_redact_v1 still applies);
--    get_guest_timeline_v1 gets a "turnover_report" event.
-- 3. run_system_verifier_v1: V20 (advance_no_stay, paid_no_link, stuck_paying, session_twice, report_no_stay), V21 (block_named, confirmed_cancelled), V22 (credit_gone).
--    apply_verifier_run_v1: V20/V22 in both scope arrays, V21 daily; an acknowledged RED finding still seen re-opens after 3 days.
-- 4. meter_chain_v1 (new, internal): the ONE eligible-reading chain (prev > 0, deltas >= 0, flag null / typed_accepted / estimated; order electric_prev, checkout day, recorded_at, id) that
--    kpi_tab_v1 counts and run_system_verifier_v1 V23 raises, so V23 reports exactly the readings the KPI leaves out. V23 detail = cards.ts v23Facts (reading, prev, expected_prev, checkout, reading_id).
-- Guards (55000, nothing changes): each live body must be the one this release was cut from (md5 of prosrc with CR stripped).
-- Grants restated for every function (ML-21). Rollback: supabase/rollbacks/20261114_s115_integrity.sql. Data step (Lloyd's block, after the release): supabase/sql/2026-11-11-s115-honey-6ff96a06.sql.

begin;

do $$
declare r record;
begin
  for r in select * from (values
    ('public.get_missed_cleanings(uuid,integer)', 'def6d3ea1ae7c3c05bc2ae178df2d0aa'),
    ('public.staff_guest_card_v1(uuid,uuid,date)', '2132ec407c3c1459a777c9c87ef2d8cc'),
    ('public.get_guest_timeline_v1(uuid)', '288c9ca25f6c2a08ffe5d6d3fcbc5c5e'),
    ('public.run_system_verifier_v1(uuid,text,timestamp with time zone)', '96f5e975a7d25b32b60487f9f1174c1b'),
    ('public.apply_verifier_run_v1(text,jsonb,timestamp with time zone)', '8cf41764607206c41eba31d32211221a'),
    ('public.kpi_tab_v1(uuid,date)', '645094c8360051a3d304c7f9134bd8a6')
  ) as v(sig, expect)
  loop
    if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure(r.sig)) is distinct from r.expect then
      raise exception 's115: % is not the body this release was cut from (md5 %): re-cut it from the live body', r.sig,
        (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure(r.sig)) using errcode = '55000';
    end if;
  end loop;
end $$;

create or replace function public.turnover_issue_text_v1(p_notes text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $body$
  -- s115: the Pre-Clean Condition segment of a cleaning report, as one plain line: stops at the next [Section] header, drops the [URGENT] tag and a trailing backfill remark; any other run of pipes (the notes separator) becomes ' / '.
  select nullif(left(btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           substring(p_notes from '\[Pre-Clean Condition\]:[[:space:]]*(.*)'),
           '\n[[:space:]]*\[[A-Za-z].*$', ''),
           '[[:space:]]*\|[[:space:]]*Backfill.*$', ''),
           '\[URGENT\][[:space:]]*', '', 'g'),
           '[[:space:]]*\|+[[:space:]]*', ' / ', 'g'),
           '[[:space:]]+', ' ', 'g')), 300), '');
$body$
;
revoke all on function public.turnover_issue_text_v1(text) from public, anon, authenticated, service_role;

create or replace function public.meter_chain_v1(p_property_id uuid)
 RETURNS TABLE(id uuid, recorded_at timestamp with time zone, checkout_date date, cd date, electric_prev numeric, electric_curr numeric, electric_delta numeric, water_delta numeric,
               meter_flag text, pc numeric, pcd date, chain_ok boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $body$
  -- s115 (Opus ML-10): the ONE meter chain, shared by kpi_tab_v1 (counts chain_ok rows) and run_system_verifier_v1 V23 (raises the rows that are not chain_ok), so V23 reports exactly the readings the KPI leaves out.
  -- Eligible readings = the s111 filters: both prev > 0, both deltas >= 0, flag null / typed_accepted / estimated (a flagged misread is neither counted nor raised).
  -- Order: electric_prev, checkout day, recorded_at, id. cd = the checkout day of the reading's cleaning session, the recorded Manila day only when it has none.
  -- pc / pcd = the previous eligible reading's end value / cd. chain_ok = first reading, or electric_prev = pc (otherwise an overlap or a gap).
  with r0 as (
    select mr.id, mr.recorded_at, mr.electric_prev, coalesce(mr.electric_curr, mr.electric_prev + mr.electric_delta) electric_curr, mr.electric_delta, mr.water_delta, mr.meter_flag, cs.checkout_date,
           coalesce(cs.checkout_date, (mr.recorded_at at time zone 'Asia/Manila')::date) cd
      from public.meter_readings mr left join public.cleaning_sessions cs on cs.id = mr.session_id
     where mr.property_id = p_property_id
       and mr.electric_prev > 0 and mr.water_prev > 0 and mr.electric_delta >= 0 and mr.water_delta >= 0
       and (mr.meter_flag is null or mr.meter_flag in ('typed_accepted', 'estimated'))
  ), e as (
    select r0.*, lag(r0.electric_curr) over w pc, lag(r0.cd) over w pcd
      from r0 window w as (order by r0.electric_prev, r0.cd, r0.recorded_at, r0.id)
  )
  select e.id, e.recorded_at, e.checkout_date, e.cd, e.electric_prev, e.electric_curr, e.electric_delta, e.water_delta, e.meter_flag, e.pc, e.pcd, (e.pc is null or e.electric_prev = e.pc)
    from e;
$body$
;
revoke all on function public.meter_chain_v1(uuid) from public, anon, authenticated, service_role;

create or replace function public.get_missed_cleanings(p_property_id uuid DEFAULT NULL::uuid, p_lookback integer DEFAULT 14)
 RETURNS TABLE(guest_name text, checkin_date date, checkout_date date, source text, days_overdue integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $body$
declare
  v_prop_id uuid;
  v_today   date;
begin
  -- s91 F6: "today" is the Manila date. current_date is UTC, one day short from 00:00 to 08:00 Manila when this is called interactively.
  v_today   := public.manila_today();
  v_prop_id := coalesce(p_property_id, (select id from public.properties limit 1));

  return query
  select
    nullif(trim(coalesce(ce.guest_name, '')), '') as guest_name,
    ce.checkin_date,
    ce.checkout_date,
    ce.source,
    (v_today - ce.checkout_date)::integer as days_overdue
  from public.calendar_events ce
  where ce.property_id = v_prop_id
    -- s115: only a confirmed row is a stay that needs a clean. A blocked row (maintenance, not available, a cancelled guest's name kept by calendar-sync) is not.
    and ce.status = 'confirmed'
    and ce.checkout_date <  v_today
    and ce.checkout_date >= v_today - p_lookback
    and not exists (
      select 1
      from public.cleaning_sessions cs
      where cs.property_id = v_prop_id
        and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
        and (
          cs.checkout_date = ce.checkout_date
          -- s99e: only a report with NO checkout date falls back to the window (filed the same or next Manila day); a report that names another
          -- checkout (a late one) no longer hides this one. Same rule as s_advance_session_v1.
          or (cs.checkout_date is null and (cs.cleaned_at at time zone 'Asia/Manila')::date between ce.checkout_date and ce.checkout_date + 1)
        )
    )
    -- D-290: the same guest checks in again on this checkout date, so nobody cleans
    and not exists (
      select 1
      from public.calendar_events nx
      where ce.status = 'confirmed'
        and nx.property_id = ce.property_id
        and nx.status = 'confirmed'
        and nx.checkin_date = ce.checkout_date
        and nx.id <> ce.id
        and public.stay_same_guest_v1(ce.id, nx.id)
    )
  order by ce.checkout_date desc;
end;
$body$
;
revoke all on function public.get_missed_cleanings(uuid,integer) from public, anon;
grant execute on function public.get_missed_cleanings(uuid,integer) to authenticated, service_role;

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

create or replace function public.get_guest_timeline_v1(p_guest_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $body$
declare v_prop uuid; v_fin boolean; v_events jsonb;
begin
  select property_id into v_prop from public.guests where id = p_guest_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'guest not found'; end if;
  perform public.admin_require('manage_operations', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  with ev as (
    select 'stay' kind, s.checkin::timestamptz at, jsonb_build_object('code', s.code, 'stayKind', s.stay_kind, 'id', s.stay_id, 'checkin', s.checkin, 'checkout', s.checkout, 'nights', s.nights, 'status', s.status, 'accommodationTotal', case when v_fin then s.accommodation_total end) body, s.stay_kind source
    from public.admin_stays_v1(v_prop) s where s.guest_id = p_guest_id
    union all
    select 'follow_up', coalesce(f.completed_at, f.created_at), jsonb_build_object('id', f.id, 'title', f.title, 'purpose', f.purpose, 'status', f.status, 'dueAt', f.due_at, 'completionNote', f.completion_note), 'follow_up_tasks'
    from public.follow_up_tasks f where f.guest_id = p_guest_id
    union all
    select 'conversation', c.updated_at, jsonb_build_object('id', c.id, 'channel', c.channel, 'purpose', c.purpose, 'status', c.status, 'bookingId', c.booking_id), 'guest_conversations'
    from public.guest_conversations c where c.guest_id = p_guest_id
    union all
    select 'consent', ce.effective_at, jsonb_build_object('purpose', ce.purpose, 'status', ce.status, 'reason', ce.reason), 'crm_consent_events'
    from public.crm_consent_events ce join public.crm_guest_profiles gp on gp.id = ce.profile_id where gp.guest_id = p_guest_id
    union all
    select 'lifecycle', le.occurred_at, jsonb_build_object('eventType', le.event_type, 'code', le.event_code, 'bookingId', le.booking_id, 'reason', le.reason), 'crm_lifecycle_events'
    from public.crm_lifecycle_events le join public.crm_guest_profiles gp on gp.id = le.profile_id where gp.guest_id = p_guest_id
    union all
    select 'refund', t.transaction_date::timestamptz, jsonb_build_object('id', t.id, 'amount', t.gross_amount, 'rail', t.refund_rail, 'reference', t.refund_ref, 'status', t.status), 'transactions'
    from public.transactions t where v_fin and t.source = 'refund' and t.booking_id in (select stay_id from public.admin_stays_v1(v_prop) where guest_id = p_guest_id)
    union all
    select 'profile_change', h.changed_at, jsonb_build_object('reason', h.reason, 'after', h.after_state), 'guest_profile_history'
    from public.guest_profile_history h where h.guest_id = p_guest_id
    union all
    select 'merge', m.merged_at, jsonb_build_object('mergedGuestId', m.merged_guest_id, 'reason', m.reason), 'guest_merge_history'
    from public.guest_merge_history m where m.surviving_guest_id = p_guest_id
    union all
    -- s115: the cleaner's urgent notes from the turnover after one of this guest's stays (same text the staff guest card shows)
    select 'turnover_report', cs.cleaned_at, jsonb_build_object('sessionId', cs.id, 'checkout', cs.checkout_date, 'text', public.turnover_issue_text_v1(cs.notes), 'issueCount', cs.issue_count), 'cleaning_sessions'
    from public.cleaning_sessions cs
    where cs.property_id = v_prop and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay' and cs.issue_count > 0
      and public.turnover_issue_text_v1(cs.notes) is not null
      and exists (select 1 from public.admin_stays_v1(v_prop) s where s.guest_id = p_guest_id and s.checkout = cs.checkout_date and s.status is distinct from 'cancelled')
      and not exists (select 1 from public.cleaning_sessions c2
                       where c2.property_id = cs.property_id and c2.checkout_date = cs.checkout_date and coalesce(c2.cleaning_type, 'checkout') <> 'mid_stay' and c2.issue_count > 0
                         and public.turnover_issue_text_v1(c2.notes) = public.turnover_issue_text_v1(cs.notes) and (c2.cleaned_at, c2.id) < (cs.cleaned_at, cs.id))
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'at', at, 'source', source, 'body', body) order by at desc), '[]'::jsonb) into v_events from ev;
  return jsonb_build_object('guestId', p_guest_id, 'financeVisible', v_fin, 'events', v_events);
end;
$body$
;
revoke all on function public.get_guest_timeline_v1(uuid) from public, anon, service_role;
grant execute on function public.get_guest_timeline_v1(uuid) to authenticated;

create or replace function public.run_system_verifier_v1(p_property_id uuid, p_scope text DEFAULT 'hourly'::text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $body$
declare
  v_found jsonb := '[]'::jsonb;
  v_daily boolean := (p_scope = 'daily');
  v_sync  timestamptz;
  v_mode  text;
  v_mode_since timestamptz;
  v_hc_ran timestamptz;
begin
  if p_scope not in ('hourly', 'daily') then
    raise exception 'scope must be hourly or daily' using errcode = '22023';
  end if;

  -- V1 - two non-cancelled stays overlap. Red: a guest is at the door.
  -- The pair is keyed by both ids in a fixed order, so the same overlap seen
  -- from either side is one finding and not two.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V1:' || least(a.id, b.id)::text || ':' || greatest(a.id, b.id)::text,
      'check_id', 'V1',
      'severity', 'red',
      'title',    'Two stays overlap',
      'detail',   jsonb_build_object(
        'a', jsonb_build_object('id', a.id, 'source', a.source, 'guest', a.guest_name, 'from', a.checkin_date, 'to', a.checkout_date, 'status', a.status),
        'b', jsonb_build_object('id', b.id, 'source', b.source, 'guest', b.guest_name, 'from', b.checkin_date, 'to', b.checkout_date, 'status', b.status))))
    from public.calendar_events a
    join public.calendar_events b
      on a.id < b.id
     and a.property_id = b.property_id
     and a.checkin_date < b.checkout_date
     and b.checkin_date < a.checkout_date
    where a.property_id = p_property_id
      and a.status <> 'cancelled' and b.status <> 'cancelled'
      and a.checkout_date > p_now::date
      -- s77 (TASKS #24): an Airbnb block that calendar-sync labelled as the mirror of THIS direct stay
      -- (block_reason 'direct', note 'DIR <first 8 of the booking id> ...') is our own block, not a second
      -- stay. coalesce: a uid that is not a direct uid never hides a pair.
      and not coalesce(
            (a.source = 'airbnb' and a.status = 'blocked' and a.block_reason = 'direct' and b.source = 'direct'
               and position(upper(left(public.stay_uid_inquiry_v1(b.uid)::text, 8)) in upper(coalesce(a.block_note, ''))) > 0)
         or (b.source = 'airbnb' and b.status = 'blocked' and b.block_reason = 'direct' and a.source = 'direct'
               and position(upper(left(public.stay_uid_inquiry_v1(a.uid)::text, 8)) in upper(coalesce(b.block_note, ''))) > 0),
          false)
  ), '[]'::jsonb);

  -- V1m - that mirror block runs past the direct stay, so nights show taken on Airbnb with no guest
  -- (Angel 2026-10-08: block Oct 8-12, stay Oct 8-11). Yellow, check_id V1 so both scopes resolve it.
  -- Dates and ids only, so an acknowledgement holds until a date moves.
  -- ponytail: one block mirroring two back-to-back direct stays would flag here; split the block, or add
  -- a not-exists over the other direct stays if that ever happens.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V1m:' || m.id::text,
      'check_id', 'V1',
      'severity', 'yellow',
      'title',    'Airbnb block runs past the direct stay',
      'detail',   jsonb_build_object(
        'block', m.id, 'stay', s.id, 'uid', s.uid, 'guest', s.guest_name,
        'stay_from', s.checkin_date, 'stay_to', s.checkout_date,
        'block_from', m.checkin_date, 'block_to', m.checkout_date)))
    from public.calendar_events m
    join public.calendar_events s
      on s.property_id = m.property_id
     and s.source = 'direct' and s.status <> 'cancelled'
     and s.checkin_date < m.checkout_date and m.checkin_date < s.checkout_date
     and position(upper(left(public.stay_uid_inquiry_v1(s.uid)::text, 8)) in upper(coalesce(m.block_note, ''))) > 0
    where m.property_id = p_property_id
      and m.source = 'airbnb' and m.status = 'blocked' and m.block_reason = 'direct'
      and m.checkout_date > p_now::date
      and (m.checkin_date < s.checkin_date - greatest(coalesce((select case when jsonb_typeof(a.value) = 'number' then floor((a.value #>> '{}')::numeric)::integer end
                         from public.app_settings a where a.key = 'airbnb_prep_nights'), 1), 0)
           or m.checkout_date > s.checkout_date + greatest(coalesce((select case when jsonb_typeof(a.value) = 'number' then floor((a.value #>> '{}')::numeric)::integer end
                         from public.app_settings a where a.key = 'airbnb_prep_nights'), 1), 0))
  ), '[]'::jsonb);

  -- V2 - a confirmed direct booking with no live calendar row. Red: the nights
  -- are still sellable to somebody else.
  -- s77: the uid is direct:<id> while a hold and cascade-direct-<id> once confirmed (inquiry_one_tap renames
  -- it); stay_uid_inquiry_v1 reads both. Matching only direct: raised V2 and V3 on Angel's confirmed stay.
  -- calendar_events carries no booking id column; the link is the uid, written
  -- as direct:<booking id> by submit-booking and read exactly that way by
  -- expire_booking_holds_v1. That is an exact join, not the date match the
  -- design fell back to.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V2:' || b.id::text,
      'check_id', 'V2',
      'severity', 'red',
      'title',    'Confirmed booking with no calendar block',
      'detail',   jsonb_build_object('booking', b.id, 'guest', b.guest_name, 'from', b.checkin_date, 'to', b.checkout_date)))
    from public.booking_inquiries b
    where b.property_id = p_property_id
      and b.status = 'confirmed'
      and b.checkout_date > p_now::date
      and not exists (
        select 1 from public.calendar_events c
        where public.stay_uid_inquiry_v1(c.uid) = b.id and c.status <> 'cancelled')
  ), '[]'::jsonb);

  -- V3 - a direct hold with nothing live behind it, hiding sellable nights.
  -- detail.auto_safe says whether an existing, tested function would already
  -- have cancelled this row: it would, when the inquiry itself is expired or
  -- cancelled, because that is exactly what expire_booking_holds_v1 does. A
  -- hold with NO inquiry at all may be a date somebody blocked by hand, so it
  -- waits for a person.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V3:' || c.id::text,
      'check_id', 'V3',
      'severity', 'yellow',
      'title',    'Calendar hold with no live booking behind it',
      'detail',   jsonb_build_object(
        'event', c.id, 'uid', c.uid, 'guest', c.guest_name, 'from', c.checkin_date, 'to', c.checkout_date,
        'inquiry_status', (select b.status from public.booking_inquiries b where b.id = public.stay_uid_inquiry_v1(c.uid)),
        'auto_safe', (c.status = 'blocked' and exists (
           select 1 from public.booking_inquiries b
           where b.id = public.stay_uid_inquiry_v1(c.uid) and b.status in ('expired', 'cancelled'))))))
    from public.calendar_events c
    where c.property_id = p_property_id
      and c.source = 'direct'
      and c.status <> 'cancelled'
      and c.checkout_date > p_now::date
      and not exists (
        select 1 from public.booking_inquiries b
        where b.id = public.stay_uid_inquiry_v1(c.uid) and b.status in ('pending', 'confirmed'))
  ), '[]'::jsonb);

  -- V4 - a Concierge booking flow stuck at the money step for over 6 hours.
  -- concierge_threads is not property-scoped; there is one property.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V4:' || t.psid,
      'check_id', 'V4',
      'severity', 'yellow',
      'title',    'Messenger booking stuck at the payment step',
      'detail',   jsonb_build_object(
        'psid', t.psid, 'guest', t.guest_name, 'step', t.booking_flow->>'step',
        'since', t.booking_flow->>'updated_at',
        'email', t.booking_flow->>'email',
        'from',  t.booking_flow->>'checkin',
        'to',    t.booking_flow->>'checkout')))
    from public.concierge_threads t
    where t.booking_flow->>'step' in ('await_receipt', 'receipt_sent')
      and (t.booking_flow->>'updated_at')::timestamptz < p_now - interval '6 hours'
  ), '[]'::jsonb);

  -- V5 - a guest question nobody has answered in 12 hours.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V5:' || h.id::text,
      'check_id', 'V5',
      'severity', 'yellow',
      'title',    'Guest handoff open over 12 hours',
      'detail',   jsonb_build_object('id', h.id, 'guest', h.guest_name, 'risk', h.risk, 'since', h.created_at, 'asked', left(coalesce(h.guest_text, ''), 200))))
    from public.concierge_handoffs h
    where h.status = 'open' and h.created_at < p_now - interval '12 hours'
  ), '[]'::jsonb);

  -- V7 - a calendar row and the reservation it is linked to disagree on dates (D-225, D-235).
  -- The Airbnb calendar is the primary record. When both rows are confirmed (auto_safe),
  -- apply_verifier_run_v1 corrects the reservation's dates from the calendar and closes this.
  -- Detail carries dates and ids only, so an acknowledgement holds until a date changes (D-217.2).
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V7:' || ar.confirmation_code,
      'check_id', 'V7',
      'severity', 'yellow',
      'title',    'Calendar and reservation disagree on dates',
      'detail',   jsonb_build_object(
        'code', ar.confirmation_code, 'guest', ar.guest_name, 'reservation', ar.id,
        'email_from', ar.checkin_date, 'email_to', ar.checkout_date,
        'calendar_from', ce.checkin_date, 'calendar_to', ce.checkout_date,
        'event', ce.id,
        'auto_safe', (ar.status = 'confirmed' and ce.status = 'confirmed'))))
    from public.calendar_events ce
    join public.airbnb_reservations ar on ar.id = ce.linked_reservation_id
    where ce.property_id = p_property_id
      and ce.source = 'airbnb' and ce.status <> 'cancelled'
      and ar.status <> 'cancelled'
      and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 1
      and (ce.checkin_date is distinct from ar.checkin_date or ce.checkout_date is distinct from ar.checkout_date)
  ), '[]'::jsonb);

  -- V7b - an Airbnb stay on the calendar with no booking e-mail behind it after 24 hours (D-235.2).
  -- The feed carries the confirmation code, so the link is exact; no link means the corroborating
  -- e-mail never arrived or was never parsed. It closes itself when calendar-sync makes the link.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V7b:' || ce.uid,
      'check_id', 'V7b',
      'severity', 'yellow',
      'title',    'Airbnb stay with no booking e-mail',
      'detail',   jsonb_build_object(
        'uid', ce.uid, 'code', substring(ce.raw_description from 'reservations/details/([A-Z0-9]{10})'),
        'from', ce.checkin_date, 'to', ce.checkout_date, 'since', ce.created_at)))
    from public.calendar_events ce
    where ce.property_id = p_property_id
      and ce.source = 'airbnb' and ce.status = 'confirmed'
      and ce.linked_reservation_id is null
      and ce.raw_description ~ 'reservations/details/[A-Z0-9]{10}'
      and ce.created_at < p_now - interval '24 hours'
      and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 1
  ), '[]'::jsonb);

  -- V8 - one receipt is evidence on two live bookings (s78, TASKS #20; DESIGN-conflict-verifier V8). Red: one payment
  -- may be counted for two stays. SPEC-44 refuses only a TYPED reference already seen on another booking, at the
  -- paid-outside confirm. This catches the rest: the same uploaded image (content_hash; Messenger receipts reach the same
  -- table through upload-booking-receipt), a reference read off a receipt on one booking and read or typed on another,
  -- and - when one side has no reference - the same amount uploaded within 30 minutes of each other.
  -- Both bookings must still be live (pending or confirmed) and one of them not yet checked out: a guest who resent the
  -- same receipt after their hold lapsed is an honest resend and stays quiet. One finding per pair of bookings, keyed by
  -- both ids in a fixed order. Detail is ids, dates, statuses and the match only, so an acknowledgement holds until one
  -- of those moves (a pending booking that gets confirmed re-opens it, on purpose).
  -- manual_evidence hashes are derived from the one-tap key, never from an image, so they never match as an image.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V8:' || p.a_id::text || ':' || p.b_id::text,
      'check_id', 'V8',
      'severity', 'red',
      'title',    'One receipt on two bookings',
      'detail',   jsonb_build_object(
        'match',     to_jsonb(p.matches),
        'reference', p.reference,
        'amount',    p.amount,
        'a', jsonb_build_object('booking', ba.id, 'guest', ba.guest_name, 'status', ba.status, 'from', ba.checkin_date, 'to', ba.checkout_date),
        'b', jsonb_build_object('booking', bb.id, 'guest', bb.guest_name, 'status', bb.status, 'from', bb.checkin_date, 'to', bb.checkout_date)))
      order by p.a_id, p.b_id)
    from (
      select x.booking_id as a_id, y.booking_id as b_id,
             array_agg(distinct case
               when x.content_hash = y.content_hash
                    and x.source_type <> 'manual_evidence' and y.source_type <> 'manual_evidence' then 'image'
               when x.normalized_reference = y.normalized_reference then 'reference'
               else 'amount_time' end) as matches,
             max(x.normalized_reference) filter (where x.normalized_reference = y.normalized_reference) as reference,
             max(coalesce(x.normalized_amount, y.normalized_amount)) as amount
        from public.payment_evidence_candidates x
        join public.payment_evidence_candidates y
          on y.property_id = x.property_id
         and x.booking_id < y.booking_id
         and (   (x.content_hash = y.content_hash
                  and x.source_type <> 'manual_evidence' and y.source_type <> 'manual_evidence')
              or x.normalized_reference = y.normalized_reference
              or (x.source_type = 'receipt_ocr' and y.source_type = 'receipt_ocr'
                  and x.normalized_amount = y.normalized_amount
                  and (x.normalized_reference is null or y.normalized_reference is null)
                  and x.observed_at between y.observed_at - interval '30 minutes' and y.observed_at + interval '30 minutes'))
       where x.property_id = p_property_id
       group by x.booking_id, y.booking_id
    ) p
    join public.booking_inquiries ba on ba.id = p.a_id
    join public.booking_inquiries bb on bb.id = p.b_id
    where ba.status in ('pending', 'confirmed') and bb.status in ('pending', 'confirmed')
      and greatest(ba.checkout_date, bb.checkout_date) > p_now::date
  ), '[]'::jsonb);

  -- V6 - arriving within three days with no ID on file. Daily only: it is a
  -- this-week job, and raising it every hour would be noise.
  if v_daily then
    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V6:' || b.id::text,
        'check_id', 'V6',
        'severity', 'yellow',
        'title',    'Arriving soon with no ID on file',
        'detail',   jsonb_build_object('booking', b.id, 'guest', b.guest_name, 'arrives', b.checkin_date)))
      from public.booking_inquiries b
      where b.property_id = p_property_id
        and b.status = 'confirmed'
        and b.checkin_date >= p_now::date
        and b.checkin_date <= p_now::date + 3
        and not exists (
          select 1 from public.guest_profile_details g
          where g.guest_id = b.guest_id and g.id_on_file is true)
    ), '[]'::jsonb);
  end if;

  -- V11 - the Concierge has been off auto for over two hours. A singleton key:
  -- it is one condition, not one per row.
  -- app_settings.value is JSONB, so s.value::text is "auto" WITH the quotes and
  -- would never equal 'auto'. Written the obvious way, this check raised a
  -- permanent yellow against a Concierge that was on auto the whole time; CI
  -- caught it because migration 20260911000000 seeds the setting as "suggest".
  -- #>> '{}' unwraps a jsonb scalar to its text, which is the only comparison
  -- that is right for both.
  select s.value #>> '{}', s.updated_at into v_mode, v_mode_since
    from public.app_settings s where s.key = 'concierge_mode';
  if v_mode is not null and v_mode <> 'auto' and v_mode_since < p_now - interval '2 hours' then
    v_found := v_found || jsonb_build_array(jsonb_build_object(
      'key', 'V11', 'check_id', 'V11', 'severity', 'yellow',
      'title', 'Concierge is not on auto',
      'detail', jsonb_build_object('mode', v_mode, 'since', v_mode_since)));
  end if;

  -- V12 - the Airbnb feed has gone quiet. Red: a booking landing now would be
  -- invisible, and B36 makes the reaper abort without telling anyone.
  -- The status literal is 'ok'. It is NOT 'success' - read against production
  -- on 2026-09-21, where 3513 rows are 'ok' and 95 are 'error'. The design's
  -- literal was wrong and this check would have alerted on a healthy feed.
  select max(l.synced_at) into v_sync
    from public.calendar_sync_log l
   where l.property_id = p_property_id
     and l.source = 'airbnb' and l.status = 'ok' and coalesce(l.event_count, 0) > 0;
  if v_sync is null or v_sync < p_now - interval '3 hours' then
    v_found := v_found || jsonb_build_array(jsonb_build_object(
      'key', 'V12', 'check_id', 'V12', 'severity', 'red',
      'title', 'Airbnb feed has gone quiet',
      'detail', jsonb_build_object('last_good_sync', v_sync)));
  end if;

  -- V10 - the ten System health checks, once a day. Severity is the check's
  -- own: fail is red, warn is yellow.
  --
  -- This READS admin_health_check_runs rather than calling
  -- run_health_checks_service_v1, and the difference matters. The health checks
  -- persist their result, so the table IS the answer; calling the function from
  -- here would make this function a writer, which would break two things it
  -- promises - that it is `stable`, and that ?dry=1 has no side effect at all.
  -- The system-verifier Edge Function calls run_health_checks_service_v1 first
  -- on the daily scope, so what this reads is minutes old. If that call is ever
  -- lost, V10:stale below says so out loud instead of quietly reporting a run
  -- from last week. (Production's stored run was seven days old when this was
  -- written, which is exactly how that failure looks.)
  if v_daily then
    select max(h.ran_at) into v_hc_ran
      from public.admin_health_check_runs h where h.property_id = p_property_id;

    if v_hc_ran is null or v_hc_ran < p_now - interval '36 hours' then
      v_found := v_found || jsonb_build_array(jsonb_build_object(
        'key', 'V10:stale', 'check_id', 'V10', 'severity', 'red',
        'title', 'System health has not been run',
        'detail', jsonb_build_object('last_run', v_hc_ran)));
    end if;

    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V10:' || h.check_key,
        'check_id', 'V10',
        -- D-232 (supersedes D-213 for checkouts_cleaned): a missing cleaning report is
        -- missed-cleaning-alert's job in OPS, so here it is yellow like every other warn.
        'severity', case when h.status = 'fail' then 'red' else 'yellow' end,
        'title',    public.health_check_problem_v1(h.check_key),
        'detail',   jsonb_build_object(
                      'check', h.check_key, 'status', h.status, 'n', h.count,
                      'label', h.label, 'd', h.detail)
                    -- K16: ledger_duplicates n=2 is explained, not broken. Both
                    -- pairs were gone through on 2026-09-14 (D-124) and left as
                    -- they are. Stored acknowledged by apply_verifier_run_v1, so
                    -- it never alerts unless the count moves off 2.
                    || case when h.check_key = 'ledger_duplicates' and h.count = 2
                            then jsonb_build_object('accepted', true, 'note',
                              'Both duplicate pairs were checked on 2026-09-14 and are legitimate. This will alert only if the count changes.')
                            else '{}'::jsonb end))
      from public.admin_health_check_runs h
      where h.property_id = p_property_id and h.status <> 'pass'
    ), '[]'::jsonb);
  end if;

  -- s91 V19 begin
  -- V19 - the month KPIs against a second count from the raw books (docs/s91/KPI-AUDIT.md 3.3). Daily only; the current Manila month and the
  -- three before. Red: a headline number differs; yellow: finance summary, cleaner fees, or a hygiene count. audience: Finance group (D-306).
  if v_daily then
    v_found := v_found || public.kpi_reconcile_window_v1(p_property_id, (p_now at time zone 'Asia/Manila')::date);
  end if;
  -- s91 V19 end

  -- s115 V20 begin
  -- V20 - pay records against the calendar and the reports (docs/s115/PLAN.md 5). Both scopes. Keys carry ids last; detail is ids, dates and names only,
  -- so an acknowledgement holds until one of them moves. audience: Finance group, except report_no_stay (OPS).
  -- advance_no_stay: a live paid-ahead line for a date that is no confirmed checkout (the 6FF96A06 case: a cancelled booking's blocked row).
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:advance_no_stay:' || q.ref || ':' || a.d,
      'check_id', 'V20',
      'severity', 'red',
      'title',    'Paid-ahead line is for a date with no confirmed checkout',
      'detail',   jsonb_build_object('ref', q.ref, 'date', a.d, 'payee', q.payee_name)))
    from public.staff_pay_requests q
    cross join lateral (select (l.value ->> 'checkout_date')::date as d from jsonb_array_elements(q.lines) l where l.value ->> 'kind' = 'advance') a
    where q.property_id = p_property_id and q.status <> 'cancelled' and q.created_at > p_now - interval '90 days' and a.d is not null
      and not exists (select 1 from public.calendar_events ce
                       where ce.property_id = q.property_id and ce.status = 'confirmed' and ce.checkout_date = a.d)
  ), '[]'::jsonb);

  -- paid_no_link: paid ahead more than 3 days ago, no report linked to the line, and the payee has a report within a day of that date that is on no paid request.
  -- report_date is that report's checkout date (contract amendment 1), so the card can say which date the report on file is for.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:paid_no_link:' || q.ref || ':' || a.d,
      'check_id', 'V20',
      'severity', 'red',
      'title',    'Paid ahead, but the report on file is for another date',
      'detail',   jsonb_build_object('ref', q.ref, 'date', a.d, 'payee', q.payee_name, 'session', s.id, 'report_date', s.checkout_date)))
    from public.staff_pay_requests q
    cross join lateral (select (l.value ->> 'checkout_date')::date as d from jsonb_array_elements(q.lines) l where l.value ->> 'kind' = 'advance') a
    cross join lateral (
      select cs.id, cs.checkout_date
        from public.cleaning_sessions cs
       where cs.property_id = q.property_id and cs.submitted_by_user_id = q.payee_user_id
         and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
         and cs.checkout_date between a.d - 1 and a.d + 1 and cs.fee_paid_at is null
         and (cs.pay_request_id is null
              or not exists (select 1 from public.staff_pay_requests r2 where r2.id = cs.pay_request_id and r2.status = 'paid'))
       order by abs(cs.checkout_date - a.d), cs.cleaned_at limit 1) s
    where q.property_id = p_property_id and q.status = 'paid' and q.paid_at < p_now - interval '3 days'
      and q.created_at > p_now - interval '90 days' and a.d is not null
      and public.s_advance_session_v1(q.id, a.d) is null
  ), '[]'::jsonb);

  -- stuck_paying: a request has sat in "paying" for more than a day.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:stuck_paying:' || q.ref,
      'check_id', 'V20',
      'severity', 'yellow',
      'title',    'Payment request stuck in paying',
      'detail',   jsonb_build_object('ref', q.ref, 'date', (select min(coalesce(l.value ->> 'checkout_date', l.value ->> 'date')) from jsonb_array_elements(q.lines) l),
                                     'payee', q.payee_name, 'since', coalesce(q.paying_at, q.updated_at))))
    from public.staff_pay_requests q
    where q.property_id = p_property_id and q.status = 'paying' and coalesce(q.paying_at, q.updated_at) < p_now - interval '24 hours'
  ), '[]'::jsonb);

  -- session_twice: one report on two live requests, or a report whose fee transaction was voided.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:session_twice:' || u.sid,
      'check_id', 'V20',
      'severity', 'red',
      'title',    'One cleaning report is paid or requested twice',
      'detail',   jsonb_build_object('ref', u.refs, 'date', u.d, 'payee', u.payee, 'session', u.sid)))
    from (
      select distinct on (z.sid) z.sid, z.refs, z.d, z.payee
        from (
          select x.sid, string_agg(x.ref, ' ' order by x.ref) as refs, min(x.d) as d, min(x.payee_name) as payee
            from (select q.id, q.ref, q.payee_name, l.value ->> 'session_id' as sid, coalesce(l.value ->> 'date', l.value ->> 'checkout_date') as d
                    from public.staff_pay_requests q cross join lateral jsonb_array_elements(q.lines) l
                   where q.property_id = p_property_id and q.status <> 'cancelled' and q.created_at > p_now - interval '90 days'
                     and l.value ->> 'session_id' is not null) x
           group by x.sid having count(distinct x.id) > 1
          union all
          select cs.id::text, r.ref, cs.checkout_date::text, r.payee_name
            from public.cleaning_sessions cs
            join public.transactions t on t.id = cs.fee_txn_id
            left join public.staff_pay_requests r on r.id = cs.pay_request_id
           where cs.property_id = p_property_id and t.status = 'void' and cs.cleaned_at > p_now - interval '90 days'
        ) z
       order by z.sid, z.refs
    ) u
  ), '[]'::jsonb);

  -- report_no_stay: a turnover report (90 days) whose checkout matches no confirmed stay. Yellow, OPS.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V20:report_no_stay:' || cs.id::text,
      'check_id', 'V20',
      'severity', 'yellow',
      'title',    'Cleaning report for a date with no confirmed stay',
      'detail',   jsonb_build_object('session', cs.id, 'date', cs.checkout_date, 'payee', cs.cleaner_name)))
    from public.cleaning_sessions cs
    where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'checkout') in ('checkout', 'turnover')
      and cs.checkout_date is not null and cs.cleaned_at > p_now - interval '90 days'
      and not exists (select 1 from public.calendar_events ce
                       where ce.property_id = cs.property_id and ce.status = 'confirmed' and ce.checkout_date = cs.checkout_date)
  ), '[]'::jsonb);
  -- s115 V20 end

  -- s115 V21 begin
  -- V21 - the calendar against the Airbnb reservations. Daily only; rows that ended in the last two weeks or are still ahead.
  if v_daily then
    -- block_named: a blocked row that carries a guest's name whose reservation (same name, same dates) is cancelled: calendar-sync kept the cancelled stay as a block.
    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V21:block_named:' || ce.id::text,
        'check_id', 'V21',
        'severity', 'yellow',
        'title',    'Blocked calendar row still carries a cancelled guest''s name',
        'detail',   jsonb_build_object('event', ce.id, 'guest', ce.guest_name, 'from', ce.checkin_date, 'to', ce.checkout_date, 'code', ar.confirmation_code)))
      from public.calendar_events ce
      join public.airbnb_reservations ar
        on ar.property_id = ce.property_id and ar.status = 'cancelled'
       and ar.checkin_date = ce.checkin_date and ar.checkout_date = ce.checkout_date
       and (lower(btrim(ar.guest_name)) = lower(btrim(ce.guest_name)) or position(lower(btrim(ce.guest_name)) in lower(btrim(ar.guest_name))) = 1)
      where ce.property_id = p_property_id and ce.status = 'blocked' and nullif(btrim(coalesce(ce.guest_name, '')), '') is not null
        and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 14
    ), '[]'::jsonb);

    -- confirmed_cancelled: a confirmed calendar row whose linked reservation is cancelled.
    v_found := v_found || coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',      'V21:confirmed_cancelled:' || ce.id::text,
        'check_id', 'V21',
        'severity', 'red',
        'title',    'Confirmed calendar row for a cancelled reservation',
        'detail',   jsonb_build_object('event', ce.id, 'guest', ce.guest_name, 'from', ce.checkin_date, 'to', ce.checkout_date, 'code', ar.confirmation_code)))
      from public.calendar_events ce
      join public.airbnb_reservations ar on ar.id = ce.linked_reservation_id
      where ce.property_id = p_property_id and ce.status = 'confirmed' and ar.status = 'cancelled'
        and ce.checkout_date >= (p_now at time zone 'Asia/Manila')::date - 14
    ), '[]'::jsonb);
  end if;
  -- s115 V21 end

  -- s115 V22 begin
  -- V22 - a paid model provider has refused every call (HTTP 402) in the last day and answered none since: the credit is used up. Probes are ignored.
  -- features are the call titles refused since the last good call, in words a person reads (contract amendment 1).
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V22:credit_gone:' || pv.provider,
      'check_id', 'V22',
      'severity', 'red',
      'title',    'Paid API credit is used up',
      'detail',   jsonb_build_object('provider', pv.provider, 'since', y.since, 'features', y.features)))
    from (select distinct u.provider
            from public.llm_usage u
           where u.at > p_now - interval '24 hours' and u.at <= p_now and coalesce(u.probe, false) = false
             and u.ok is not true and u.error like '%\_402') pv
    cross join lateral (select max(o.at) as last_ok from public.llm_usage o
                         where o.provider = pv.provider and o.ok is true and coalesce(o.probe, false) = false
                           and o.at > p_now - interval '30 days' and o.at <= p_now) k
    cross join lateral (
      select min(w.at) as since, coalesce(jsonb_agg(distinct w.nm order by w.nm), '[]'::jsonb) as features
        from (select x.at,
                     case btrim(coalesce(x.title, ''))
                       when 'Cascade ID face box'   then 'the ID face box'
                       when 'Cascade Guest Details' then 'guest details'
                       when 'Cascade Meter'         then 'meter readings'
                       when 'Cascade Power Watch'   then 'Power Watch'
                       else lower(left(regexp_replace(btrim(coalesce(x.title, 'unknown')), '^Cascade ', ''), 1))
                            || substr(regexp_replace(btrim(coalesce(x.title, 'unknown')), '^Cascade ', ''), 2)
                     end as nm
                from public.llm_usage x
               where x.provider = pv.provider and x.error like '%\_402' and coalesce(x.probe, false) = false
                 and x.at > coalesce(k.last_ok, p_now - interval '30 days') and x.at <= p_now) w) y
    where y.since is not null
  ), '[]'::jsonb);
  -- s115 V22 end

  -- s115 V23 begin
  -- V23 - the meter chain: each reading should start where the previous one ended. An overlap or a gap means a reading was missed, doubled or estimated. It raises exactly the readings
  -- kpi_tab_v1 leaves out of the per-day figures (both read public.meter_chain_v1, ML-10), until they are put right. Last 60 days. Finance group.
  -- detail (cards.ts v23Facts): reading = this reading's meter value, prev = the reading before it ended at, expected_prev = this one says it started from, checkout, reading_id.
  v_found := v_found || coalesce((
    select jsonb_agg(jsonb_build_object(
      'key',      'V23:meter_chain:' || x.id::text,
      'check_id', 'V23',
      'severity', 'yellow',
      'title',    'Meter reading does not continue the previous one',
      'detail',   jsonb_build_object('reading', x.electric_curr, 'checkout', x.cd, 'prev', x.pc, 'expected_prev', x.electric_prev, 'reading_id', x.id)))
    from public.meter_chain_v1(p_property_id) x
    where not x.chain_ok and x.recorded_at > p_now - interval '60 days'
  ), '[]'::jsonb);
  -- s115 V23 end

  return jsonb_build_object('scope', p_scope, 'ran_at', p_now, 'found', v_found);
end;
$body$
;
revoke all on function public.run_system_verifier_v1(uuid,text,timestamp with time zone) from public, anon, authenticated;
grant execute on function public.run_system_verifier_v1(uuid,text,timestamp with time zone) to service_role;

create or replace function public.apply_verifier_run_v1(p_scope text, p_found jsonb, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $body$
declare
  v_checks text[];
  v_new      jsonb := '[]'::jsonb;
  v_remind   jsonb := '[]'::jsonb;
  v_resolved jsonb := '[]'::jsonb;
  r record;
begin
  if p_scope not in ('hourly', 'daily') then
    raise exception 'scope must be hourly or daily' using errcode = '22023';
  end if;
  if p_found is null or jsonb_typeof(p_found) <> 'array' then
    raise exception 'p_found must be a json array' using errcode = '22023';
  end if;

  v_checks := case p_scope
    -- V13 (model budget) is raised by the system-verifier Edge Function in both scopes (D-227).
    -- V14-V18 (API governor, D-294) are raised by the Edge Function in the daily scope; V14-V15 hourly too (urgent).
    -- V8 (receipt reused on two live bookings, s78) runs in both scopes, so a finding that is gone resolves either way.
    -- V19 (month KPIs against the raw books, s91) is raised by run_system_verifier_v1 in the daily scope only.
    -- s115: V20 (pay records vs calendar and reports) and V22 (paid API credit gone) are raised by run_system_verifier_v1 in both scopes, V21 (calendar vs reservations) in the daily scope.
    when 'hourly' then array['V1','V2','V3','V4','V5','V7','V7b','V8','V11','V12','V13','V14','V15','V20','V22','V23']
    else                array['V1','V2','V3','V4','V5','V6','V7','V7b','V8','V10','V11','V12','V13','V14','V15','V16','V17','V18','V19','V20','V21','V22','V23']
  end;

  -- Everything seen in this run: insert it, or mark it seen again. A finding
  -- that has been acknowledged stays acknowledged unless its shape changed,
  -- which is what the design's detail->>'n' comparison is for; here the whole
  -- detail is compared, because these checks carry ids rather than a count.
  for r in select value as v from jsonb_array_elements(p_found) loop
    -- An ALREADY-ACCEPTED finding is born acknowledged and never alerts. Only
    -- V10 sets detail.accepted, and only for K16's ledger_duplicates n=2. The
    -- on-conflict branch below still flips it back to open the moment the
    -- detail changes, which is what makes this safe: accepting a shape is not
    -- accepting the check forever.
    insert into public.verifier_findings as f
      (key, check_id, severity, title, detail, status, first_seen, last_seen)
    values (r.v->>'key', r.v->>'check_id', r.v->>'severity', r.v->>'title',
            coalesce(r.v->'detail', '{}'::jsonb),
            case when coalesce(r.v->'detail'->>'accepted', '') = 'true'
                 then 'acknowledged' else 'open' end,
            p_now, p_now)
    on conflict (key) do update
      set last_seen = p_now,
          severity  = excluded.severity,
          title     = excluded.title,
          detail    = excluded.detail,
          status    = case
                        when f.status = 'resolved' then 'open'
                        when f.status = 'acknowledged' and f.detail <> excluded.detail then 'open'
                        else f.status
                      end,
          resolved_at = null,
          resolved_by = null;
  end loop;

  -- s115: an acknowledged RED finding that is still being seen re-opens after 3 days, so one old "Mark handled" cannot hide an outage for good (the alert step then re-announces it).
  -- The alert step below then sends it again (red repeats after 24 hours). Yellow stays acknowledged; an accepted finding (acknowledged_at null) is untouched.
  update public.verifier_findings f set status = 'open'
   where f.status = 'acknowledged' and f.severity = 'red' and f.last_seen = p_now and f.acknowledged_at < p_now - interval '3 days';

  -- Auto-resolution 1: a ghost hold whose inquiry is already expired or
  -- cancelled. This writes exactly what expire_booking_holds_v1 writes, on
  -- exactly the rows it would have written to, and nothing else.
  for r in
    select f.key, (f.detail->>'event')::uuid as event_id
      from public.verifier_findings f
     where f.check_id = 'V3' and f.status = 'open'
       and f.last_seen = p_now
       and (f.detail->>'auto_safe')::boolean is true
  loop
    update public.calendar_events set status = 'cancelled'
     where id = r.event_id and status = 'blocked';
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', 'The booking behind this hold had already expired, so the hold was cancelled the same way the hold releaser would have.')
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Calendar hold with no live booking behind it', 'auto', true));
    end if;
  end loop;

  -- Auto-resolution 2: a stuck Messenger flow whose booking is already dead.
  -- The thread carries no booking id, so the match is the guest's e-mail AND
  -- both dates, and all three must be present. No match means no change: the
  -- safe direction is always to leave the flow alone and tell a person.
  for r in
    select f.key, f.detail->>'psid' as psid
      from public.verifier_findings f
     where f.check_id = 'V4' and f.status = 'open'
       and f.last_seen = p_now
       and coalesce(f.detail->>'email', '') <> ''
       and coalesce(f.detail->>'from', '')  <> ''
       and coalesce(f.detail->>'to', '')    <> ''
       and exists (
         select 1 from public.booking_inquiries b
          where lower(b.guest_email) = lower(f.detail->>'email')
            and b.checkin_date  = (f.detail->>'from')::date
            and b.checkout_date = (f.detail->>'to')::date
            and b.status in ('expired', 'cancelled'))
  loop
    update public.concierge_threads
       set booking_flow = booking_flow || jsonb_build_object('step', 'cancelled', 'updated_at', p_now)
     where psid = r.psid;
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', 'The booking this conversation was waiting on had already expired, so the flow was closed and the guest can start again.')
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Messenger booking stuck at the payment step', 'auto', true));
    end if;
  end loop;

  -- Auto-resolution 3 (D-235): the Airbnb calendar is the primary record. A confirmed reservation
  -- whose dates disagree with its confirmed calendar row takes the calendar's dates (nights is generated
  -- from them). Money is never touched: the payout e-mail reconciles it, and payout_totals_agree judges it.
  for r in
    select f.key, (f.detail->>'reservation')::uuid as res_id,
           (f.detail->>'calendar_from')::date as cal_from, (f.detail->>'calendar_to')::date as cal_to,
           (f.detail->>'email_from')::date as em_from, (f.detail->>'email_to')::date as em_to
      from public.verifier_findings f
     where f.check_id = 'V7' and f.status = 'open'
       and f.last_seen = p_now
       and (f.detail->>'auto_safe')::boolean is true
  loop
    update public.airbnb_reservations
       set checkin_date = r.cal_from, checkout_date = r.cal_to
     where id = r.res_id and status = 'confirmed';
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', format(
               'The Airbnb calendar is the primary record, so the reservation dates were corrected from it: %s to %s became %s to %s.',
               coalesce(to_char(r.em_from, 'Mon FMDD'), 'no date'), coalesce(to_char(r.em_to, 'Mon FMDD'), 'no date'),
               to_char(r.cal_from, 'Mon FMDD'), to_char(r.cal_to, 'Mon FMDD')))
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Reservation dates corrected from the Airbnb calendar', 'auto', true));
    end if;
  end loop;

  -- V7b is a weekly line plus ONE Follow-ups task per stay (D-218); the task closes itself below.
  for r in
    select f.detail->>'uid' as uid, f.detail->>'code' as code, f.detail->>'from' as d_from, f.detail->>'to' as d_to
      from public.verifier_findings f
     where f.check_id = 'V7b' and f.status = 'open' and f.last_seen = p_now
  loop
    perform public.system_task_open_v1(
      (select ce.property_id from public.calendar_events ce where ce.uid = r.uid limit 1),
      'airbnb_unmatched', r.uid,
      'Find the booking e-mail for Airbnb ' || coalesce(r.code, 'stay') || ' (' || r.d_from || ' to ' || r.d_to || ')',
      'The Airbnb calendar shows this stay but no booking e-mail matched it in 24 hours. Check the cascadereservations inbox, or the reservation on Airbnb.',
      'normal');
  end loop;

  -- Gone: open findings of a check this scope ran, that this run did not see.
  for r in
    update public.verifier_findings f
       set status = 'resolved', resolved_at = p_now, resolved_by = 'auto'
     where f.status in ('open', 'acknowledged')
       and f.check_id = any (v_checks)
       and f.last_seen < p_now
    returning f.key, f.title, f.severity
  loop
    v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', r.title, 'auto', false));
  end loop;

  perform public.system_task_close_missing_v1('airbnb_unmatched',
    array(select f.detail->>'uid' from public.verifier_findings f where f.check_id = 'V7b' and f.status in ('open', 'acknowledged')),
    null, 'Closed automatically: the booking e-mail arrived and the stay is linked.');

  -- Worth saying out loud: never alerted, or alerted long enough ago to be
  -- worth repeating. Acknowledged findings are never reminded about; that is
  -- the whole point of the button.
  for r in
    update public.verifier_findings f
       set last_alerted_at = p_now
     where f.status = 'open'
       and f.last_seen = p_now
       and (f.last_alerted_at is null
            or f.last_alerted_at < p_now - (case when f.severity = 'red' then interval '24 hours' else interval '7 days' end))
    returning f.key, f.check_id, f.severity, f.title, f.detail, f.first_seen
  loop
    if r.first_seen = p_now then
      v_new := v_new || jsonb_build_array(jsonb_build_object('key', r.key, 'check_id', r.check_id, 'severity', r.severity, 'title', r.title, 'detail', r.detail));
    else
      v_remind := v_remind || jsonb_build_array(jsonb_build_object('key', r.key, 'check_id', r.check_id, 'severity', r.severity, 'title', r.title, 'detail', r.detail));
    end if;
  end loop;

  return jsonb_build_object('new', v_new, 'remind', v_remind, 'resolved', v_resolved);
end;
$body$
;
revoke all on function public.apply_verifier_run_v1(text,jsonb,timestamp with time zone) from public, anon, authenticated;
grant execute on function public.apply_verifier_run_v1(text,jsonb,timestamp with time zone) to service_role;

create or replace function public.kpi_tab_v1(p_property_id uuid, p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $body$
declare
  v_today date := public.manila_today(); v_m0 date; v_m1 date; v_fin boolean;
  v_kwh numeric; v_nights numeric; v_last jsonb; v_per jsonb; v_bo jsonb; v_wc jsonb; v_inv jsonb; v_out jsonb;
  v_turn integer; v_turn90 integer; v_rate public.utility_rates%rowtype; v_lastd numeric; v_usage_cost numeric; v_ic jsonb;
  v_fs jsonb; v_hm jsonb; v_sold numeric; v_dn numeric; v_mcost numeric;
  v_m3 numeric; v_kpd numeric; v_mpd numeric; v_pm jsonb; v_nb integer;
  v_tnet numeric; v_tat timestamptz; v_tby text; v_cb numeric; v_rn numeric; v_adr numeric;
  v_cset jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('read_operations', p_property_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_m0 := date_trunc('month', coalesce(p_month, v_today))::date;
  v_m1 := (v_m0 + interval '1 month')::date;

  -- s115 utility block (Lloyd 2026-11-11: one sharp day in the chart). The s111 days ran from the previous REPORT to this one, so late reports filed together gave a 2-night reading
  -- "1 day", and meter ranges that overlap counted one stretch of use twice. Now: the eligible readings (the s111 filters: both prev > 0, both deltas >= 0, flag null / typed_accepted / estimated)
  -- are ordered by their meter chain (electric_prev, checkout day, recorded_at, id) in public.meter_chain_v1, the one chain V23 also reads. cd = the checkout day of the reading's cleaning session, the recorded Manila day only when it has none.
  -- days = cd minus the previous eligible reading's cd, at least 1, null for the first. A reading whose electric_prev is not the previous eligible reading's electric_curr
  -- (an overlap or a gap) is left out of every figure here; V23 in run_system_verifier_v1 reports it. Months are the checkout month.
  with c as (
    select m.*, case when m.pcd is not null then greatest(1, m.cd - m.pcd) end days
      from public.meter_chain_v1(p_property_id) m where m.chain_ok
  )
  select (select coalesce(sum(c.electric_delta), 0) from c where c.cd >= v_m0 and c.cd < v_m1),
         (select coalesce(sum(c.water_delta), 0) from c where c.cd >= v_m0 and c.cd < v_m1),
         (select case when sum(c.days) > 0 then round(sum(c.electric_delta) filter (where c.days is not null) / sum(c.days), 2) end from c where c.cd >= v_m0 and c.cd < v_m1),
         (select case when sum(c.days) > 0 then round(sum(c.water_delta) filter (where c.days is not null) / sum(c.days), 2) end from c where c.cd >= v_m0 and c.cd < v_m1),
         (select jsonb_build_object('recorded_at', c.recorded_at, 'delta_kwh', c.electric_delta, 'days', c.days, 'kwh_per_day', round(c.electric_delta / c.days, 2),
                                    'delta_m3', c.water_delta, 'm3_per_day', round(c.water_delta / c.days, 2), 'flag', c.meter_flag)
            from c order by c.recorded_at desc, c.id limit 1),
         (select coalesce(jsonb_agg(jsonb_build_object('checkout_date', y.checkout_date, 'recorded_at', y.recorded_at, 'from', y.pcd, 'to', y.cd, 'days', y.days,
                                                       'kwh', y.electric_delta, 'kwh_per_day', round(y.electric_delta / y.days, 2),
                                                       'm3', y.water_delta, 'm3_per_day', round(y.water_delta / y.days, 2)) order by y.cd, y.recorded_at, y.id), '[]'::jsonb)
            from (select * from c order by c.cd desc, c.recorded_at desc, c.id desc limit 8) y),
         (select jsonb_agg(jsonb_build_object('month', to_char(g.m, 'YYYY-MM'), 'stays', coalesce(a.n, 0), 'kwh', round(a.e, 2), 'm3', round(a.w, 2),
                                              'kwh_per_stay', case when a.n > 0 then round(a.e / a.n, 1) end, 'm3_per_stay', case when a.n > 0 then round(a.w / a.n, 2) end,
                                              'kwh_per_day', case when a.dd > 0 then round(a.ed / a.dd, 2) end, 'm3_per_day', case when a.dd > 0 then round(a.wd / a.dd, 2) end) order by g.m)
            from (select (v_m0 - (k * interval '1 month'))::date m from generate_series(0, 11) k) g
            left join (select date_trunc('month', c.cd)::date m, count(*)::integer n, sum(c.electric_delta) e, sum(c.water_delta) w,
                              sum(c.electric_delta) filter (where c.days is not null) ed, sum(c.water_delta) filter (where c.days is not null) wd, sum(c.days) dd
                         from c where c.cd >= (v_m0 - interval '11 months')::date and c.cd < v_m1 group by 1) a on a.m = g.m),
         (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'cd', c.cd)), '[]'::jsonb) from c)
    into v_kwh, v_m3, v_kpd, v_mpd, v_last, v_per, v_pm, v_cset;
  v_lastd := (v_last ->> 'delta_kwh')::numeric;
  -- nights_booked: get_hospitality_metrics_v1 sold_nights replicated exactly (hospitality_metrics_core_v1 20261026010000 over admin_stays_v1 20261026000000):
  -- distinct nights of the month covered by a confirmed / completed stay. The core cannot be called here: admin_stays_v1 raises not_authorized for cleaner and laundry.
  select count(distinct d)::integer into v_nb
    from (select r.checkin_date ci, r.checkout_date co from public.airbnb_reservations r
           where r.property_id = p_property_id and r.checkin_date is not null and r.checkout_date is not null and r.source is distinct from 'direct'
             and r.status in ('confirmed', 'completed')
          union all
          select i.checkin_date, i.checkout_date from public.booking_inquiries i
           where i.property_id = p_property_id and i.status in ('confirmed', 'completed')) s
    cross join lateral generate_series(greatest(s.ci, v_m0), least(s.co, v_m1) - 1, interval '1 day') d
   where s.ci < v_m1 and s.co > v_m0;

  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_bo
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type = 'brownout' and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1;
  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_wc
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type = 'water' and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1;

  -- internet: the same rule as lib.js isInternetNotice (an internet word AND an outage word in the title or text of a note / maintenance notice)
  select jsonb_build_object('count', count(*), 'hours', coalesce(round(sum(n.duration_hours), 1), 0)) into v_ic
    from public.ops_notices n
   where n.property_id = p_property_id and n.notice_type in ('note', 'maintenance') and n.is_active and n.effective_date >= v_m0 and n.effective_date < v_m1
     and lower(coalesce(n.title, '') || ' ' || coalesce(n.description, '')) ~ '\m(internet|wi-?fi|fiber|fibre|pldt|converge|globe at home|sky ?fiber|modem|router)\M'
     and lower(coalesce(n.title, '') || ' ' || coalesce(n.description, '')) ~ '\m(no|down|outage|interrupt\w*|offline|maintenance|repair\w*|cut|walang|wala|mawawala|disconnect\w*)\M';

  select count(*) into v_turn from public.cleaning_sessions cs
   where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')
     and (cs.cleaned_at at time zone 'Asia/Manila')::date >= v_m0 and (cs.cleaned_at at time zone 'Asia/Manila')::date < v_m1;
  select count(*) into v_turn90 from public.cleaning_sessions cs
   where cs.property_id = p_property_id and coalesce(cs.cleaning_type, 'turnover') in ('turnover', 'deep_clean')
     and (cs.cleaned_at at time zone 'Asia/Manila')::date > v_today - 90;

  select jsonb_build_object(
    'low_now', (select count(*) from public.inventory_items i where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below),
    'restocks_month', (select count(*) from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
                        where i.property_id = p_property_id and p.purchased_at >= v_m0 and p.purchased_at < v_m1),
    'turnovers_month', v_turn,
    'per_turnover', coalesce((
      select jsonb_agg(jsonb_build_object('item_id', t.id, 'name', t.name, 'used_per_turnover', case when v_turn > 0 then round(t.used / v_turn, 2) end,
                                          'usual', case when v_turn90 > 0 then round(t.used90 / v_turn90, 2) end) order by t.used desc, t.name)
        from (select * from (
                select i.id, i.name, sum(u.used_qty) filter (where u.session_date >= v_m0 and u.session_date < v_m1) used,
                       sum(u.used_qty) filter (where u.session_date > v_today - 90) used90
                  from public.inventory_items i join public.inventory_usage u on u.item_id = i.id
                 where i.property_id = p_property_id and i.is_active and i.is_consumable group by i.id, i.name) z
               where z.used > 0 order by z.used desc, z.name limit 6) t), '[]'::jsonb),
    'runs_out', coalesce((
      select jsonb_agg(jsonb_build_object('item_id', r.id, 'name', r.name, 'days_left', r.days_left) order by r.days_left, r.name)
        from (select i.id, i.name, floor(i.qty_on_hand / (sum(u.used_qty) / 30.0))::integer days_left
                from public.inventory_items i join public.inventory_usage u on u.item_id = i.id
               where i.property_id = p_property_id and i.is_active and i.is_consumable and i.qty_on_hand is not null and i.qty_on_hand >= 0
                 and u.session_date > v_today - 30
               group by i.id, i.name, i.qty_on_hand having sum(u.used_qty) > 0 order by days_left, i.name limit 3) r), '[]'::jsonb))
    into v_inv;

  v_out := jsonb_build_object('ok', true, 'month', v_m0,
    'utility', jsonb_build_object('kwh_month', round(v_kwh, 2), 'kwh_per_day', v_kpd, 'm3_month', round(v_m3, 2), 'm3_per_day', v_mpd,
                                  'nights_booked', v_nb, 'nights_in_month', v_m1 - v_m0,
                                  'last_reading', v_last, 'per_stay', v_per, 'per_month', v_pm, 'brownouts', v_bo, 'water_cuts', v_wc, 'internet_cuts', v_ic),
    'inventory', v_inv);

  if v_fin then
    select * into v_rate from public.utility_rates r where r.effective_from <= v_today
     order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1;
    -- s115: the same counted readings as kwh_month (v_cset), each costed at the rate in force on its checkout day (latest month first, a manual correction beats an auto read of the same month)
    select sum(mr.electric_delta * rt.php_per_kwh) into v_mcost
      from jsonb_to_recordset(coalesce(v_cset, '[]'::jsonb)) x(id uuid, cd date)
      join public.meter_readings mr on mr.id = x.id
      cross join lateral (select r.php_per_kwh from public.utility_rates r where r.effective_from <= x.cd
                           order by date_trunc('month', r.effective_from) desc, (r.source = 'manual') desc, r.effective_from desc, r.created_at desc limit 1) rt
     where x.cd >= v_m0 and x.cd < v_m1;
    select coalesce(sum(u.used_qty * coalesce(i.unit_cost, 0)), 0) into v_usage_cost
      from public.inventory_usage u join public.inventory_items i on i.id = u.item_id
     where i.property_id = p_property_id and u.session_date >= v_m0 and u.session_date < v_m1;
    v_fs := public.get_finance_summary(v_m0, p_property_id);
    v_hm := public.hospitality_metrics_core_v1(p_property_id, v_m0, v_m1, true) -> 'metrics';
    v_sold := (v_hm -> 'sold_nights' ->> 'value')::numeric;
    select coalesce(sum(greatest(0, least(i.checkout_date, v_m1) - greatest(i.checkin_date, v_m0))), 0) into v_dn
      from public.booking_inquiries i
     where i.property_id = p_property_id and i.status in ('confirmed', 'completed') and coalesce(i.guest_name, '') !~* '^synthetic';
    v_out := v_out || jsonb_build_object('admin', jsonb_build_object(
      'revenue_month', (v_fs ->> 'income')::numeric, 'costs_month', (v_fs ->> 'expenses')::numeric, 'net_month', (v_fs ->> 'net')::numeric,
      'occupancy', case when (v_hm -> 'occupancy' ->> 'value') is not null then round((v_hm -> 'occupancy' ->> 'value')::numeric / 100, 4) end,
      'adr', (v_hm -> 'adr' ->> 'value')::numeric, 'sold_nights', v_sold, 'sellable_nights', (v_hm -> 'capacity_nights' ->> 'value')::numeric,
      'direct_share', case when v_sold > 0 then least(1, round(v_dn / v_sold, 4)) end,
      'rate', case when v_rate.id is null then null else jsonb_build_object('php_per_kwh', v_rate.php_per_kwh, 'effective_from', v_rate.effective_from,
                                                                            'source', v_rate.source, 'source_url', v_rate.source_url) end,
      'last_reading_cost', case when v_rate.id is not null and v_lastd is not null then round(v_lastd * v_rate.php_per_kwh, 2) end,
      'month_kwh_cost', case when v_rate.id is not null then round(coalesce(v_mcost, 0), 2) end,
      'supplies_month', (select coalesce(sum(p.qty * p.unit_cost), 0) from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
                          where i.property_id = p_property_id and p.purchased_at >= v_m0 and p.purchased_at < v_m1),
      'supply_cost_per_turnover', case when v_turn > 0 then round(v_usage_cost / v_turn, 2) end,
      'cleaning_pay_month', (select coalesce(sum(q.total_amount), 0) from public.staff_pay_requests q
                              where q.property_id = p_property_id and q.status in ('requested', 'paying', 'paid')
                                and (q.created_at at time zone 'Asia/Manila')::date >= v_m0 and (q.created_at at time zone 'Asia/Manila')::date < v_m1)));
    -- s111 admin.target. costs_basis = average get_finance_summary expenses of the 3 full months before the selected one, over the months that have any (null if none).
    -- nights_on_books = the core's sold_nights, which already counts every confirmed or completed night of the month, past and future. set_by = the setter's role.
    select t.monthly_net_target, t.set_at, p.role into v_tnet, v_tat, v_tby
      from public.kpi_targets t left join public.staff_access_profiles p on p.user_id = t.set_by
        and (p.role = 'owner' or exists (select 1 from public.staff_property_access s where s.user_id = p.user_id and s.property_id = t.property_id))
     where t.property_id = p_property_id;
    select round(avg(x.e), 2) into v_cb
      from (select (public.get_finance_summary((v_m0 - (k * interval '1 month'))::date, p_property_id) ->> 'expenses')::numeric e from generate_series(1, 3) k) x
     where x.e > 0;
    v_rn := v_cb + coalesce(v_tnet, 0);
    v_adr := (v_hm -> 'adr' ->> 'value')::numeric;
    v_out := jsonb_set(v_out, '{admin,target}', jsonb_build_object(
      'net_target', coalesce(v_tnet, 0), 'costs_basis', v_cb, 'revenue_needed', v_rn, 'adr', v_adr,
      'nights_in_month', v_m1 - v_m0, 'nights_on_books', v_sold,
      'needed_occupancy', case when v_adr > 0 and v_rn is not null then round(v_rn / (v_adr * (v_m1 - v_m0)), 4) end,
      'needed_adr', case when v_sold > 0 and v_rn is not null then round(v_rn / v_sold, 2) end,
      'set_by', v_tby, 'set_at', v_tat));
  end if;
  return v_out;
end;
$body$
;
revoke all on function public.kpi_tab_v1(uuid,date) from public, anon, service_role;
grant execute on function public.kpi_tab_v1(uuid,date) to authenticated;

commit;
