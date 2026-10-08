-- Compensating rollback for 20261009010000_drop_w01_dispatch.sql: recreates the W01 dispatcher function and trigger exactly as
-- read from production on 2026-10-08 (function md5(replace(prosrc, chr(13), '')) d85d10f1d5d28fc809ad57b6f6458b5e, owner-only
-- execute: acl {postgres=X/postgres}). The vault secrets were never removed by the release.
begin;

create or replace function public.dispatch_w01_booking_requested()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  webhook_secret text;
  cf_client_id text;
  cf_client_secret text;
begin
  if new.event_type <> 'booking.requested' then
    return new;
  end if;

  select decrypted_secret into strict webhook_secret
  from vault.decrypted_secrets
  where name = 'cascade_n8n_w01_webhook_secret';

  select decrypted_secret into strict cf_client_id
  from vault.decrypted_secrets
  where name = 'cascade_cf_w01_client_id';

  select decrypted_secret into strict cf_client_secret
  from vault.decrypted_secrets
  where name = 'cascade_cf_w01_client_secret';

  perform net.http_post(
    url := 'https://cascade-n8n.rocloyd.com/webhook/cascade-w01-booking-requested',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Cascade-Webhook-Secret', webhook_secret,
      'CF-Access-Client-Id', cf_client_id,
      'CF-Access-Client-Secret', cf_client_secret
    ),
    body := jsonb_build_object('event_id', new.id, 'workflow_id', 'CH-W01'),
    timeout_milliseconds := 5000
  );

  return new;
exception
  when others then
    -- A delivery integration must never reject a booking.  The pending outbox
    -- record remains the durable retry/audit source for operational recovery.
    raise warning 'W01 outbox dispatch skipped for %: %', new.id, sqlerrm;
    return new;
end;
$function$;

revoke all on function public.dispatch_w01_booking_requested() from public, anon, authenticated, service_role;

drop trigger if exists automation_outbox_dispatch_w01 on public.automation_outbox;
create trigger automation_outbox_dispatch_w01
  after insert on public.automation_outbox
  for each row execute function public.dispatch_w01_booking_requested();

commit;
