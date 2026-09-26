-- 2026-09-26 (session 55): clean up the SPEC-34 synthetic submits (the server-authority proof and the site full-pay
-- proof). Every synthetic request uses guest_email cascadereservations+s55@gmail.com and guest name "Synthetic S55";
-- all of them are still pending (never confirmed), so their income rows are pending_review, not confirmed.
--   booking -> cancelled; calendar hold 'direct:<id>' -> cancelled; pending_review transaction -> void;
--   any active hold -> released; pending automation_outbox rows -> dead_letter (NO_CONSUMER_D070).
-- Guarded: matches only that e-mail; a confirmed one, or none at all, rolls everything back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site, before the next 07:00 Manila digest.
begin;
do $$
declare n integer; ids uuid[];
begin
  select array_agg(id) into ids from public.booking_inquiries
   where guest_email = 'cascadereservations+s55@gmail.com' and guest_name = 'Synthetic S55';
  if ids is null then raise exception 'no Synthetic S55 booking found; nothing changed'; end if;
  if exists (select 1 from public.booking_inquiries where id = any(ids) and status not in ('pending', 'cancelled')) then
    raise exception 'a Synthetic S55 booking is not pending; nothing changed';
  end if;
  raise notice 'synthetic bookings: %', array_length(ids, 1);

  update public.booking_inquiries set status = 'cancelled', notes = coalesce(notes || E'\n', '') || '[system] session 55 synthetic test, cancelled by cleanup'
   where id = any(ids) and status <> 'cancelled';
  update public.calendar_events set status = 'cancelled', updated_at = now()
   where uid = any(select 'direct:' || x::text from unnest(ids) x) and status <> 'cancelled';
  get diagnostics n = row_count; raise notice 'calendar rows cancelled: %', n;
  update public.booking_holds set status = 'released' where booking_id = any(ids) and status = 'active';
  update public.transactions set status = 'void', updated_at = now()
   where booking_id = any(ids) and status = 'pending_review';
  get diagnostics n = row_count; raise notice 'transactions voided: %', n;
  if exists (select 1 from public.transactions where booking_id = any(ids) and status = 'confirmed') then
    raise exception 'a confirmed transaction references a synthetic booking; nothing changed';
  end if;
  update public.automation_outbox set status = 'dead_letter', last_error_code = 'NO_CONSUMER_D070', completed_at = now()
   where aggregate_id = any(ids) and status = 'pending';
  get diagnostics n = row_count; raise notice 'outbox rows retired: %', n;
end $$;
commit;
-- Forward checks (all true):
-- select bool_and(status = 'cancelled') from public.booking_inquiries where guest_email = 'cascadereservations+s55@gmail.com';
-- select count(*) = 0 from public.transactions t join public.booking_inquiries b on b.id = t.booking_id where b.guest_email = 'cascadereservations+s55@gmail.com' and t.status <> 'void';
-- select count(*) = 0 from public.calendar_events c join public.booking_inquiries b on c.uid = 'direct:' || b.id where b.guest_email = 'cascadereservations+s55@gmail.com' and c.status <> 'cancelled';
-- select count(*) = 0 from public.automation_outbox o join public.booking_inquiries b on o.aggregate_id = b.id where b.guest_email = 'cascadereservations+s55@gmail.com' and o.status = 'pending';
