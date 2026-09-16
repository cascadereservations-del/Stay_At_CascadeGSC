-- 20260916110000_cleaning_photos_storage_read_fix.sql (admin session 21, follow-up)
-- The cleaning_photos_ops_read policy applied by 20260916100000 crashes instead of
-- denying: cleaning-photos also holds objects under a legacy path scheme whose
-- first folder segment is a plain date ("2026-07-25", not a property uuid) --
-- confirmed live, dozens of distinct date-shaped segments exist in the same
-- bucket. Postgres does not guarantee left-to-right AND short-circuit for RLS
-- quals, so ((storage.foldername(name))[1])::uuid can be evaluated against a
-- legacy row and throw invalid_text_representation, which aborts the whole
-- list() call with a 400 instead of just excluding that row. try_uuid() makes
-- the cast crash-safe; current_staff_authorized(_, null) returns false, which
-- correctly denies (not crashes on) any row under the legacy scheme.
begin;

create or replace function public.try_uuid(p_text text) returns uuid
language plpgsql immutable as $$
begin
  return p_text::uuid;
exception when invalid_text_representation then
  return null;
end;
$$;

alter policy cleaning_photos_ops_read on storage.objects
using (
  bucket_id = 'cleaning-photos'
  and public.current_staff_authorized('read_operations', public.try_uuid((storage.foldername(name))[1]))
);

-- forward check: listing a real property folder no longer throws
do $$
declare v_ok boolean;
begin
  begin
    perform 1 from storage.objects
    where bucket_id = 'cleaning-photos'
      and public.current_staff_authorized('read_operations', public.try_uuid((storage.foldername(name))[1]));
    v_ok := true;
  exception when invalid_text_representation then
    v_ok := false;
  end;
  if not v_ok then
    raise exception 'cleaning_photos_ops_read still crashes on a legacy-path row';
  end if;
end $$;

commit;
