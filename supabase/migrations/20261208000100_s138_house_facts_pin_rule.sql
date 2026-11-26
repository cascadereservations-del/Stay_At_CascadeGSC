-- 20261208000100_s138_house_facts_pin_rule.sql
-- Payment rule s138 (D-429): the door PIN follows full payment, IDs and the PHP 800 refundable deposit (it used to say "IDs and the balance"; there is no balance any more). NOT APPLIED.
-- Two house_facts rows, one sentence each: smart-lock-prospect (public) and smart-lock-staff (staff). Guarded: each row must hold exactly the seeded text of
-- 20260929010000_house_facts.sql (:91 and :94) or the statement stops (55000); it never overwrites a body edited since.
-- NOT in this release (flagged for the orchestrator): the guest row `smart-lock` (:88) carries the same "once your IDs and the balance are in" wording. The brief named two rows.
-- Rollback: supabase/rollbacks/20261208_s138_house_facts_pin_rule.sql. Release: supabase/releases/s138_payment_rule_20261208.release.json. Test: supabase/tests/database/s138_payment_rule.sql.
do $g$
declare v_p text; v_s text;
begin
  select body into v_p from public.house_facts where topic = 'smart-lock-prospect';
  select body into v_s from public.house_facts where topic = 'smart-lock-staff';
  if v_p is null or v_s is null then
    raise exception 's138 house_facts: smart-lock-prospect or smart-lock-staff is missing' using errcode = '55000';
  end if;
  if v_p is distinct from $b$Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you. Check-in opens at 2:00 PM.$b$ then
    raise exception 's138 house_facts: smart-lock-prospect is not the seeded text (edited since): re-cut' using errcode = '55000';
  end if;
  if v_s is distinct from $b$The lock is TTLock; guest codes are issued from the TTLock app by the host once IDs and the balance are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.$b$ then
    raise exception 's138 house_facts: smart-lock-staff is not the seeded text (edited since): re-cut' using errcode = '55000';
  end if;
end $g$;

update public.house_facts
   set body = $b$Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once your payment, your IDs and the PHP 800 refundable security deposit are in, and the door locks itself behind you. Check-in opens at 2:00 PM.$b$,
       updated_by = 's138 pay-in-full', updated_at = now()
 where topic = 'smart-lock-prospect';

update public.house_facts
   set body = $b$The lock is TTLock; guest codes are issued from the TTLock app by the host once the full payment, the IDs and the PHP 800 refundable security deposit are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.$b$,
       updated_by = 's138 pay-in-full', updated_at = now()
 where topic = 'smart-lock-staff';

do $r$
begin
  if (select count(*) from public.house_facts where topic in ('smart-lock-prospect', 'smart-lock-staff') and body like '%PHP 800%' and body not like '%the balance%') <> 2 then
    raise exception 's138 house_facts: read-back failed' using errcode = '55000';
  end if;
end $r$;
