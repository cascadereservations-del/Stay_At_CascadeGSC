-- 20260916100000_cleaning_photos_storage_read.sql (admin session 21)
-- storage.objects has RLS enabled but NO policy at all for the cleaning-photos
-- bucket, so every list()/read call from the admin dashboard (or anywhere else)
-- was silently denied for every role, admin included. This is the real reason
-- the cleaning-detail page's Photos section could never show anything beyond
-- the stored counts, independent of the client-side path bug fixed alongside
-- it (admin-dashboard app/src/features/operations/api.ts). Photos upload to
-- {propertyId}/{uploaderUserId}/{submissionId}/... (upload-photo/index.ts), so
-- the property id is the first path segment. Mirrors the existing
-- "guest id photos manage read" policy shape (current_staff_authorized keyed
-- off a path segment).
begin;

create policy cleaning_photos_ops_read on storage.objects for select to authenticated
using (
  bucket_id = 'cleaning-photos'
  and public.current_staff_authorized('read_operations', ((storage.foldername(name))[1])::uuid)
);

-- forward check: the policy exists and is scoped to the right bucket
do $$
begin
  if not exists (
    select 1 from pg_policy pol
    where pol.polname = 'cleaning_photos_ops_read'
      and pol.polrelid = 'storage.objects'::regclass
      and pg_get_expr(pol.polqual, pol.polrelid) ilike '%cleaning-photos%'
  ) then
    raise exception 'cleaning_photos_ops_read policy did not apply as expected';
  end if;
end $$;

commit;
