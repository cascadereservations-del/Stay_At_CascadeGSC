-- rollback_20261208_s138_rate_card_deposit_pct.sql: restores terms.deposit_pct on exactly the versions of the Cascade property that 20261208000000_s138_rate_card_deposit_pct.sql changed.
-- Scope: a row is restored only if it carries the marker terms.s138_prev_deposit_pct (written by the migration) and still reads 100. The marker holds the value to put back and is
-- removed. A row already at 100 before the migration has no marker and keeps 100; a row re-edited through the admin RPC after the migration lost its marker and is left alone. The
-- rows chosen do not depend on the date the rollback runs (past versions were never touched and never carry the marker).
-- Stops (55000) if no row carries the marker (nothing to roll back), or a marked row no longer reads 100 or holds a non-numeric value (edited since).
-- Run it together with the redeploy of the previous edge code only if the pay-in-full rule is withdrawn: the code ignores deposit_pct for the amount due, so the value alone changes no charge.
-- run-sql-on-host.sh does NOT wrap a file: this script carries its own begin/commit.
begin;
do $g$
declare n_marked int; n_changed int;
begin
  select count(*),
         count(*) filter (where jsonb_typeof(terms -> 'deposit_pct') is distinct from 'number'
                             or jsonb_typeof(terms -> 's138_prev_deposit_pct') is distinct from 'number'
                             or (terms ->> 'deposit_pct')::numeric <> 100)
    into n_marked, n_changed
    from public.booking_rate_policy_versions
   where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
     and terms ? 's138_prev_deposit_pct';
  if n_marked = 0 then
    raise exception 's138 deposit_pct rollback: no version carries the s138 marker, nothing to roll back' using errcode = '55000';
  end if;
  if n_changed > 0 then
    raise exception 's138 deposit_pct rollback: % marked version(s) were edited since (not a number, or no longer 100)', n_changed using errcode = '55000';
  end if;
end $g$;
update public.booking_rate_policy_versions
   set terms = jsonb_set(terms, '{deposit_pct}', terms -> 's138_prev_deposit_pct', true) - 's138_prev_deposit_pct'
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
   and terms ? 's138_prev_deposit_pct'
   and jsonb_typeof(terms -> 's138_prev_deposit_pct') = 'number';
commit;
