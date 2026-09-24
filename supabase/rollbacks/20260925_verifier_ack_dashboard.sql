-- Rollback for release verifier_ack_dashboard_20260925: restores telegram_ack_verifier_finding_v1 to its
-- pre-release body (md5 df5698031a61a10ae33fac46f925286a, from 20260921010000_system_verifier_phase1.sql) and drops
-- ack_verifier_finding_v1. The acknowledged_at / acknowledged_by columns stay: nothing old reads them.
begin;

drop function if exists public.ack_verifier_finding_v1(text);

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
     set status = 'acknowledged'
   where key = p_key and status = 'open';
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_open'); end if;

  return jsonb_build_object('ok', true, 'key', p_key, 'by', p.user_id);
end;
$function$;

revoke all on function public.telegram_ack_verifier_finding_v1(bigint, text) from public, anon, authenticated;
grant execute on function public.telegram_ack_verifier_finding_v1(bigint, text) to service_role;

do $$
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.telegram_ack_verifier_finding_v1(bigint, text)'::regprocedure) <> 'df5698031a61a10ae33fac46f925286a' then
    raise exception 'rollback body does not hash to the pre-release md5';
  end if;
end $$;

commit;
