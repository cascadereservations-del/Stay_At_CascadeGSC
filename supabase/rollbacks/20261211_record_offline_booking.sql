-- Rollback of record_offline_booking_20261211 (supabase/migrations/20261211000000_record_offline_booking.sql): puts the engine body back to the one it was cut
-- from (md5 8f9384913791779afd0cd38ed5152220), drops record_offline_booking_v1 and the booking_inquiries.channel column.
-- Refuses (55000, nothing changes) while a booking carries a channel other than 'site': dropping the column would lose where it came from. Bookings the
-- function recorded stay as they are (confirmed direct bookings with their DIRECT: reservation, calendar row and income row), and so do the Airbnb blocks it
-- relabelled 'direct' (calendar-sync resets those by itself after a cancel). Grants restated (ML-21).
begin;

do $g$
declare
  v_md5 text;
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'booking_inquiries' and column_name = 'channel') then
    if exists (select 1 from public.booking_inquiries where channel <> 'site') then
      raise exception 'record_offline_booking rollback: a booking carries a channel other than site; keep the release or clear them first' using errcode = '55000';
    end if;
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure('public.decide_direct_booking_without_finance_review(uuid,text,text)');
  if v_md5 is null then
    raise exception 'record_offline_booking rollback: the engine is missing' using errcode = '55000';
  end if;
  if v_md5 not in ('2342d3f0ee88eb5f98c1260577391618', '8f9384913791779afd0cd38ed5152220') then
    raise exception 'record_offline_booking rollback: the engine is neither the patched body nor the original (md5 %)', v_md5 using errcode = '55000';
  end if;
end $g$;

-- 1. The engine: take the one predicate out again (a no-op when the engine is already the original).
do $r$
declare
  v_def text;
  v_old text;
  v_to  text;
  v_md5 text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure('public.decide_direct_booking_without_finance_review(uuid,text,text)');
  if v_md5 = '8f9384913791779afd0cd38ed5152220' then
    return;
  end if;
  v_def := pg_get_functiondef(to_regprocedure('public.decide_direct_booking_without_finance_review(uuid,text,text)'));
  v_old := $a$and ce.uid not in ('direct:' || v_booking.id::text, 'cascade-direct-' || v_booking.id::text)$a$;
  v_to  := v_old || $a$
      and not (ce.source = 'airbnb' and ce.status = 'blocked' and ce.block_reason = 'direct'
               and current_setting('cascade.offline_booking_id', true) = v_booking.id::text
               and position(upper(left(v_booking.id::text, 8)) in upper(coalesce(ce.block_note, ''))) > 0)$a$;
  if (length(v_def) - length(replace(v_def, v_to, ''))) / length(v_to) <> 1 then
    raise exception 'record_offline_booking rollback: the patched predicate was not found exactly once' using errcode = '55000';
  end if;
  execute replace(v_def, v_to, v_old);
end $r$;
revoke all on function public.decide_direct_booking_without_finance_review(uuid, text, text) from public, anon, authenticated, service_role;

-- 2. The function and the column.
drop function if exists public.record_offline_booking_v1(uuid, date, date, text, text, text, text, integer, numeric, numeric, text, text, text, text, boolean, text[], text);
alter table public.booking_inquiries drop constraint if exists booking_inquiries_channel_check;
alter table public.booking_inquiries drop column if exists channel;

-- read-back
do $$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v
    from pg_proc p where p.oid = to_regprocedure('public.decide_direct_booking_without_finance_review(uuid,text,text)');
  if v is distinct from '8f9384913791779afd0cd38ed5152220' then
    raise exception 'record_offline_booking rollback: the engine is not the original body (md5 %)', coalesce(v, 'null');
  end if;
  if to_regprocedure('public.record_offline_booking_v1(uuid,date,date,text,text,text,text,integer,numeric,numeric,text,text,text,text,boolean,text[],text)') is not null then
    raise exception 'record_offline_booking rollback: record_offline_booking_v1 still exists';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'booking_inquiries' and column_name = 'channel') then
    raise exception 'record_offline_booking rollback: booking_inquiries.channel still exists';
  end if;
end $$;

commit;
