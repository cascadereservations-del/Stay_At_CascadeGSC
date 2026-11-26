-- rollback_20261208_s138_house_facts_pin_rule.sql: restores the seeded smart-lock-prospect and smart-lock-staff bodies of 20260929010000_house_facts.sql (:91, :94).
-- Guard: each row must hold this release's text or already the seeded text; anything else (an edit since) stops it (55000). updated_by goes back to 'seed 2026-09-29'.
-- run-sql-on-host.sh does NOT wrap a file: this script carries its own begin/commit.
begin;
do $g$
declare v_p text; v_s text;
begin
  select body into v_p from public.house_facts where topic = 'smart-lock-prospect';
  select body into v_s from public.house_facts where topic = 'smart-lock-staff';
  if v_p is null or v_s is null then raise exception 's138 house_facts rollback: a row is missing' using errcode = '55000'; end if;
  if v_p not like '%PHP 800 refundable security deposit are in%' and v_p not like '%once IDs and the balance are in%' then
    raise exception 's138 house_facts rollback: smart-lock-prospect is neither this release nor the seed' using errcode = '55000';
  end if;
  if v_s not like '%PHP 800 refundable security deposit are in%' and v_s not like '%once IDs and the balance are in%' then
    raise exception 's138 house_facts rollback: smart-lock-staff is neither this release nor the seed' using errcode = '55000';
  end if;
end $g$;
update public.house_facts
   set body = $b$Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you. Check-in opens at 2:00 PM.$b$,
       updated_by = 'seed 2026-09-29', updated_at = now()
 where topic = 'smart-lock-prospect' and body like '%PHP 800%';
update public.house_facts
   set body = $b$The lock is TTLock; guest codes are issued from the TTLock app by the host once IDs and the balance are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.$b$,
       updated_by = 'seed 2026-09-29', updated_at = now()
 where topic = 'smart-lock-staff' and body like '%PHP 800%';
commit;
