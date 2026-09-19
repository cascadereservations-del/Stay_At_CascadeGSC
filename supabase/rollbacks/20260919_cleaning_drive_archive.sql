-- Compensating rollback for 20260919010000_cleaning_drive_archive.sql.
-- Drops the two added columns. The Drive ids they held are lost from the database but NOT from Drive
-- (the photos and the e-mail are untouched), and the Supabase Storage copies are untouched because phase 1
-- deletes nothing. session_folder_id pre-dates this release and is left as it is.
-- Deploy the previous submit-cleaning FIRST, or its update of drive_files starts failing (logged, non-fatal).
begin;

alter table public.cleaning_sessions drop constraint if exists cleaning_sessions_drive_files_is_array;
alter table public.cleaning_sessions drop column if exists drive_files;
alter table public.cleaning_sessions drop column if exists session_folder_url;

commit;
