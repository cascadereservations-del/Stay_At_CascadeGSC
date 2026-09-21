-- 20260921000000_meter_followup_resolution.sql
-- Cascade Hideaway · the graduated meter-mismatch alert, database half.
--
-- Why this exists. `meter_readings.vision_resolved_at` has been declared since
-- 2026-09-13 and read by get_meter_photo_followups ever since, but NOTHING has
-- ever written it. The follow-up card the cleaner sees at sign-in therefore had
-- no way to end: its "I have dealt with it" button only hid the box in her
-- browser, and the next sign-in raised the same report again.
--
-- That was harmless while the card was advisory. It stops being harmless the
-- moment an unresolved mismatch blocks the next turnover, which is what Lloyd
-- asked for on 2026-09-20 (mirror the alert to Finance, ask for a re-upload,
-- block only if it is still unresolved). A block with no exit traps the cleaner
-- in the unit. So the exit is built first, and it is on the record: who cleared
-- it, when, and what they said they did.
--
-- Additive only. Two nullable columns and one new function. Nothing existing
-- changes. There are ZERO 'mismatch' rows in production today (13 ok, 1
-- unreadable, 48 unchecked, verified 2026-09-21), so nobody is blocked by the
-- act of applying this.

alter table public.meter_readings
  add column if not exists vision_resolved_by   uuid,
  add column if not exists vision_resolved_note text;

comment on column public.meter_readings.vision_resolved_by is
  'auth.uid() of the staff member who answered the meter follow-up. NULL until someone does.';
comment on column public.meter_readings.vision_resolved_note is
  'What they said they did about it, in their own words. Recorded so a cleared block is never a silent one.';

-- Answer a meter follow-up, on the record.
--
-- Gated on 'submit_cleaning' rather than 'read_operations': the person who
-- submits the cleaning is the person who answers for its meter photo, and that
-- is the narrowest role that must be able to clear its own block (cleaner,
-- inspector, admin, owner — never finance, never maintenance).
--
-- Idempotent. A second tap returns already_resolved rather than moving the
-- timestamp, so a double tap cannot rewrite who cleared it.
create or replace function public.resolve_meter_followup_v1(
  p_session_id uuid,
  p_answer     text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_property uuid;
  v_has_row  boolean;
  v_answer   text := nullif(btrim(coalesce(p_answer, '')), '');
begin
  if v_answer is null or length(v_answer) > 300 then
    raise exception 'an answer of 1 to 300 characters is required'
      using errcode = '22023';
  end if;

  select cs.property_id into v_property
  from public.cleaning_sessions cs
  where cs.id = p_session_id;

  if v_property is null then
    raise exception 'unknown cleaning session' using errcode = '22023';
  end if;

  if not public.current_staff_authorized('submit_cleaning', v_property) then
    raise exception 'not authorized to resolve meter follow-ups for this property'
      using errcode = '42501';
  end if;

  -- A session whose meter photos were SKIPPED can have no meter_readings row at
  -- all, and get_meter_photo_followups raises those too. There is nothing to
  -- stamp, so say so plainly instead of reporting a resolution that did not
  -- happen. Only a 'mismatch' ever blocks, and a mismatch always has a row.
  select exists (
    select 1 from public.meter_readings mr where mr.session_id = p_session_id
  ) into v_has_row;

  if not v_has_row then
    return jsonb_build_object('ok', true, 'outcome', 'no_reading_row');
  end if;

  update public.meter_readings mr
     set vision_resolved_at   = now(),
         vision_resolved_by   = auth.uid(),
         vision_resolved_note = v_answer
   where mr.session_id = p_session_id
     and mr.vision_resolved_at is null;

  if not found then
    return jsonb_build_object('ok', true, 'outcome', 'already_resolved');
  end if;

  return jsonb_build_object('ok', true, 'outcome', 'resolved');
end;
$function$;

revoke all on function public.resolve_meter_followup_v1(uuid, text) from public, anon;
grant execute on function public.resolve_meter_followup_v1(uuid, text) to authenticated;

comment on function public.resolve_meter_followup_v1(uuid, text) is
  'Answer a meter photo follow-up and lift the block it carries. submit_cleaning role required; records who, when and what they said. Idempotent.';
