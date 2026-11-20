-- Rollback of s129_staying_companions_20261129: puts the owner/admin-only body of staff_guest_companions_v1 back (the 20261009040000 body, live md5 ab34f947cec8caa410540216fd3b39f1 CR-stripped).
-- staff_home_v1 is untouched by both directions. Cleaners and the other staff roles lose the companions key on current_guest and next_guest (the Staff app then shows the booker / typed names only).
-- Guarded the other way round: stops with 55000 when the live body is neither this release's body nor the original. Grants restated as they were.
begin;

do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = 'public.staff_guest_companions_v1(uuid)'::regprocedure;
  if v is distinct from 'f1dac1d94870fb2575343b796fb94485' and v is distinct from 'ab34f947cec8caa410540216fd3b39f1' then
    raise exception using errcode = '55000', message = 's129 rollback: public.staff_guest_companions_v1(uuid) is neither the expected live body nor this release (md5 ' || coalesce(v, 'null') || ')';
  end if;
end $g$;

create or replace function public.staff_guest_companions_v1(p_guest_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select case when p_guest_id is not null
               and exists (select 1 from public.staff_access_profiles p
                            where p.user_id = auth.uid() and p.role in ('owner','admin') and p.disabled_at is null)
    then jsonb_build_object('companions', coalesce((
           select jsonb_agg(jsonb_build_object('name', public.staff_redact_v1(c.name), 'has_photo', c.id_photo_path is not null)
                            order by c.created_at, c.id)
             from public.guest_companions c where c.guest_id = p_guest_id), '[]'::jsonb))
    else '{}'::jsonb end;
$$;
revoke all on function public.staff_guest_companions_v1(uuid) from public, anon, authenticated, service_role;

-- staff_home_v1 comment back to the s82 text
comment on function public.staff_home_v1(uuid) is
  'Cascade Staff home (SPEC-36, S77, D-319, S82): calendar with block_reason/block_label, day_flags, current/next guest with returning marker and notes, open system-check warnings with key/acknowledged/facts, weather. Owner and admin sessions also get the current/next guest phone, e-mail and Messenger thread, companions (name, has_photo) and arrival_ready {id, paid, door_code} on every upcoming or in-house stay; never money; cleaners and other roles never get contact details, companions or arrival_ready (D-289).';

commit;
