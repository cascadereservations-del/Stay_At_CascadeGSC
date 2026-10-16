-- s90 (#8): the abandoned checklist of 2026-10-14 06:51 Manila (folder 3c5fd5c9-f232-4032-925b-fa0ea6d54efd, property 6ae230f4) was a test:
-- all 9 "photos" (5 pre-clean, 2 meters, 2 kitchen) are screenshots of GitHub/social posts, none of the house (looked at 2026-10-16).
-- No cleaning, meter or diagnostics row references it; only 9 staff_upload_hashes rows do. The Storage files are deleted in the dashboard.
begin;
do $$
declare n int;
begin
  delete from public.staff_upload_hashes where path like '%/3c5fd5c9-f232-4032-925b-fa0ea6d54efd/%';
  get diagnostics n = row_count;
  if n <> 9 then raise exception 'expected 9 upload-hash rows, got %', n; end if;
end $$;
commit;
select 'abandoned checklist hashes removed: 9' as result;
