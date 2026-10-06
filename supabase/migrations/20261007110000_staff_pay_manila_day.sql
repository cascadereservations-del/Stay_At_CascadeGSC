-- 20261007110000_staff_pay_manila_day.sql
-- Session 74, lane G3 (money): release money_fixes_20261007, part 1.
-- A clean logged at 07:30 Manila is 23:30Z the day before. staff_pay_candidates_v1 and staff_pay_request_create_v1 fall back to
-- cleaned_at::date when a session has neither a checkout nor a check-in date; the database session is UTC, so that clean was listed,
-- priced (rate in force on that day) and booked to the PREVIOUS day. The pay day is the Manila date.
--
-- The two functions are patched from their LIVE bodies (pg_get_functiondef, then the one expression replaced) instead of vendored
-- here: hand-applied schema is invisible to CI (memory: cascade-sql-dir-schema-is-invisible-to-ci), and a copied 150-line body could
-- silently revert a hand edit. Nothing else in either function changes; grants, owner and search_path are kept by CREATE OR REPLACE.
-- Idempotent: a body with no cleaned_at::date left is skipped. A function that is missing stops the release.
-- Not changed here (not staff pay, reported in the release note): stay_chains.sql:327 and the health-check cleaned_at::date joins.

begin;

do $$
declare
  v_fn text; v_def text; v_new text;
begin
  foreach v_fn in array array['public.staff_pay_candidates_v1()', 'public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);   -- raises if the function does not exist
    if v_def !~ 'cleaned_at::date' then continue; end if;
    -- (alias.)cleaned_at::date  ->  (alias.cleaned_at at time zone 'Asia/Manila')::date
    v_new := regexp_replace(v_def, '(\w+\.)?cleaned_at::date', '(\1cleaned_at at time zone ''Asia/Manila'')::date', 'g');
    if v_new = v_def or v_new ~ 'cleaned_at::date' then
      raise exception 'staff pay Manila day: could not patch %', v_fn;
    end if;
    execute v_new;
  end loop;
end $$;

commit;
