-- Session 85, lane count: release s85_cleaner_count_20261018. A cleaner may set the remaining amount of an item (reconcile_inventory_baseline_v1) and undo their own count
-- (inventory_undo_v1). Hermetic: its own property and users (uuids d8500000-...). Everything rolls back.
-- The md5 guard at the head of the migration cannot run inside pgTAP; the rehearsal proves it separately.
begin;
select plan(19);

grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;

-- fixtures: a cleaner, an owner, a finance user (neither action) and a cleaner with no access to the property; two items
insert into auth.users(id, email) values
  ('d8500000-0000-4000-8000-0000000000a1', 'zz85-honey@example.com'), ('d8500000-0000-4000-8000-0000000000a5', 'zz85-owner@example.com'),
  ('d8500000-0000-4000-8000-0000000000a4', 'zz85-finance@example.com'), ('d8500000-0000-4000-8000-0000000000a6', 'zz85-outsider@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('d8500000-0000-4000-8000-0000000000a1', 'cleaner'), ('d8500000-0000-4000-8000-0000000000a5', 'owner'),
  ('d8500000-0000-4000-8000-0000000000a4', 'finance'), ('d8500000-0000-4000-8000-0000000000a6', 'cleaner');
insert into public.properties(id, name, is_active) values ('d8500000-0000-4000-8000-0000000000b0', 'Zz S85 fixture property', true);
insert into public.staff_property_access(user_id, property_id) select u, 'd8500000-0000-4000-8000-0000000000b0'
  from unnest(array['d8500000-0000-4000-8000-0000000000a1', 'd8500000-0000-4000-8000-0000000000a5', 'd8500000-0000-4000-8000-0000000000a4']::uuid[]) u;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, reorder_below, is_consumable) values
  ('d8500000-0000-4000-8000-0000000000c1', 'd8500000-0000-4000-8000-0000000000b0', 'Zz85 Hand soap', 'Toiletries', 'pc', 5, 2, true),
  ('d8500000-0000-4000-8000-0000000000c2', 'd8500000-0000-4000-8000-0000000000b0', 'Zz85 Towel', 'Bedroom', 'pc', 8, null, false);

-- 1. the cleaner counts item 1 (5 -> 7), twice with the same key, then with bad input, as finance and as an outsider
select pg_temp.as_user('d8500000-0000-4000-8000-0000000000a1');
insert into _t select 'c1', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c1', 7, 'cleaner count', 'zz85-count-key-0001')$$);
insert into _t select 'c1r', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c1', 7, 'cleaner count', 'zz85-count-key-0001')$$);
insert into _t select 'cn', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c2', -1, 'cleaner count', 'zz85-count-key-0002')$$);
insert into _t select 'cd', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c2', 1.234, 'cleaner count', 'zz85-count-key-0003')$$);
insert into _t select 'cm', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c2', 3, '  ', 'zz85-count-key-0004')$$);
reset role;
select pg_temp.as_user('d8500000-0000-4000-8000-0000000000a4');
insert into _t select 'cf', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c2', 3, 'finance count', 'zz85-count-key-0005')$$);
reset role;
select pg_temp.as_user('d8500000-0000-4000-8000-0000000000a6');
insert into _t select 'co', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c2', 3, 'outsider count', 'zz85-count-key-0006')$$);
reset role;
select is((select v->>'ok' from _t where k = 'c1'), 'true', 'as cleaner a count succeeds');
select is((select v->>'before' || '>' || (v->>'after') from _t where k = 'c1'), '5.00>7', 'and reports before and after');
select is((select qty_on_hand from public.inventory_items where id = 'd8500000-0000-4000-8000-0000000000c1'), 7.00, 'the remaining amount is now 7');
select is((select count(*)::int from public.inventory_stock_movements where item_id = 'd8500000-0000-4000-8000-0000000000c1' and kind = 'reconcile'
  and actor_user_id = 'd8500000-0000-4000-8000-0000000000a1' and quantity_before = 5 and quantity_after = 7), 1, 'one reconcile movement is written, by the cleaner');
select ok((select movement_controlled_at is not null and baseline_note = 'cleaner count' and baseline_reviewed_by = 'd8500000-0000-4000-8000-0000000000a1' from public.inventory_items
  where id = 'd8500000-0000-4000-8000-0000000000c1'), 'the item is movement-controlled with the note');
select is((select v->>'movementId' from _t where k = 'c1r'), (select v->>'movementId' from _t where k = 'c1'), 'the same key again replays the same movement');
select is((select count(*)::int from public.inventory_stock_movements where item_id = 'd8500000-0000-4000-8000-0000000000c1'), 1, 'and writes nothing more');
select is((select v->>'err' from _t where k = 'cn'), '22023', 'a negative count is still refused');
select is((select v->>'err' from _t where k = 'cd'), '22023', 'three decimals are still refused');
select is((select v->>'err' from _t where k = 'cm'), '22023', 'a blank note is still refused');
select is((select v->>'err' from _t where k = 'cf'), '42501', 'a role with neither action (finance) is refused with 42501');
select is((select v->>'err' from _t where k = 'co'), '42501', 'a cleaner with no access to the property is refused with 42501');
select is((select count(*)::int from public.inventory_stock_movements where item_id = 'd8500000-0000-4000-8000-0000000000c2'), 0, 'no refused count wrote a movement');

-- 2. the owner still counts (item 2: 8 -> 6); the cleaner cannot undo it; the owner can undo their own
select pg_temp.as_user('d8500000-0000-4000-8000-0000000000a5');
insert into _t select 'o1', pg_temp.try($$select public.reconcile_inventory_baseline_v1('d8500000-0000-4000-8000-0000000000c2', 6, 'owner count', 'zz85-count-key-0007')$$);
reset role;
select pg_temp.as_user('d8500000-0000-4000-8000-0000000000a1');
insert into _t select 'u_other', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'o1')));
reset role;
select pg_temp.as_user('d8500000-0000-4000-8000-0000000000a5');
insert into _t select 'u_owner', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'o1')));
reset role;
select ok((select v->>'ok' = 'true' and v->>'after' = '6' from _t where k = 'o1') and (select kind from public.inventory_stock_movements where id = (select (v->>'movementId')::uuid from _t where k = 'o1')) = 'reconcile', 'the owner still counts (one reconcile movement)');
select is((select v->>'reason' from _t where k = 'u_other'), 'not_yours', 'a cleaner cannot undo someone else''s count');
select ok((select v->>'ok' = 'true' and v->>'qty' = '8.00' from _t where k = 'u_owner'), 'the owner still undoes their own count (back to 8)');

-- 3. the cleaner undoes their own count (item 1: 7 -> 5), and a repeat is answered, not applied twice
select pg_temp.as_user('d8500000-0000-4000-8000-0000000000a1');
insert into _t select 'u_own', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'c1')));
insert into _t select 'u_rep', pg_temp.try(format($q$select public.inventory_undo_v1(%L)$q$, (select v->>'movementId' from _t where k = 'c1')));
reset role;
select ok((select v->>'ok' = 'true' and v->>'qty' = '5.00' from _t where k = 'u_own')
  and (select qty_on_hand from public.inventory_items where id = 'd8500000-0000-4000-8000-0000000000c1') = 5.00, 'undo of own count by the cleaner works (back to 5)');
select ok((select v->>'replayed' = 'true' from _t where k = 'u_rep')
  and (select count(*)::int from public.inventory_stock_movements where item_id = 'd8500000-0000-4000-8000-0000000000c1' and kind = 'adjustment' and actor_user_id = 'd8500000-0000-4000-8000-0000000000a1') = 1, 'a repeat is a replay: one adjustment movement');

-- 4. the new internal writer has no client grant
select ok(not (has_function_privilege('anon', 'public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text)', 'execute')
  or has_function_privilege('authenticated', 'public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text)', 'execute')
  or has_function_privilege('service_role', 'public.s_inventory_staff_movement_v1(uuid,text,numeric,text,text)', 'execute')), 'the internal movement writer is executable by no client role');

select * from finish();
rollback;
