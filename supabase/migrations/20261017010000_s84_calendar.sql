-- Session 84 (lane C): release s84_calendar_20261017.
-- 1. PRIVACY FIX. public.admin_stays_v1(uuid) is SECURITY DEFINER with no role check and EXECUTE for `authenticated`, so any signed-in
--    staff session (a cleaner included) could read every booking's guest name, accommodation total and host payout (verified live
--    2026-10-14). It now refuses a session that is not owner/admin (manage_operations) or finance (read_finance, aal2). Why those two:
--    the functions that call it (get_hospitality_metrics_v1, get_admin_overview_v1, get_guest_timeline_v1, run_health_checks_v1,
--    get_report_drilldown_v1) already gate on read_operations / manage_operations and show money only to finance_human_authorized;
--    the Manage screen and the admin dashboard are the only clients and are owner/admin (finance reads the dashboard). A cleaner,
--    inspector or maintenance session can no longer reach the stays set directly OR through those functions' stay reads.
--    A caller with no JWT (auth.uid() is null: the postgres owner, a cron job or another definer function run by it) is let through;
--    anon and service_role hold no EXECUTE on admin_stays_v1 (revoked in 20260913100000), so that branch is not reachable from the API.
--    The Edge Functions do NOT call admin_stays_v1: cascade-core/tools.ts reads the two booking tables with the service key (see its
--    header comment), so that path is untouched.
--    The SQL body of admin_stays_v1 is kept byte-for-byte (live md5 e2f41dcc6de28ba1ebe23b4534b6443d, CR stripped, read 2026-10-14, equal to
--    the body in 20260913100000_admin_read_models_v1.sql); it is wrapped as a subselect behind a one-row gate. Signature, return
--    columns, language, security mode, search_path and grants are unchanged.
-- 2. New read RPC staff_calendar_history_v1(p_from, p_to, p_property_id): owner/admin only, past (and any) stays overlapping the range,
--    from the same set, with source, id, dates, nights, status and the guest FIRST NAME only. No contact, no money.
begin;

do $stop$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.admin_stays_v1(uuid)'::regprocedure) <> 'e2f41dcc6de28ba1ebe23b4534b6443d' then
    raise exception 'STOP: public.admin_stays_v1 changed in production since s84 lane C was written (md5 e2f41dcc6de28ba1ebe23b4534b6443d); re-read production and re-vendor before applying';
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
  select s.* from (select public.admin_stays_gate_v1(p_property_id)) g,
  lateral (
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
  ) s;
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

commit;
