-- 2026-09-28 (session 58): close the lockout handoff the host already answered from the page inbox (door code sent by
-- hand). Before waves' inbox-close fix, a page-inbox reply never closed a handoff; left open, D-274 would turn the guest's
-- next ordinary question into a follow-up card until 06:43 Manila. Guarded: only this row, only while open.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.
begin;
do $$
declare n integer;
begin
  update public.concierge_handoffs set status = 'sent', resolved_by = 'page inbox (by hand, session 58)', resolved_at = now()
   where id::text like '8a2b605b%' and risk = 'access' and status = 'open';
  get diagnostics n = row_count; if n <> 1 then raise exception 'lockout handoff not matched (%); nothing changed', n; end if;
end $$;
commit;
-- Forward check (true):
-- select status = 'sent' from public.concierge_handoffs where id::text like '8a2b605b%';
