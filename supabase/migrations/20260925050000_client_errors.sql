-- 20260925050000_client_errors.sql
-- Session 49 (Opus 5): release client_errors_20260925 - the free error monitor Lloyd chose (D-240, option A).
--
-- The cleaning checklist and the direct booking site report their own errors (a crash, an unhandled promise, a
-- failed server reply) to the client-error Edge Function, which records them here and tells a person in Telegram.
-- One row per distinct error (fingerprint), with a count, so a flood of the same error is one row and one card.
-- Built on Supabase Free and the existing Telegram bot: no new service (memory cascade-free-tier-first).
-- Live 2026-09-25 00:07-00:13Z is the case it exists for: a cleaner's report was refused three times with
-- invalid_photo_scope and nobody knew until Lloyd sent a phone screenshot.

begin;

create table if not exists public.client_errors (
  fingerprint     text primary key check (char_length(fingerprint) between 8 and 64),
  app             text not null check (app in ('checklist', 'booking_site')),
  kind            text not null check (kind in ('error', 'rejection', 'http')),
  message         text not null check (char_length(message) <= 400),
  detail          jsonb not null default '{}'::jsonb,
  first_seen      timestamptz not null default now(),
  last_seen       timestamptz not null default now(),
  count           integer not null default 1,
  last_alerted_at timestamptz
);

alter table public.client_errors enable row level security;
revoke all on table public.client_errors from public, anon, authenticated;
grant select on table public.client_errors to authenticated;
grant all on table public.client_errors to service_role;
drop policy if exists client_errors_staff_read on public.client_errors;
create policy client_errors_staff_read on public.client_errors for select to authenticated
  using (public.current_staff_authorized('read_operations', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid));

-- Record one occurrence and say whether a person should hear about it now: a new error always, a known one once a
-- day while it keeps happening. p_alertable = false (an expected refusal such as a 409) records without alerting.
-- Flood guard: at most 200 NEW fingerprints an hour; beyond that a new error is dropped (known ones still count).
create or replace function public.record_client_error_v1(
  p_fingerprint text,
  p_app         text,
  p_kind        text,
  p_message     text,
  p_detail      jsonb,
  p_alertable   boolean default true
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_row public.client_errors%rowtype;
  v_new boolean;
begin
  select * into v_row from public.client_errors where fingerprint = p_fingerprint for update;
  v_new := not found;
  if v_new then
    if (select count(*) from public.client_errors where first_seen > now() - interval '1 hour') >= 200 then
      return jsonb_build_object('recorded', false, 'alert', false, 'reason', 'flood_guard');
    end if;
    insert into public.client_errors(fingerprint, app, kind, message, detail)
    values (p_fingerprint, p_app, p_kind, left(coalesce(p_message, ''), 400), coalesce(p_detail, '{}'::jsonb))
    returning * into v_row;
  else
    update public.client_errors
       set count = count + 1, last_seen = now(), detail = coalesce(p_detail, detail)
     where fingerprint = p_fingerprint
    returning * into v_row;
  end if;

  if coalesce(p_alertable, true) and (v_row.last_alerted_at is null or v_row.last_alerted_at < now() - interval '24 hours') then
    update public.client_errors set last_alerted_at = now() where fingerprint = p_fingerprint;
    return jsonb_build_object('recorded', true, 'alert', true, 'new', v_new, 'count', v_row.count, 'first_seen', v_row.first_seen);
  end if;
  return jsonb_build_object('recorded', true, 'alert', false, 'new', v_new, 'count', v_row.count, 'first_seen', v_row.first_seen);
end;
$function$;

revoke all on function public.record_client_error_v1(text, text, text, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.record_client_error_v1(text, text, text, text, jsonb, boolean) to service_role;

comment on table public.client_errors is
  'D-240: errors the checklist and the booking site report about themselves, one row per fingerprint. Written only by the client-error Edge Function through record_client_error_v1.';

commit;
