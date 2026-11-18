-- Compensating rollback for release s120_guest_count_20261120 (session 120, migration 20261120000001_s120_guest_count.sql).
-- Takes the two `|| public.stay_guest_count_json_v1(p_property_id, s.uid)` additions and the two `, 'guest_id', s.guest_id` additions back out of staff_home_v1 (guard: the s120 body b85530233f55696b136e4a49d1ed255c; result: the s119 body,
-- md5 18f5723d01ce20788d6fb2f114129ed8), drops the two RPCs and the helper, the guest_count column and its check, removes the history rows of action count and puts the four-value action
-- check back. DATA LOSS (by design): every typed guest count and its history rows. Rows of stay_staying that only held a count stay as rows with no names, exactly like a blank save.
-- Roll the Staff app back first (it reads staying.guest_count / booked_guests and calls the RPCs). Apply with run-sql-on-host.sh.

begin;

do $$
declare v_def text; v_a text; v_to text; v_got text; v_g text; v_g2 text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)');
  if v_got is distinct from 'b85530233f55696b136e4a49d1ed255c' then
    raise exception 's120 guest count rollback: staff_home_v1 is not the s120 body (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
  v_def := replace(pg_get_functiondef(to_regprocedure('public.staff_home_v1(uuid)')), chr(13), '');
  v_a := 'jsonb_build_object(''staying'', public.stay_staying_json_v1(p_property_id, s.uid) || public.stay_guest_count_json_v1(p_property_id, s.uid))';
  if (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 2 then
    raise exception 's120 guest count rollback: the staying anchor in staff_home_v1 was not found exactly twice' using errcode = '55000';
  end if;
  v_to := 'jsonb_build_object(''staying'', public.stay_staying_json_v1(p_property_id, s.uid))';
  v_def := replace(v_def, v_a, v_to);
  v_g2 := 'jsonb_build_object(''arrival_ready'', public.s_arrival_ready_v1(s.guest_id, s.source), ''guest_id'', s.guest_id)';
  if (length(v_def) - length(replace(v_def, v_g2, ''))) / length(v_g2) <> 2 then
    raise exception 's120 guest count rollback: the guest_id anchor in staff_home_v1 was not found exactly twice' using errcode = '55000';
  end if;
  v_g := 'jsonb_build_object(''arrival_ready'', public.s_arrival_ready_v1(s.guest_id, s.source))';
  execute replace(v_def, v_g2, v_g);
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)');
  if v_got is distinct from '18f5723d01ce20788d6fb2f114129ed8' then
    raise exception 's120 guest count rollback: staff_home_v1 after the restore has md5 %, expected 18f5723d01ce20788d6fb2f114129ed8', v_got using errcode = '55000';
  end if;
end $$;
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

drop function if exists public.staff_guest_stay_v1(uuid, uuid);
drop function if exists public.set_stay_guest_count_v1(uuid, text, integer, integer, text, text);
drop function if exists public.stay_guest_count_json_v1(uuid, text);

delete from public.stay_staying_history where action = 'count';
alter table public.stay_staying_history drop constraint if exists stay_staying_history_action_check;
alter table public.stay_staying_history add constraint stay_staying_history_action_check check (action in ('set', 'accept', 'reject', 'suggest'));
alter table public.stay_staying drop constraint if exists stay_staying_guest_count_range;
alter table public.stay_staying drop column if exists guest_count;

do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)')) is distinct from '18f5723d01ce20788d6fb2f114129ed8' then
    raise exception 's120 guest count rollback: staff_home_v1 is not the s119 body after the restore' using errcode = '55000';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'stay_staying' and column_name = 'guest_count') then
    raise exception 's120 guest count rollback: guest_count is still there' using errcode = '55000';
  end if;
end $$;

commit;
