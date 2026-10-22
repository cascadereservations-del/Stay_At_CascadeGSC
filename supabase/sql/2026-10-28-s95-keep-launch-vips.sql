-- s95 data step (D-345, Lloyd 2026-10-22): keep the guests who were VIP before the SPEC-46 release as VIP by hand.
-- Runs AFTER release 20261028_s95_guest_tiers is applied. Checks itself and rolls back on any surprise.
-- The 3 ids were VIP on production at 2026-10-22 ~18:05Z and drop to Regular under the new rule; the 4th VIP
-- (59653d3a..., 23 nights) still qualifies and stays rule-driven.
begin;

do $$
declare
  v_ids uuid[] := array[
    '76574d91-681f-4add-a1dc-b472ec8b5f8b',  -- 1 stay, 18 nights
    '91a6226f-5853-4c8b-849d-309d427d1b23',  -- 4 stays, 4 nights
    'bfc9b352-886b-4a76-9dfa-4139557a4ea8'   -- 2 stays, 11 nights
  ]::uuid[];
  v_id uuid;
  v_n int;
begin
  -- the release must be in place
  if to_regprocedure('public.refresh_guest_stats(uuid,uuid,text)') is null then
    raise exception 's95 data step: release 20261028_s95_guest_tiers is not applied';
  end if;
  select count(*) into v_n from public.guests where id = any(v_ids);
  if v_n <> 3 then raise exception 's95 data step: expected 3 guests, found %', v_n; end if;
  -- already done (re-run): nothing to do
  select count(*) into v_n from public.guests where id = any(v_ids) and tier_manual = 'vip';
  if v_n = 3 then raise notice 's95 data step: already applied, nothing changed'; return; end if;

  foreach v_id in array v_ids loop
    update public.guests set tier_manual = 'vip' where id = v_id;
    perform public.refresh_guest_stats(v_id, null, 'Manual tier: vip - existing VIP kept at SPEC-46 launch');
  end loop;

  select count(*) into v_n from public.guests where id = any(v_ids) and tier = 'vip' and tier_manual = 'vip';
  if v_n <> 3 then raise exception 's95 data step: only % of 3 guests are VIP after the update', v_n; end if;
  select count(*) into v_n from public.guest_profile_history
   where guest_id = any(v_ids) and reason = 'Manual tier: vip - existing VIP kept at SPEC-46 launch';
  if v_n <> 3 then raise exception 's95 data step: expected 3 history rows, found %', v_n; end if;
  -- the guest who still qualifies keeps VIP without a manual tier
  select count(*) into v_n from public.guests where id = '59653d3a-52b4-4b27-95dc-c7db62f8128c' and tier = 'vip' and tier_manual is null;
  if v_n <> 1 then raise exception 's95 data step: the rule-driven VIP is not VIP'; end if;
  raise notice 's95 data step: 3 launch VIPs kept by hand, history rows written';
end $$;

select tier, count(*) as guests from public.guests group by 1 order by 1;

commit;
