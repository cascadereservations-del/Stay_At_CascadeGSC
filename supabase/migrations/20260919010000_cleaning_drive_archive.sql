-- SPEC-15 phase 1 (session 38, D-197): where Drive put each cleaning's photos.
-- session_folder_id already exists and has been null on every row (41 of 41, 2026-09-19); the spec
-- assumed session_folder_url existed too, it does not, so it is added here. drive_files holds the
-- per-file list Code.gs v3.10 returns: [{section, name, fileId, url}]. null = not known (older
-- Code.gs, or never matched), which is NOT the same as [] (known to have no files).
-- Additive only: two nullable columns and one CHECK on the new column. Nothing reads them yet
-- except submit-cleaning (write) and, after this release, resend-cleaning-report and the dashboard.
begin;

alter table public.cleaning_sessions add column if not exists session_folder_url text;
alter table public.cleaning_sessions add column if not exists drive_files jsonb;

alter table public.cleaning_sessions drop constraint if exists cleaning_sessions_drive_files_is_array;
alter table public.cleaning_sessions add constraint cleaning_sessions_drive_files_is_array
  check (drive_files is null or jsonb_typeof(drive_files) = 'array');

comment on column public.cleaning_sessions.session_folder_url is
  'Drive folder of this report (Code.gs response folderUrl). SPEC-15.';
comment on column public.cleaning_sessions.drive_files is
  'Drive copy of each photo: [{section,name,fileId,url}] from Code.gs v3.10+. null = unknown, [] = none. SPEC-15.';

commit;
