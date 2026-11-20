-- Session 129 (lane SQL): release s129_staying_companions_20261129. Who is staying follows the guest record (D-390): every active staff member sees the names of the people on the current and next
-- stay in the Staff app, not only owner and admin. Contract: docs/s129/CONTRACT-staying.md (SQL lane).
--
--   staff_guest_companions_v1(uuid)   the ONLY function replaced. The gate was a staff_access_profiles row for auth.uid() with role owner or admin and disabled_at null; it is now any row for auth.uid()
--                                     with disabled_at null (owner, admin, cleaner, laundry, inspector, finance, maintenance). Output shape, attributes and grants are unchanged:
--                                     {"companions":[{name, has_photo}]} ordered by created_at, id; '{}' for a null guest or a session with no active profile (anon, no profile, disabled).
--   staff_home_v1(uuid)               NOT replaced (live md5 b85530233f55696b136e4a49d1ed255c stays). It already calls this helper for current_guest and next_guest; the key companions is now present for every
--                                     active staff role instead of owner/admin only.
--
-- Money / privacy rule: a companion is only ever shown as staff_redact_v1(name) plus has_photo (a boolean). No ID type, no id_photo_path, no phone, no e-mail leaves this function.
-- The live body was read 2026-11-20 (md5 of the CR-stripped body in the guard below; the live body is stored with CR line endings); a DO block stops with 55000 when the live body is neither that original nor this release, so a re-run is safe.
-- Rollback: supabase/rollbacks/20261129_s129_staying_companions.sql (puts the owner/admin-only body back).

begin;

-- 1. guard: the live body this release replaces ------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = 'public.staff_guest_companions_v1(uuid)'::regprocedure;
  if v is distinct from 'ab34f947cec8caa410540216fd3b39f1' and v is distinct from 'f1dac1d94870fb2575343b796fb94485' then
    raise exception using errcode = '55000', message = 's129: public.staff_guest_companions_v1(uuid) is neither the expected live body nor this release (md5 ' || coalesce(v, 'null') || ')';
  end if;
end $g$;

-- 2. staff_guest_companions_v1: any active staff profile (the only change is the role list in the gate) ----------------------------------------------------------------------
create or replace function public.staff_guest_companions_v1(p_guest_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select case when p_guest_id is not null
               and exists (select 1 from public.staff_access_profiles p
                            where p.user_id = auth.uid() and p.disabled_at is null)
    then jsonb_build_object('companions', coalesce((
           select jsonb_agg(jsonb_build_object('name', public.staff_redact_v1(c.name), 'has_photo', c.id_photo_path is not null)
                            order by c.created_at, c.id)
             from public.guest_companions c where c.guest_id = p_guest_id), '[]'::jsonb))
    else '{}'::jsonb end;
$$;

-- 3. grants restated: internal helper, staff_home_v1 (its owner) is the only caller; no API role -----------------------------------------------------------------------------
revoke all on function public.staff_guest_companions_v1(uuid) from public, anon, authenticated, service_role;

-- 4. staff_home_v1 comment restated truthfully (COMMENT does not change prosrc, so the md5 guards stay valid)
comment on function public.staff_home_v1(uuid) is
  'Cascade Staff home (SPEC-36, S77, D-319, S82): calendar with block_reason/block_label, day_flags, current/next guest with returning marker and notes, open system-check warnings with key/acknowledged/facts, weather. Owner and admin sessions also get the current/next guest phone, e-mail and Messenger thread and arrival_ready {id, paid, door_code} on every upcoming or in-house stay; never money; cleaners and other roles never get contact details or arrival_ready (D-289). Every active staff role gets companions on the current and next guest (name and has_photo only, names redacted; S129, D-390).';

commit;
