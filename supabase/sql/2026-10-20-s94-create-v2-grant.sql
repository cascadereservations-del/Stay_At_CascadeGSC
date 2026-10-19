-- s94: production's default privileges gave service_role EXECUTE on the new staff_pay_admin_create_v2 (the rehearsal
-- baseline has no such default). v1 has no service_role grant; match it so the release forward check holds.
begin;
revoke execute on function public.staff_pay_admin_create_v2(uuid, jsonb, uuid[], jsonb, text) from service_role;
do $$ begin
  if has_function_privilege('service_role', 'public.staff_pay_admin_create_v2(uuid,jsonb,uuid[],jsonb,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.staff_pay_admin_create_v2(uuid,jsonb,uuid[],jsonb,text)', 'execute') then
    raise exception 's94 grant fix did not take';
  end if;
end $$;
commit;
