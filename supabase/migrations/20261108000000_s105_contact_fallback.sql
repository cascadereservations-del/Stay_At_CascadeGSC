-- s105 (Lloyd 2026-10-31): the Today card's tap-to-call shows the number staff saved on the guest page.
-- staff_guest_contact_v1 read only guests.phone_e164 / guests.phone, but the admin dashboard's Edit profile
-- saves guest_profile_details.contact_number (36 guests have a number only there, 7 in guests.phone).
-- Change: phone = first non-blank of guests.phone_e164, guests.phone, guest_profile_details.contact_number.
-- Everything else is the live body verbatim (calendar_day_flags 20261008120000): same owner/admin gate,
-- same e-mail and Messenger keys, same grants (none; only staff_home_v1, a definer, calls it).

do $guard$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc
       where oid = 'public.staff_guest_contact_v1(uuid)'::regprocedure) <> 'fa16d92c8d608b945e06cd5627ecc399' then
    raise exception 's105: live staff_guest_contact_v1 differs from the reviewed body; stop and re-read it';
  end if;
end
$guard$;

create or replace function public.staff_guest_contact_v1(p_guest_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select case when exists (select 1 from public.staff_access_profiles p
                            where p.user_id = auth.uid() and p.role in ('owner','admin') and p.disabled_at is null)
    then jsonb_build_object(
      'phone', (select coalesce(nullif(btrim(g.phone_e164), ''), nullif(btrim(g.phone), ''), nullif(btrim(d.contact_number), ''))
                  from (select 1) o
                  left join public.guests g on g.id = p_guest_id
                  left join public.guest_profile_details d on d.guest_id = p_guest_id),
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
