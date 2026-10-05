-- Compensating rollback for release transactions_hide_archive_20261005 (session 71).
-- Archived rows go back to the status they had (archived_prev_status), then the function, constraint and columns are dropped.
-- Hidden flags are display only and are dropped with their columns. Take a backup first: dropping the columns loses who hid or archived what.
begin;
-- One update: status and archived_at change together, or the archived-is-void CHECK would abort the rollback.
update public.transactions set status = coalesce(archived_prev_status, 'void'), archived_at = null, archived_by = null, archived_prev_status = null where archived_at is not null;
drop function if exists public.admin_transactions_bulk_v1(uuid, uuid[], text, text);
alter table public.transactions drop constraint if exists transactions_archived_is_void_check;
alter table public.transactions
  drop column if exists hidden_at, drop column if exists hidden_by,
  drop column if exists archived_at, drop column if exists archived_by, drop column if exists archived_prev_status;
commit;
