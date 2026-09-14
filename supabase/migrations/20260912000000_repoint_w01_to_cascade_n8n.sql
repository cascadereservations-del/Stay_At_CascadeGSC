-- Repoint the W01 dispatcher from Alfred's SHARED n8n to Cascade's own instance
-- (D-068 / D-069). Only the URL changes; body, headers, error handling, trigger and
-- privileges are byte-identical to 20260824045800_dispatch_w01_to_n8n.sql.
--
-- The CF-Access service-token headers are kept deliberately. On the new hostname
-- /webhook is an Access bypass app, so they are ignored today, but keeping them means
-- tightening that path to a service-token policy later needs no database change.
create or replace function public.dispatch_w01_booking_requested()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke all on function public.dispatch_w01_booking_requested()
  from public, anon, authenticated, service_role;

comment on function public.dispatch_w01_booking_requested() is
  'Trigger-only W01 dispatcher, pointed at cascade-n8n.rocloyd.com (D-069). Not executable through PostgREST roles.';
