-- 20261102000000_s99e_missed_cleanings.sql
-- Session 99e, lane SQL: release s99e_missed_and_pay_20261102, part 1.
-- BUG: get_missed_cleanings treated a cleaning session as covering a checkout when
--        cs.checkout_date = ce.checkout_date  OR  cs.cleaned_at::date between ce.checkout_date and ce.checkout_date + 1.
--   The second branch fired even for a session that names ANOTHER checkout. Live 2026-10-27: Honey filed her late reports for the 14 and 17 Oct checkouts
--   on 21 Oct 22:36 Manila, so the real 21 Oct checkout (no report) was hidden from get_missed_cleanings, from the cleaner's Pay screen ("No report yet"),
--   from the "Cleaning report missing" follow-up tasks, and staff_pay_admin_create_v2 / staff_pay_request_create_v2 refused it as advance_not_owed.
--   cleaned_at::date is also the UTC date, not the Manila date.
-- FIX: the date-window fallback applies ONLY to a session with no checkout_date, and uses the Manila date ((cleaned_at at time zone 'Asia/Manila')::date):
--   the rule s_advance_session_v1 (20261027000000_s94_pay_ahead.sql) and cleaning_sessions_link_advance_trg already use. A session that names a checkout
--   date covers exactly that checkout. Everything else is the live s91 body: signature, language, volatility, SECURITY INVOKER, search_path, the D-290
--   same-guest clause, the order.
-- Guard (55000, nothing changes): the live body must be the s91 body, md5(prosrc, CR stripped) ce6a29c3a3ad63ea4eef3e4eba410885.
-- Grants restated (ML-21): revoke all from public, anon; grant execute to authenticated and service_role (the live state: the 20261002 stay_chains notes say
--   authenticated may call it, the edge function missed-cleaning-alert calls it as service_role, the definer pay functions run as their owner).
-- Rollback: supabase/rollbacks/20261102_s99e_missed_cleanings.sql. After it, run supabase/sql/2026-10-27-s99e-honey-2700.sql (data step, Lloyd's block).

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.get_missed_cleanings(uuid,integer)');
  if v_got is distinct from 'ce6a29c3a3ad63ea4eef3e4eba410885' then
    raise exception 's99e: public.get_missed_cleanings(uuid,integer) is not the s91 body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

create or replace function public.get_missed_cleanings(p_property_id uuid default null::uuid, p_lookback integer default 14)
returns table(guest_name text, checkin_date date, checkout_date date, source text, days_overdue integer)
language plpgsql stable set search_path = '' as $body$
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
    and ce.status <> 'cancelled'
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
$body$;

revoke all on function public.get_missed_cleanings(uuid, integer) from public, anon;
grant execute on function public.get_missed_cleanings(uuid, integer) to authenticated, service_role;

commit;
