-- Session 74 lane G8, migration 20261007150000: finance-watch-daily, release-expired-holds-hourly and verify-meter-photo-daily send the
-- Vault cron secret. pg_cron is absent from the schema-only recovery baseline, so every check skips there. Inside begin/rollback.
begin;
select plan(12);

create function public.test_cron_secret_contract() returns setof text language plpgsql as $t$
declare j text; fn text;
begin
  if to_regclass('cron.job') is null then
    return query select * from skip(12, 'pg_cron is absent from the schema-only recovery baseline');
    return;
  end if;
  return query select is((select count(*)::int from cron.job where jobname in ('finance-watch-daily', 'release-expired-holds-hourly', 'verify-meter-photo-daily') and active), 3,
    'all three jobs exist and are active');
  return query select is((select schedule from cron.job where jobname = 'finance-watch-daily'), '30 0 * * *', 'finance-watch-daily keeps 00:30 UTC');
  return query select is((select schedule from cron.job where jobname = 'release-expired-holds-hourly'), '20 * * * *', 'release-expired-holds-hourly keeps :20');
  return query select is((select schedule from cron.job where jobname = 'verify-meter-photo-daily'), '30 23 * * *', 'verify-meter-photo-daily keeps 23:30 UTC');
  for j, fn in select * from (values ('finance-watch-daily', 'finance-watch'), ('release-expired-holds-hourly', 'release-expired-holds'), ('verify-meter-photo-daily', 'verify-meter-photo')) v(a, b) loop
    return query select ok((select command like '%/functions/v1/' || fn || E'\'%' from cron.job where jobname = j), j || ' calls ' || fn);
    return query select ok((select command like '%x-cascade-cron-secret%' and command like '%vault.decrypted_secrets%' and command like '%cascade_cron_shared_secret%'
                              and command !~ 'x-cascade-cron-secret''\s*,\s*''[^(]' from cron.job where jobname = j), j || ' reads the secret from Vault, never embeds it');
  end loop;
  return query select ok((select command like '%"notify":false%' and command like '%"limit":5%' and command like '%timeout_milliseconds := 300000%' from cron.job where jobname = 'verify-meter-photo-daily'),
    'the meter sweep keeps its body and 300 s timeout');
  return query select ok((select command like '%Bearer eyJ%' from cron.job where jobname = 'verify-meter-photo-daily'),
    'the meter sweep still sends the anon JWT its gateway checks (verify_jwt stays true)');
end $t$;
select * from public.test_cron_secret_contract();
drop function public.test_cron_secret_contract();

select * from finish();
rollback;
