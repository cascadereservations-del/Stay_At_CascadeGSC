create or replace function public.ops_payload_has_financial_data(p_payload jsonb)
returns boolean
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
  v_key text;
  v_value jsonb;
  v_text text;
begin
  case pg_catalog.jsonb_typeof(p_payload)
    when 'object' then
      for v_key, v_value in select key, value from pg_catalog.jsonb_each(p_payload)
      loop
        if v_key ~* '(amount|currency|payout|revenue|expense|balance|payment|paid|receipt|bank|refund|deposit|fee|rate|price|cost|ledger|transaction)' then
          return true;
        end if;
        if public.ops_payload_has_financial_data(v_value) then
          return true;
        end if;
      end loop;
    when 'array' then
      for v_value in select value from pg_catalog.jsonb_array_elements(p_payload)
      loop
        if public.ops_payload_has_financial_data(v_value) then
          return true;
        end if;
      end loop;
    when 'string' then
      v_text := p_payload #>> '{}';
      if v_text ~* '(₱|\mphp\M|\musd\M|\meur\M|\mgbp\M|\mjpy\M|\maud\M|\mcad\M|\mpaid\M|\mpayment\M|\mpayout\M|\mrevenue\M|\mexpense\M|\mbalance\M|\mreceipt\M|\mbank\M|\mrefund\M|\mdeposit\M|\mfee\M|\mrate\M|\mprice\M|\mcost\M|\mledger\M|\mtransaction\M)' then
        return true;
      end if;
    else
      null;
  end case;
  return false;
end;
$$;

revoke all on function public.ops_payload_has_financial_data(jsonb) from public, anon, authenticated;
grant execute on function public.ops_payload_has_financial_data(jsonb) to service_role;

alter table public.automation_outbox
  add column if not exists route_class text not null default 'internal',
  add column if not exists template_key text not null default 'internal.event';

alter table public.automation_outbox
  drop constraint if exists automation_outbox_route_class_check,
  add constraint automation_outbox_route_class_check
    check (route_class in ('finance', 'ops', 'guest', 'internal')),
  drop constraint if exists automation_outbox_template_key_check,
  add constraint automation_outbox_template_key_check
    check (template_key ~ '^(finance|ops|guest|internal)\.[a-z0-9_]+$'),
  drop constraint if exists automation_outbox_template_route_check,
  add constraint automation_outbox_template_route_check
    check (split_part(template_key, '.', 1) = route_class),
  drop constraint if exists automation_outbox_ops_payload_guard,
  add constraint automation_outbox_ops_payload_guard
    check (route_class <> 'ops' or not public.ops_payload_has_financial_data(payload));

alter table public.notification_routes
  add column if not exists route_class text not null default 'internal';

alter table public.notification_routes
  drop constraint if exists notification_routes_route_class_check,
  add constraint notification_routes_route_class_check
    check (route_class in ('finance', 'ops', 'guest', 'internal'));

comment on column public.automation_outbox.route_class is
  'Authority boundary for delivery. OPS payloads are rejected when financial keys or text are present.';
comment on column public.automation_outbox.template_key is
  'Closed route-specific message template; arbitrary provider prose is not an outbox contract.';
