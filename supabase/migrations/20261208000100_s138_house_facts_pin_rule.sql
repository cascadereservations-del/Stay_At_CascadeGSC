-- 20261208000100_s138_house_facts_pin_rule.sql
-- Payment rule s138 (D-429): the door PIN follows full payment, IDs and the PHP 800 refundable deposit (it used to say "IDs and the balance"; there is no balance any more). NOT APPLIED.
-- Three house_facts rows, one sentence each: smart-lock-prospect (public), smart-lock-staff (staff) and smart-lock (guest tier, fix round 1). Guarded: each row must hold exactly the
-- seeded text of 20260929010000_house_facts.sql (:88, :91 and :94) or the statement stops (55000); it never overwrites a body edited since.
-- smart-lock has two known texts: the seed, and the seed after stay-site/supabase/sql/2026-10-01-house-facts-remote-tray.sql (key card "on the wooden tray on the TV cabinet", the newest
-- file that sets that topic). Either passes the guard; the update replaces only the one sentence, so the tray wording is kept.
-- Rollback: supabase/rollbacks/20261208_s138_house_facts_pin_rule.sql. Release: supabase/releases/s138_payment_rule_20261208.release.json. Test: supabase/tests/database/s138_payment_rule.sql.
do $g$
declare v_p text; v_s text; v_g text;
begin
  select body into v_p from public.house_facts where topic = 'smart-lock-prospect';
  select body into v_s from public.house_facts where topic = 'smart-lock-staff';
  select body into v_g from public.house_facts where topic = 'smart-lock';
  if v_p is null or v_s is null or v_g is null then
    raise exception 's138 house_facts: smart-lock-prospect, smart-lock-staff or smart-lock is missing' using errcode = '55000';
  end if;
  if v_p is distinct from $b$Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you. Check-in opens at 2:00 PM.$b$ then
    raise exception 's138 house_facts: smart-lock-prospect is not the seeded text (edited since): re-cut' using errcode = '55000';
  end if;
  if v_s is distinct from $b$The lock is TTLock; guest codes are issued from the TTLock app by the host once IDs and the balance are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.$b$ then
    raise exception 's138 house_facts: smart-lock-staff is not the seeded text (edited since): re-cut' using errcode = '55000';
  end if;
  if v_g is distinct from $b$Tap the keypad to wake it, enter your code and press #. The door locks itself when it closes, so pull it firmly shut whenever you leave. Your key card, kept with the remotes inside, also opens the door with a tap on the keypad. Your personal code reaches you at least a day before arrival, once your IDs and the balance are in. Should the keypad not respond, message us here or call {{ONGROUND}} and we will get you in.$b$
     and v_g is distinct from $b$Tap the keypad to wake it, enter your code and press #. The door locks itself when it closes, so pull it firmly shut whenever you leave. Your key card, kept with the remotes on the wooden tray on the TV cabinet, also opens the door with a tap on the keypad. Your personal code reaches you at least a day before arrival, once your IDs and the balance are in. Should the keypad not respond, message us here or call {{ONGROUND}} and we will get you in.$b$ then
    raise exception 's138 house_facts: smart-lock is neither the seeded text nor the seed with the remote-tray edit (edited since): re-cut' using errcode = '55000';
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

update public.house_facts
   set body = replace(body, 'once your IDs and the balance are in.', 'once your payment, your IDs and the PHP 800 refundable security deposit are in.'),
       updated_by = 's138 pay-in-full', updated_at = now()
 where topic = 'smart-lock';

do $r$
begin
  if (select count(*) from public.house_facts where topic in ('smart-lock-prospect', 'smart-lock-staff', 'smart-lock') and body like '%PHP 800%' and body not like '%the balance%') <> 3 then
    raise exception 's138 house_facts: read-back failed' using errcode = '55000';
  end if;
end $r$;
