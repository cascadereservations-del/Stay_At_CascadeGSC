
-- Allow anon to upload and read cleaning photos
-- (checklist app uses anon key — no auth)
create policy "anon upload cleaning photos"
  on storage.objects for insert
  to anon
  with check (bucket_id = 'cleaning-photos');

create policy "anon read cleaning photos"
  on storage.objects for select
  to anon
  using (bucket_id = 'cleaning-photos');

create policy "authenticated all cleaning photos"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'cleaning-photos');
;
