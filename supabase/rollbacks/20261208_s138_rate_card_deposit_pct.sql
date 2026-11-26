-- rollback_20261208_s138_rate_card_deposit_pct.sql: puts terms.deposit_pct back to 50 on the live or scheduled versions of the Cascade property that 20261208000000_s138_rate_card_deposit_pct.sql set to 100.
-- The migration's guard required every such row to read 50, so 100 -> 50 restores them exactly; a row at any other value stops this script (55000). Past versions were never touched.
-- Run it together with the redeploy of the previous edge code only if the pay-in-full rule is withdrawn: the code ignores deposit_pct for the amount due, so the value alone changes no charge.
-- run-sql-on-host.sh does NOT wrap a file: this script carries its own begin/commit.
begin;
do $g$
declare n_other int;
begin
  select count(*) into n_other from public.booking_rate_policy_versions
   where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
     and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
     and coalesce(terms ->> 'deposit_pct', '50')::numeric not in (50, 100);
  if n_other > 0 then
    raise exception 's138 deposit_pct rollback: % live/scheduled version(s) hold a value other than 50 or 100', n_other using errcode = '55000';
  end if;
end $g$;
update public.booking_rate_policy_versions
   set terms = jsonb_set(terms, '{deposit_pct}', '50'::jsonb, true)
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
   and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
   and coalesce(terms ->> 'deposit_pct', '50')::numeric = 100;
commit;
