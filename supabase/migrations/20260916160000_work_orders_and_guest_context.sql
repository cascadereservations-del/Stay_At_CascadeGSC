-- Telegram plan §1 + §6 (admin session 26, 2026-09-16, D-160). Two service-role RPCs:
--   raise_work_order_v1  - idempotent work order from a cleaner's [URGENT] note or a Messenger
--                          complaint/safety handoff. blocks_arrival when urgent and a confirmed
--                          arrival is within 2 days. work_orders is revoked from service_role
--                          (20260913100000), so Edge Functions need this definer.
--   guest_context_v1     - one jsonb of what a booking card should say about a guest: stay count,
--                          last stay, last [URGENT] cleaning note after their stay, preferences,
--                          tags, VIP reason, note, birthday, open follow-ups. Empty fields are
--                          omitted so the caller renders only what exists.
-- No table, column or grant on existing objects changes.
begin;

create or replace function public.raise_work_order_v1(
  p_property_id uuid, p_source_kind text, p_source_ref text, p_title text, p_detail text, p_priority text default 'high'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_key text := 'wo:' || p_source_kind || ':' || p_source_ref;
  v_id uuid; v_created boolean := false; v_blocks boolean := false; v_today date := public.manila_today();
  v_next record;
begin
  if p_source_kind not in ('cleaning_issue', 'guest_report') then raise exception 'source_kind_not_allowed: %', p_source_kind; end if;
  if p_priority not in ('low', 'normal', 'high', 'urgent') then p_priority := 'high'; end if;
  select id into v_id from public.work_orders where idempotency_key = v_key;
  if v_id is null then
    select guest_name, checkin_date into v_next from public.calendar_events
     where property_id = p_property_id and status = 'confirmed' and checkin_date between v_today and v_today + 2
     order by checkin_date limit 1;
    v_blocks := p_priority = 'urgent' and v_next.checkin_date is not null;
    insert into public.work_orders (property_id, source_kind, source_ref, title, description, priority, blocks_arrival, status, idempotency_key)
    values (p_property_id, p_source_kind, p_source_ref, left(btrim(p_title), 200), p_detail, p_priority, v_blocks, 'open', v_key)
    on conflict (idempotency_key) do nothing returning id into v_id;
    v_created := v_id is not null;
    if v_id is null then select id into v_id from public.work_orders where idempotency_key = v_key; end if;
  end if;
  return jsonb_build_object('id', v_id, 'created', v_created, 'blocks_arrival', v_blocks,
    'next_guest', v_next.guest_name, 'next_checkin', v_next.checkin_date);
end $$;
revoke all on function public.raise_work_order_v1(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.raise_work_order_v1(uuid, text, text, text, text, text) to service_role;

create or replace function public.guest_context_v1(p_property_id uuid, p_guest_id uuid default null, p_name text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  g public.guests%rowtype; d public.guest_profile_details%rowtype; v_last record; v_issue record; v_out jsonb;
begin
  if p_guest_id is not null then
    select * into g from public.guests where id = p_guest_id and property_id = p_property_id;
  elsif p_name is not null and btrim(p_name) <> '' then
    select * into g from public.guests where property_id = p_property_id and name ilike btrim(p_name) order by total_stays desc nulls last limit 1;
    if g.id is null then
      select * into g from public.guests where property_id = p_property_id and name ilike btrim(p_name) || '%' order by total_stays desc nulls last limit 1;
    end if;
  end if;
  if g.id is null then return jsonb_build_object('found', false); end if;
  select * into d from public.guest_profile_details where guest_id = g.id;
  -- Most recent finished stay from either booking table.
  select checkin_date, checkout_date into v_last from (
    select checkin_date, checkout_date from public.airbnb_reservations where guest_id = g.id and status in ('completed', 'confirmed') and checkout_date <= public.manila_today()
    union all
    select checkin_date, checkout_date from public.booking_inquiries where guest_id = g.id and status in ('confirmed', 'completed') and checkout_date <= public.manila_today()
  ) s order by checkout_date desc limit 1;
  -- The cleaner records the guest's first name(s) only, so match on prefix of the full name.
  select c.cleaned_at::date as cleaned_on, substring(c.notes from '\[URGENT\]\s*([^\n|]+)') as issue into v_issue
    from public.cleaning_sessions c
   where c.property_id = p_property_id and c.notes ilike '%[URGENT]%'
     and c.notes not ilike '%duplicate submission%'
     and lower(g.name) like lower(btrim(c.last_guest_name)) || '%'
   order by c.cleaned_at desc limit 1;
  v_out := jsonb_strip_nulls(jsonb_build_object(
    'found', true, 'guest_id', g.id, 'name', g.name, 'tier', g.tier, 'total_stays', coalesce(g.total_stays, 0),
    'total_nights', g.total_nights_stayed, 'first_stay', g.first_stay_date,
    'last_stay_checkin', v_last.checkin_date, 'last_stay_checkout', v_last.checkout_date,
    'last_issue', nullif(btrim(v_issue.issue), ''), 'last_issue_on', v_issue.cleaned_on,
    'preferences', nullif(btrim(d.stay_preferences), ''), 'tags', case when d.tags is not null and array_length(d.tags, 1) > 0 then to_jsonb(d.tags) end,
    'vip_reason', case when d.vip then coalesce(nullif(btrim(d.vip_reason), ''), 'VIP') end,
    'note', nullif(btrim(g.notes), ''), 'birthday', d.birthday,
    'open_follow_ups', (select jsonb_agg(f.title order by f.due_at nulls last) from public.follow_up_tasks f where f.guest_id = g.id and f.status in ('open', 'in_progress'))
  ));
  return v_out;
end $$;
revoke all on function public.guest_context_v1(uuid, uuid, text) from public, anon;
grant execute on function public.guest_context_v1(uuid, uuid, text) to service_role, authenticated;

commit;
