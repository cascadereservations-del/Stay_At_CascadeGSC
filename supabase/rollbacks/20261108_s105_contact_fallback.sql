-- Rollback for s105_contact_fallback_20261108: restores staff_guest_contact_v1 as defined in 20261008120000_calendar_day_flags.sql.
create or replace function public.staff_guest_contact_v1(p_guest_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select case when exists (select 1 from public.staff_access_profiles p
                            where p.user_id = auth.uid() and p.role in ('owner','admin') and p.disabled_at is null)
    then jsonb_build_object(
      'phone', (select coalesce(g.phone_e164, g.phone) from public.guests g where g.id = p_guest_id),
      'email', (select g.email from public.guests g where g.id = p_guest_id),
      'messenger', (select jsonb_build_object('psid', m.psid, 'thread_url', m.link)
                      from (select coalesce(nullif(btrim(d.messenger_psid), ''),
                                            (select t.psid from public.concierge_threads t
                                              where t.booking_flow->>'booking_id' in (select b.id::text from public.booking_inquiries b where b.guest_id = p_guest_id)
                                              order by t.updated_at desc limit 1)) as psid,
                                   case when btrim(d.messenger_link) ~ '^https://' then btrim(d.messenger_link) end as link
                              from (select 1) o left join public.guest_profile_details d on d.guest_id = p_guest_id) m
                     where m.psid is not null or m.link is not null))
    else '{}'::jsonb end;
$$;
revoke all on function public.staff_guest_contact_v1(uuid) from public, anon, authenticated, service_role;
