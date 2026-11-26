-- 20261208000000_s138_rate_card_deposit_pct.sql
-- Payment rule s138 (D-428): every direct stay is paid in full to confirm. rate card terms.deposit_pct 50 -> 100 on the versions that are live or scheduled. NOT APPLIED.
-- Rollback: supabase/rollbacks/20261208_s138_rate_card_deposit_pct.sql. Release: supabase/releases/s138_payment_rule_20261208.release.json. Test: supabase/tests/database/s138_payment_rule.sql.
--
-- What changes: booking_rate_policy_versions.terms -> 'deposit_pct' for the rows of the Cascade property whose effective_to is null or not yet past (the version in force today and
-- every scheduled one). Past versions keep 50: they describe stays already quoted. Nothing else in terms (tiers) or the row (rate, dates, approval) is touched.
-- Who reads it: get_rate_card_v1 (coalesce(..., 50)) and its `upcoming` list pass the number on; the edge code (pricing.ts) now treats the amount due as the whole stay whatever
-- the number is, so the value is informational (the relay email, the site). bookings keep deposit_amount = amount due (now the total); no stored booking changes.
--
-- Guard (55000): refuse unless the property has at least one live-or-scheduled version, and every such version reads 50 (the value this release was cut from) or already 100 with
-- at least one still at 50. A mixed or unexpected value (say 30) means the card was edited after this was cut: stop and re-cut.
do $g$
declare n_open int; n_50 int; n_other int;
begin
  select count(*),
         count(*) filter (where coalesce(terms ->> 'deposit_pct', '50')::numeric = 50),
         count(*) filter (where coalesce(terms ->> 'deposit_pct', '50')::numeric not in (50, 100))
    into n_open, n_50, n_other
    from public.booking_rate_policy_versions
   where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
     and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date);
  if n_open = 0 then
    raise exception 's138 deposit_pct: no live or scheduled rate version for the property' using errcode = '55000';
  end if;
  if n_other > 0 then
    raise exception 's138 deposit_pct: % live/scheduled version(s) hold a deposit_pct other than 50 or 100: re-cut from the live card', n_other using errcode = '55000';
  end if;
  if n_50 = 0 then
    raise exception 's138 deposit_pct: already applied (no live/scheduled version holds 50)' using errcode = '55000';
  end if;
end $g$;

update public.booking_rate_policy_versions
   set terms = jsonb_set(terms, '{deposit_pct}', '100'::jsonb, true)
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
   and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
   and coalesce(terms ->> 'deposit_pct', '50')::numeric = 50;

-- read-back: nothing live or scheduled is left at 50
do $r$
begin
  if exists (select 1 from public.booking_rate_policy_versions
              where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
                and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
                and coalesce(terms ->> 'deposit_pct', '50')::numeric <> 100) then
    raise exception 's138 deposit_pct: read-back failed, a live or scheduled version is not at 100' using errcode = '55000';
  end if;
end $r$;
