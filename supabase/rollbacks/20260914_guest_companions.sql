-- Compensating rollback for 20260914240000_guest_companions.sql.
-- Refuses while any companion row exists, so a rollback never silently discards
-- companion contact/ID data. Storage objects (uploaded ID photos) are not
-- deleted automatically; remove them from the guest-id-photos bucket by hand
-- first if the bucket itself should also go.
begin;

do $$
begin
  if exists (select 1 from public.guest_companions) then
    raise exception 'guest_companions has rows; delete or migrate them out before rolling back';
  end if;
end $$;

drop policy if exists "guest id photos manage read" on storage.objects;
drop policy if exists "guest id photos manage write" on storage.objects;
drop policy if exists "guest id photos manage delete" on storage.objects;
delete from storage.buckets where id = 'guest-id-photos';

drop function if exists public.list_guest_companions_v1(uuid);
drop function if exists public.delete_guest_companion_v1(uuid, text);
drop function if exists public.save_guest_companion_v1(uuid, uuid, jsonb, integer, text);
drop table if exists public.guest_companion_history;
drop table if exists public.guest_companions;

commit;
