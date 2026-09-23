-- Session 46, D-204 finding 2: three booking_inquiries rows (Jul-Aug 2026) hold a full /object/public/ URL on the PRIVATE
-- booking-receipts bucket, which returns HTTP 400. Today's writer (upload-booking-receipt) stores the bare object name, and
-- all three objects exist in storage (read 2026-09-23). Strip the URL prefix; nothing else changes. Refuses unless exactly 3.
begin;
do $$
declare n int;
begin
  update public.booking_inquiries
     set receipt_image_path = substring(receipt_image_path from length('https://qkgfhsdppslwunarczeq.supabase.co/storage/v1/object/public/booking-receipts/') + 1)
   where receipt_image_path like 'https://qkgfhsdppslwunarczeq.supabase.co/storage/v1/object/public/booking-receipts/%'
     and id in ('92f94d0e-008c-4439-9c94-6d48684629da', '56f21075-0a3e-4326-9f20-f285323bc1d2', 'b55d9df9-3c10-46f3-a5df-242090105da0');
  get diagnostics n = row_count;
  if n <> 3 then raise exception 'expected 3 rows, updated %', n; end if;
end $$;
commit;
-- forward checks: 0 URL-shaped paths left; the three rows now name objects that exist
select 'url_paths_left' k, count(*) from public.booking_inquiries where receipt_image_path like 'http%';
select 'rows_pointing_at_real_objects' k, count(*) from public.booking_inquiries b
  join storage.objects o on o.bucket_id = 'booking-receipts' and o.name = b.receipt_image_path
 where b.id in ('92f94d0e-008c-4439-9c94-6d48684629da', '56f21075-0a3e-4326-9f20-f285323bc1d2', 'b55d9df9-3c10-46f3-a5df-242090105da0');
