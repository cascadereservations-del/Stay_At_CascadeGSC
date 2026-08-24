-- Receipt evidence is sensitive payment data. The browser may never write to
-- or read from this bucket directly; only the receipt Edge Function uses the
-- service role after validating a short-lived booking-scoped claim.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'booking-receipts',
  'booking-receipts',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Remove any historic anonymous object policies specifically scoped to this
-- bucket. Existing policies for other Storage buckets are deliberately left
-- intact.
do $$
declare
  receipt_policy record;
begin
  for receipt_policy in
    select policyname
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and roles @> array['anon']::name[]
      and (coalesce(qual, '') like '%booking-receipts%'
        or coalesce(with_check, '') like '%booking-receipts%')
  loop
    execute format('drop policy if exists %I on storage.objects', receipt_policy.policyname);
  end loop;
end $$;
