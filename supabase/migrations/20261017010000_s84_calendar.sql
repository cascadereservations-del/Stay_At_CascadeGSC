-- Session 84 (lane C): release s84_calendar_20261017.
-- 1. PRIVACY FIX. public.admin_stays_v1(uuid) is SECURITY DEFINER with no role check and EXECUTE for `authenticated`, so any signed-in
--    staff session (a cleaner included) could read every booking's guest name, accommodation total and host payout (verified live
--    2026-10-14). It now refuses a session that is not owner/admin (manage_operations) or finance (read_finance, aal2). Why those two:
--    the functions that call it (get_hospitality_metrics_v1, get_admin_overview_v1, get_guest_timeline_v1,
--    get_report_drilldown_v1) already gate on read_operations / manage_operations and show money only to finance_human_authorized;
--    the Manage screen and the admin dashboard are the only clients and are owner/admin (finance reads the dashboard). A cleaner,
--    inspector or maintenance session can no longer reach the stays set directly OR through those functions' stay reads.
--    A caller with no JWT (auth.uid() is null: the postgres owner, a cron job or another definer function run by it) is let through;
--    anon and service_role hold no EXECUTE on admin_stays_v1 (revoked in 20260913100000), so that branch is not reachable from the API.
--    The Edge Functions do NOT call admin_stays_v1: cascade-core/tools.ts reads the two booking tables with the service key (see its
--    header comment), so that path is untouched.
--    The SQL body of admin_stays_v1 is kept byte-for-byte (live md5 e2f41dcc6de28ba1ebe23b4534b6443d, CR stripped, read 2026-10-14, equal to
--    the body in 20260913100000_admin_read_models_v1.sql); it is filtered by the gate in a top-level WHERE (a qual is never dropped by the planner; a one-row FROM subselect would be). Signature, return
--    columns, language, security mode, search_path and grants are unchanged.
-- 3. staff_pay_admin_step_v1 (live md5 ee76bfac5542808058969b731940f343 = the body in 20261014010000_s81_staff_pay_push.sql, the only migration
--    that defines it): it refused 'not_sent' on a payment another admin is making but not 'cancel', so an admin on a stale screen could cancel
--    a request a second admin had taken over and was paying. One new guard beside the not_sent one: cancel on a paying row whose payer is not
--    the caller returns {ok:false, reason:'not_yours'}. Everything else is the live body byte-for-byte. Signature, return type, security mode,
--    search_path and grants unchanged. Cancelling your own payment, or a request that is only 'requested', works as before.
--    Note: a row Telegram started (paying_by_user_id null) is now also 'not_yours' for a cancel from the app; cancel it from Telegram or take it over first.
-- 2. New read RPC staff_calendar_history_v1(p_from, p_to, p_property_id): owner/admin only, past (and any) stays overlapping the range,
--    from the same set, with source, id, dates, nights, status and the guest FIRST NAME only. No contact, no money.
-- 4. calendar_events contact columns (found 2026-10-14, live): `authenticated` held table-level SELECT, and calendar_events_staff_read admits every
--    role with read_operations, so a cleaner could read guest_phone, raw_summary and raw_description over PostgREST. Fix: the two owner/admin RPCs
--    below serve the only two direct readers that need those columns (admin-dashboard features/bookings/api.ts fetchStays: raw_summary;
--    fetchStayDetail: select '*'), then SELECT is restricted to every column EXCEPT guest_phone, raw_summary and raw_description. guest_name stays
--    (get_booking_for_date and the cleaning checklist's stay picker show it). Other readers: the checklist's direct select (checkin_date, checkout_date,
--    nights, status, block_reason, block_reason_source) and the dashboard insights select (checkin_date, checkout_date) are unaffected; every Edge
--    Function reads with the service role (its own table grant is untouched). Four SECURITY INVOKER SQL functions name one of the three columns
--    (check_availability: raw_summary; stay_same_guest_v1: raw_description, guest_phone; and, through it, stay_continues_v1 / stay_chains_v1 /
--    get_missed_cleanings): they are called only by Edge Functions (service role) and by definer functions, never by a user JWT, so they keep working;
--    a direct call by a signed-in staff session now fails closed. A column added to the table later is NOT granted until someone grants it.
begin;

do $stop$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.admin_stays_v1(uuid)'::regprocedure) <> 'e2f41dcc6de28ba1ebe23b4534b6443d' then
    raise exception 'STOP: public.admin_stays_v1 changed in production since s84 lane C was written (md5 e2f41dcc6de28ba1ebe23b4534b6443d); re-read production and re-vendor before applying';
  end if;
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.staff_pay_admin_step_v1(uuid,text)'::regprocedure) <> 'ee76bfac5542808058969b731940f343' then
    raise exception 'STOP: public.staff_pay_admin_step_v1 changed in production since s84 lane C was written (md5 ee76bfac5542808058969b731940f343); re-read production and re-vendor before applying';
  end if;
  if (select array_agg(attname::text order by attname::text) from pg_attribute where attrelid = 'public.calendar_events'::regclass and attnum > 0 and not attisdropped)
     is distinct from (select array_agg(c order by c) from unnest(string_to_array('id,property_id,uid,source,checkin_date,checkout_date,nights,guest_name,guest_phone,status,raw_summary,raw_description,synced_at,created_at,updated_at,checkin_time,checkout_time,linked_reservation_id,recon_status,recon_alerted_at,block_reason,block_reason_source,block_note,block_answered_by,block_answered_at', ',')) c) then
    raise exception 'STOP: public.calendar_events columns changed in production since s84 lane C was written; re-read the column list and re-vendor the grant before applying';
  end if;
end;
$stop$;

-- The gate. Not callable by any API role: admin_stays_v1 (SECURITY DEFINER, owner postgres) runs it with its owner's rights.
create or replace function public.admin_stays_gate_v1(p_property_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return true;
  end if;
  if public.current_staff_authorized('manage_operations', p_property_id)
     or public.current_staff_authorized('read_finance', p_property_id) then
    return true;
  end if;
  raise exception using errcode = '42501', message = 'not_authorized';
end;
$$;
revoke all on function public.admin_stays_gate_v1(uuid) from public, anon, authenticated, service_role;

create or replace function public.admin_stays_v1(p_property_id uuid)
returns table (
  stay_kind text, stay_id uuid, code text, guest_id uuid, guest_name text,
  checkin date, checkout date, nights integer, status text,
  accommodation_total numeric, allocation_method text, booking_created date, payout_date date, host_payout numeric
) language sql stable security definer set search_path = '' as $$
  select s.* from (
  select 'airbnb', r.id, r.confirmation_code, r.guest_id, r.guest_name, r.checkin_date, r.checkout_date,
         (r.checkout_date - r.checkin_date), r.status,
         case
           when t.gross_earnings is not null then round(t.gross_earnings - coalesce(t.cleaning_fee, 0), 2)
           when r.host_payout is not null then round(r.host_payout + coalesce(r.host_service_fee, 0), 2)
           else null end,
         case
           when t.gross_earnings is not null then 'airbnb_transactions_gross_less_cleaning'
           when r.host_payout is not null then 'host_payout_plus_host_fee'
           else 'missing' end,
         t.booking_date, r.payout_date, r.host_payout
  from public.airbnb_reservations r
  left join lateral (
    select max(x.gross_earnings) gross_earnings, max(x.cleaning_fee) cleaning_fee, min(x.booking_date) booking_date
    from public.airbnb_transactions x
    where x.property_id = r.property_id and x.confirmation_code = r.confirmation_code and x.row_type = 'reservation'
  ) t on true
  where r.property_id = p_property_id and r.checkin_date is not null and r.checkout_date is not null
  union all
  select 'direct', i.id, 'DIR-' || upper(left(i.id::text, 8)), i.guest_id, i.guest_name, i.checkin_date, i.checkout_date,
         (i.checkout_date - i.checkin_date),
         case when i.status in ('confirmed','completed') then i.status when i.status in ('cancelled','declined') then 'cancelled' else 'inquiry' end,
         i.total_amount, case when i.total_amount is not null then 'direct_quoted_total' else 'missing' end,
         i.submitted_at::date, null, null
  from public.booking_inquiries i
  where i.property_id = p_property_id
  ) s
  where public.admin_stays_gate_v1(p_property_id);
$$;
revoke all on function public.admin_stays_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_stays_v1(uuid) to authenticated;

-- Staff-app calendar history. p_from and p_to are both inclusive days; a stay is returned when it overlaps [p_from, p_to].
create or replace function public.staff_calendar_history_v1(
  p_from        date,
  p_to          date,
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('manage_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not_authorized';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception using errcode = '22023', message = 'bad_range';
  end if;
  if p_to - p_from > 400 then
    raise exception using errcode = '22023', message = 'range_too_large';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', x.stay_kind,
           'id', x.stay_id,
           'checkin', x.checkin,
           'checkout', x.checkout,
           'nights', x.nights,
           'status', x.status,
           'first_name', nullif(split_part(btrim(coalesce(x.guest_name, '')), ' ', 1), '')
         ) order by x.checkin, x.checkout, x.stay_id), '[]'::jsonb)
    into v_rows
    from public.admin_stays_v1(p_property_id) x
   where x.status in ('confirmed', 'completed')
     and x.checkin <= p_to and x.checkout > p_from;
  return jsonb_build_object('from', p_from, 'to', p_to, 'stays', v_rows);
end;
$$;
revoke all on function public.staff_calendar_history_v1(date, date, uuid) from public, anon, service_role;
grant execute on function public.staff_calendar_history_v1(date, date, uuid) to authenticated;

create or replace function public.staff_pay_admin_step_v1(p_request_id uuid, p_step text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_name text; v_r public.staff_pay_requests%rowtype; v_res jsonb;
begin
  if v_uid is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if p_step not in ('pay', 'sent', 'takeover', 'not_sent', 'cancel') then return jsonb_build_object('ok', false, 'reason', 'bad_step'); end if;
  select * into v_r from public.staff_pay_requests where id = p_request_id and property_id = c_prop for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Finance')
    into v_name from auth.users u where u.id = v_uid;
  v_name := left(coalesce(v_name, 'Finance'), 30);

  if p_step = 'pay' and v_r.status = 'paying' and v_r.paying_by_user_id = v_uid then -- opening my own payment again
    return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid);
  end if;
  if p_step = 'sent' then -- the payer has scanned, copied or saved: from now on a take-over or a Telegram cancel is refused (money_may_be_sent)
    if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;
    if v_r.paying_by_user_id is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_yours', 'status', v_r.status, 'ref', v_r.ref, 'paying_by_name', v_r.paying_by_name); end if;
    update public.staff_pay_requests set sent_said_at = coalesce(sent_said_at, now()) where id = v_r.id;
    return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid, 'sent', true);
  end if;
  if p_step = 'takeover' then -- "I am paying it instead": only while nobody has said the money was sent
    if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;
    if v_r.paying_by_user_id = v_uid then return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid); end if;
    if v_r.sent_said_at is not null or v_r.proof_file_unique_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'money_may_be_sent', 'status', v_r.status, 'ref', v_r.ref);
    end if;
    perform set_config('cascade.audit_reason', 'staff pay ' || v_r.ref || ' taken over from ' || coalesce(v_r.paying_by_name, 'Telegram') || ' by ' || v_name, true);
    update public.staff_pay_requests set paying_by_user_id = v_uid, paying_by_tg = null, paying_by_name = v_name, paying_at = now() where id = v_r.id;
    return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid, 'took_over_from', v_r.paying_by_name);
  end if;
  if p_step = 'not_sent' and v_r.status = 'paying' and v_r.paying_by_user_id is distinct from v_uid then -- unpay is for my own paying state only
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'status', v_r.status, 'ref', v_r.ref, 'paying_by_name', v_r.paying_by_name);
  end if;
  if p_step = 'cancel' and v_r.status = 'paying' and v_r.paying_by_user_id is distinct from v_uid then -- s84: cancel is for my own paying state only (a stale screen must not cancel someone else's payment)
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'status', v_r.status, 'ref', v_r.ref, 'paying_by_name', v_r.paying_by_name);
  end if;

  v_res := public.telegram_staff_pay_step_v1(p_request_id, p_step, null, v_name, null);
  if coalesce((v_res ->> 'ok')::boolean, false) then
    if p_step = 'pay' then update public.staff_pay_requests set paying_by_user_id = v_uid where id = v_r.id; v_res := v_res || jsonb_build_object('paying_by_user_id', v_uid);
    else update public.staff_pay_requests set paying_by_user_id = null where id = v_r.id; end if;
  end if;
  return v_res;
end $$;
revoke all on function public.staff_pay_admin_step_v1(uuid, text) from public, anon, service_role;
grant execute on function public.staff_pay_admin_step_v1(uuid, text) to authenticated;

-- Owner/admin reads of calendar_events columns that `authenticated` no longer holds.
create or replace function public.admin_calendar_event_v1(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_prop uuid;
  v_row  jsonb;
begin
  select to_jsonb(ce) into v_row from public.calendar_events ce where ce.id = p_id;
  v_prop := coalesce((v_row ->> 'property_id')::uuid, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid);
  if auth.uid() is null or not public.current_staff_authorized('manage_operations', v_prop) then
    raise exception using errcode = '42501', message = 'not_authorized';
  end if;
  return v_row; -- null when the id does not exist
end;
$$;
revoke all on function public.admin_calendar_event_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_calendar_event_v1(uuid) to authenticated;

create or replace function public.admin_calendar_events_v1(p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not public.current_staff_authorized('manage_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not_authorized';
  end if;
  -- the columns and order admin-dashboard fetchStays selects today, including raw_summary
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id, 'uid', x.uid, 'source', x.source, 'checkin_date', x.checkin_date, 'checkout_date', x.checkout_date,
             'guest_name', x.guest_name, 'status', x.status, 'linked_reservation_id', x.linked_reservation_id,
             'synced_at', x.synced_at, 'raw_summary', x.raw_summary) order by x.checkin_date desc, x.id)
      from (select * from public.calendar_events ce where ce.property_id = p_property_id order by ce.checkin_date desc, ce.id limit 1000) x
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.admin_calendar_events_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_calendar_events_v1(uuid) to authenticated;

-- The restriction. Every column except guest_phone, raw_summary, raw_description.
revoke select on public.calendar_events from authenticated;
grant select (id, property_id, uid, source, checkin_date, checkout_date, nights, guest_name, status, synced_at, created_at, updated_at, checkin_time, checkout_time, linked_reservation_id, recon_status, recon_alerted_at, block_reason, block_reason_source, block_note, block_answered_by, block_answered_at) on public.calendar_events to authenticated;

commit;
