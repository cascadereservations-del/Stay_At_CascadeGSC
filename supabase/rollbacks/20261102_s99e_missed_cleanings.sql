-- Compensating rollback for release s99e_missed_and_pay_20261102 (migration 20261102000000_s99e_missed_cleanings.sql).
-- Puts back, byte for byte, the s91 body of public.get_missed_cleanings(uuid,integer): md5(prosrc, CR stripped) ce6a29c3a3ad63ea4eef3e4eba410885.
-- It refuses (55000, nothing changes) unless the live body is the s99e one (md5 def6d3ea1ae7c3c05bc2ae178df2d0aa).
-- NOT undone: the data step supabase/sql/2026-10-27-s99e-honey-2700.sql (a paid request, ledger rows, the corrected KitKat claim stay as they are).
-- After the rollback a late report filed on another checkout's day hides that checkout again (the bug this release fixed). Apply with run-sql-on-host.sh.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.get_missed_cleanings(uuid,integer)');
  if v_got is distinct from 'def6d3ea1ae7c3c05bc2ae178df2d0aa' then
    raise exception 's99e rollback: public.get_missed_cleanings(uuid,integer) is not the body the release installed (md5 %); somebody changed it since', v_got using errcode = '55000';
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
          -- filed a day late but clearly for this stay
          or cs.cleaned_at::date between ce.checkout_date and ce.checkout_date + 1
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
