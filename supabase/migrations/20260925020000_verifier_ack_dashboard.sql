-- 20260925020000_verifier_ack_dashboard.sql
-- Session 49 (Opus 5): release verifier_ack_dashboard_20260925 - SPEC-25 (D-226).
--
-- 1. verifier_findings gains acknowledged_at / acknowledged_by (the auth user uuid as text) so every
--    acknowledgement records who and when.
-- 2. ack_verifier_finding_v1(key): the dashboard's "Known, stop reminding". Owner or admin (42501 otherwise),
--    an outcome for state (acknowledged / not_open). authenticated only; anon revoked by name.
-- 3. telegram_ack_verifier_finding_v1 stamps the same two columns. Its body was cut from
--    20260921010000_system_verifier_phase1.sql after asserting it hashes to the live md5 df569803..., then one
--    exact replacement of its update statement.
-- apply_verifier_run_v1 is NOT touched (B126 md5 stands), so the D-217.2 rule - an acknowledgement holds until the
-- finding's detail changes - is inherited. A reopened row keeps its old ack columns; the dashboard shows them only
-- while status = 'acknowledged'.

begin;

alter table public.verifier_findings
  add column if not exists acknowledged_at timestamptz,
  add column if not exists acknowledged_by text;

create or replace function public.ack_verifier_finding_v1(p_key text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
begin
  if not public.current_staff_active(array['owner', 'admin']) then
    raise exception 'only an owner or admin can acknowledge a finding' using errcode = '42501';
  end if;
  update public.verifier_findings
     set status = 'acknowledged', acknowledged_at = now(), acknowledged_by = auth.uid()::text
   where key = p_key and status = 'open';
  if not found then return jsonb_build_object('ok', true, 'outcome', 'not_open'); end if;
  return jsonb_build_object('ok', true, 'outcome', 'acknowledged');
end;
$function$;

revoke all on function public.ack_verifier_finding_v1(text) from public, anon;
grant execute on function public.ack_verifier_finding_v1(text) to authenticated;

comment on function public.ack_verifier_finding_v1(text) is
  'SPEC-25 (D-226): the dashboard Known, stop reminding. Owner or admin; stamps acknowledged_at/by. An acknowledged finding re-opens by itself if its detail changes.';

create or replace function public.telegram_ack_verifier_finding_v1(
  p_telegram_user_id bigint,
  p_key              text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare p public.staff_access_profiles%rowtype;
begin
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  if p.role not in ('owner', 'admin') then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  if p.disabled_at is not null then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;

  update public.verifier_findings
     set status = 'acknowledged', acknowledged_at = now(), acknowledged_by = p.user_id::text
   where key = p_key and status = 'open';
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_open'); end if;

  return jsonb_build_object('ok', true, 'key', p_key, 'by', p.user_id);
end;
$function$;

revoke all on function public.telegram_ack_verifier_finding_v1(bigint, text) from public, anon, authenticated;
grant execute on function public.telegram_ack_verifier_finding_v1(bigint, text) to service_role;

commit;
