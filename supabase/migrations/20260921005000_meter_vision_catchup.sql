-- 20260921005000_meter_vision_catchup.sql
-- CATCH-UP, not a change. Written 2026-09-21.
--
-- The meter-photo vision schema has been live in production since 2026-09-13,
-- applied by hand from CH-Cleaners-Checklist/sql/2026-09-13-meter-vision-and-photo-skip.sql
-- through run-sql-on-host.sh. It was never recorded as a stay-site migration,
-- so CI's baseline database has never had any of it, and no pgTAP could touch
-- it. That gap surfaced when supabase/tests/database/meter_followup_resolution.sql
-- died on CI with 'column vision_electric of relation meter_readings does not
-- exist' while passing every forward check against production.
--
-- Every statement here is idempotent and this migration is a NO-OP against
-- production. The function body below was verified byte-identical to the
-- deployed one on 2026-09-21 by comparing md5(prosrc): 68844a6d99f94ab7c410f4d55806ee19,
-- 1233 bytes, on both sides. Do not reformat it; that comparison is the only
-- thing making this safe to re-run on a live database.
--
-- Deliberately partial. This carries exactly what production has that the test
-- suite needs: the two column sets and get_meter_photo_followups. The rest of
-- the 2026-09-13 file (can_skip_meter_photos, get_meter_sessions_pending_vision,
-- get_meter_photo_objects) is still outside the migration history and still
-- untestable in CI. That is a known gap, recorded rather than quietly widened.

alter table public.meter_readings
  add column if not exists vision_electric    numeric,
  add column if not exists vision_water       numeric,
  add column if not exists vision_confidence  numeric,
  -- ok | mismatch | unreadable | not_a_meter | error
  add column if not exists vision_verdict     text,
  add column if not exists vision_checked_at  timestamptz,
  add column if not exists vision_raw         jsonb,
  -- Set once the cleaner has re-uploaded, so the sign-in nudge stops asking.
  add column if not exists vision_resolved_at timestamptz;

alter table public.cleaning_sessions
  add column if not exists meter_photos_skipped   boolean not null default false,
  add column if not exists meter_photo_skip_note  text;

-- Read at sign-in. Returns recent sessions whose meter photos were skipped, or
-- whose vision check disagreed with the typed reading, and which nobody has
-- since put right.
create or replace function public.get_meter_photo_followups(
  p_property_id uuid    default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid,
  p_lookback    integer default 14
)
returns table (
  session_id      uuid,
  submission_id   text,
  cleaned_at      timestamptz,
  cleaner_name    text,
  reason          text,
  typed_electric  numeric,
  typed_water     numeric,
  vision_electric numeric,
  vision_water    numeric,
  vision_verdict  text
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'not authorized to read operations for this property'
      using errcode = '42501';
  end if;

  return query
  select
    cs.id,
    cs.submission_id,
    cs.cleaned_at,
    cs.cleaner_name,
    case
      when cs.meter_photos_skipped              then 'no meter photos were attached'
      when mr.vision_verdict = 'mismatch'       then 'the photo does not show the number that was typed'
      when mr.vision_verdict = 'not_a_meter'    then 'the photo does not look like a meter'
      when mr.vision_verdict = 'unreadable'     then 'the photo could not be read'
      else 'needs another look'
    end,
    mr.electric_curr,
    mr.water_curr,
    mr.vision_electric,
    mr.vision_water,
    mr.vision_verdict
  from public.cleaning_sessions cs
  left join public.meter_readings mr on mr.session_id = cs.id
  where cs.property_id = p_property_id
    and cs.cleaned_at >= (now() - make_interval(days => greatest(p_lookback, 1)))
    and mr.vision_resolved_at is null
    and (
      cs.meter_photos_skipped
      or mr.vision_verdict in ('mismatch', 'not_a_meter', 'unreadable')
    )
  order by cs.cleaned_at desc;
end;
$function$;

revoke all on function public.get_meter_photo_followups(uuid, integer) from public;
grant execute on function public.get_meter_photo_followups(uuid, integer) to authenticated;

comment on function public.get_meter_photo_followups(uuid, integer) is
  'Recent sessions whose meter photos were skipped or failed the vision check and have not been put right. Read at sign-in so the app can ask for a re-upload.';
