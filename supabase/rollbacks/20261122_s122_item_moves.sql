-- Compensating rollback for release s122_item_moves_20261122 (session 122, migration 20261122000000_s122_item_moves.sql).
-- Puts the four patched bodies back (each from the patched md5 to the release original; a body that is neither stops the rollback with 55000 before anything is dropped):
--   record_inventory_anchor_v1 a8c9099d20a49fa57f266e0c2a73c3eb, record_missed_refill_v1 d0d9cf73fea6e67150d0766bdede7d02,
--   record_inventory_usage c1c7bff8e55b4aab5528b9fc60a49740, record_restock_v1 490f7db83c6cf1f1dfef72452a4f49e7.
-- Then drops the four move functions and the two internal helpers, the closed table inventory_item_moves and the three columns
-- inventory_usage_intervals.moved_between, inventory_usage.moved_from_item_id and inventory_usage.moved_at.
-- DATA LOSS (by design): every recorded move and undo, and the moved_between of every interval. The shelves stay where the moves put them, usage rows stay under the item they were
-- re-pointed to, and consumed / accepted of closed intervals are not touched (an interval that counted a move keeps its consumed figure).
-- Roll the admin app back FIRST (it calls the four functions). Apply with run-sql-on-host.sh.

begin;

-- 1. record_inventory_anchor_v1: back to a8c9099d20a49fa57f266e0c2a73c3eb
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_inventory_anchor_v1(uuid,numeric,timestamptz,text)');
  if v_src is null then raise exception 's122: public.record_inventory_anchor_v1 is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = 'a8c9099d20a49fa57f266e0c2a73c3eb' then raise notice 's122: record_inventory_anchor_v1 already original'; return; end if;
  if v_md5 is distinct from 'f38dcf164dad76b9cda818509400a633' then
    raise exception 's122: public.record_inventory_anchor_v1 is neither the body this release was cut from nor the release one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$v_recv numeric; v_moved numeric; v_consumed numeric;$o0$, chr(13), ''), replace($n0$v_recv numeric; v_consumed numeric;$n0$, chr(13), ''));
  v_new := replace(v_new, replace($o1$  -- S122: stock moved between items (move_inventory_stock_v1 and its undo) is a flow between the two counts, like a purchase: units in minus units out
  v_moved := coalesce((select sum(case when m.to_item_id = i.id then m.qty else -m.qty end) from public.inventory_item_moves m
                        where m.kind = 'stock' and (m.to_item_id = i.id or m.from_item_id = i.id) and m.created_at > v_prev.anchor_at and m.created_at <= p_anchor_at), 0);
  v_consumed := v_prev.qty_now + v_recv + v_moved - p_qty_now;$o1$, chr(13), ''), replace($n1$  v_consumed := v_prev.qty_now + v_recv - p_qty_now;$n1$, chr(13), ''));
  v_new := replace(v_new, replace($o2$qty_prev, received_between, moved_between, qty_now, consumed, days,$o2$, chr(13), ''), replace($n2$qty_prev, received_between, qty_now, consumed, days,$n2$, chr(13), ''));
  v_new := replace(v_new, replace($o3$v_prev.qty_now, v_recv, v_moved, p_qty_now, v_consumed, v_days,$o3$, chr(13), ''), replace($n3$v_prev.qty_now, v_recv, p_qty_now, v_consumed, v_days,$n3$, chr(13), ''));
  if md5(v_new) is distinct from 'a8c9099d20a49fa57f266e0c2a73c3eb' then
    raise exception 's122: patching public.record_inventory_anchor_v1 did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_inventory_anchor_v1(p_item_id uuid, p_qty_now numeric, p_anchor_at timestamptz, p_source text) returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_inventory_anchor_v1(uuid, numeric, timestamptz, text) from public, anon, authenticated, service_role;

-- 2. record_missed_refill_v1: back to d0d9cf73fea6e67150d0766bdede7d02
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_missed_refill_v1(uuid,numeric)');
  if v_src is null then raise exception 's122: public.record_missed_refill_v1 is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = 'd0d9cf73fea6e67150d0766bdede7d02' then raise notice 's122: record_missed_refill_v1 already original'; return; end if;
  if v_md5 is distinct from 'eb75c59afba9ac1984fb4b774554b503' then
    raise exception 's122: public.record_missed_refill_v1 is neither the body this release was cut from nor the release one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$v_consumed := x.qty_prev + x.received_between + x.moved_between + p_qty - x.qty_now;$o0$, chr(13), ''), replace($n0$v_consumed := x.qty_prev + x.received_between + p_qty - x.qty_now;$n0$, chr(13), ''));
  v_new := replace(v_new, replace($o1

-- the patched bodies are back: nothing may still depend on the columns and the table
drop function if exists public.get_inventory_item_moves_v1(uuid);
drop function if exists public.undo_inventory_move_v1(uuid, text);
drop function if exists public.move_inventory_usage_v1(uuid, uuid, text);
drop function if exists public.move_inventory_stock_v1(uuid, uuid, numeric, text, text);
drop function if exists public.s_inventory_move_json_v1(uuid, boolean);
drop function if exists public.s_inventory_move_check_v1(public.inventory_items, public.inventory_items);
drop table if exists public.inventory_item_moves;
alter table public.inventory_usage_intervals drop column if exists moved_between;
alter table public.inventory_usage drop column if exists moved_at;
alter table public.inventory_usage drop column if exists moved_from_item_id;

do $$
begin
  if to_regclass('public.inventory_item_moves') is not null
     or exists (select 1 from information_schema.columns where table_schema = 'public' and column_name in ('moved_between', 'moved_from_item_id', 'moved_at')
                  and table_name in ('inventory_usage_intervals', 'inventory_usage')) then
    raise exception 's122 rollback: the table or a column is still there' using errcode = '55000';
  end if;
  if to_regprocedure('public.move_inventory_stock_v1(uuid,uuid,numeric,text,text)') is not null
     or to_regprocedure('public.move_inventory_usage_v1(uuid,uuid,text)') is not null
     or to_regprocedure('public.undo_inventory_move_v1(uuid,text)') is not null
     or to_regprocedure('public.get_inventory_item_moves_v1(uuid)') is not null then
    raise exception 's122 rollback: a move function is still there' using errcode = '55000';
  end if;
end $$;

commit;
minimum', x.qty_now - x.qty_prev - x.received_between - x.moved_between)$o1$, chr(13), ''), replace($n1

-- the patched bodies are back: nothing may still depend on the columns and the table
drop function if exists public.get_inventory_item_moves_v1(uuid);
drop function if exists public.undo_inventory_move_v1(uuid, text);
drop function if exists public.move_inventory_usage_v1(uuid, uuid, text);
drop function if exists public.move_inventory_stock_v1(uuid, uuid, numeric, text, text);
drop function if exists public.s_inventory_move_json_v1(uuid, boolean);
drop function if exists public.s_inventory_move_check_v1(public.inventory_items, public.inventory_items);
drop table if exists public.inventory_item_moves;
alter table public.inventory_usage_intervals drop column if exists moved_between;
alter table public.inventory_usage drop column if exists moved_at;
alter table public.inventory_usage drop column if exists moved_from_item_id;

do $$
begin
  if to_regclass('public.inventory_item_moves') is not null
     or exists (select 1 from information_schema.columns where table_schema = 'public' and column_name in ('moved_between', 'moved_from_item_id', 'moved_at')
                  and table_name in ('inventory_usage_intervals', 'inventory_usage')) then
    raise exception 's122 rollback: the table or a column is still there' using errcode = '55000';
  end if;
  if to_regprocedure('public.move_inventory_stock_v1(uuid,uuid,numeric,text,text)') is not null
     or to_regprocedure('public.move_inventory_usage_v1(uuid,uuid,text)') is not null
     or to_regprocedure('public.undo_inventory_move_v1(uuid,text)') is not null
     or to_regprocedure('public.get_inventory_item_moves_v1(uuid)') is not null then
    raise exception 's122 rollback: a move function is still there' using errcode = '55000';
  end if;
end $$;

commit;
minimum', x.qty_now - x.qty_prev - x.received_between)$n1$, chr(13), ''));
  if md5(v_new) is distinct from 'd0d9cf73fea6e67150d0766bdede7d02' then
    raise exception 's122: patching public.record_missed_refill_v1 did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_missed_refill_v1(p_item_id uuid, p_qty numeric) returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_missed_refill_v1(uuid, numeric) from public, anon, authenticated, service_role;
grant execute on function public.record_missed_refill_v1(uuid, numeric) to authenticated;

-- 3. record_inventory_usage: back to c1c7bff8e55b4aab5528b9fc60a49740
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_inventory_usage(uuid,date,text,text,jsonb)');
  if v_src is null then raise exception 's122: public.record_inventory_usage is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = 'c1c7bff8e55b4aab5528b9fc60a49740' then raise notice 's122: record_inventory_usage already original'; return; end if;
  if v_md5 is distinct from '365f7c6d50258a611612465e4ad3624b' then
    raise exception 's122: public.record_inventory_usage is neither the body this release was cut from nor the release one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$(u.item_id = v_item or u.moved_from_item_id = v_item) and u.notes like '%[key:' || v_usage_key || ']%'$o0$, chr(13), ''), replace($n0$u.item_id = v_item and u.notes like '%[key:' || v_usage_key || ']%'$n0$, chr(13), ''));
  if md5(v_new) is distinct from 'c1c7bff8e55b4aab5528b9fc60a49740' then
    raise exception 's122: patching public.record_inventory_usage did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_inventory_usage(p_property_id uuid, p_session_date date, p_logged_by text, p_notes text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_inventory_usage(uuid, date, text, text, jsonb) from public, anon;
grant execute on function public.record_inventory_usage(uuid, date, text, text, jsonb) to authenticated, service_role;

-- 4. record_restock_v1: back to 490f7db83c6cf1f1dfef72452a4f49e7
do $g$
declare v_src text; v_new text; v_md5 text;
begin
  select replace(pr.prosrc, chr(13), '') into v_src from pg_proc pr where pr.oid = to_regprocedure('public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)');
  if v_src is null then raise exception 's122: public.record_restock_v1 is missing' using errcode = '55000'; end if;
  v_md5 := md5(v_src);
  if v_md5 = '490f7db83c6cf1f1dfef72452a4f49e7' then raise notice 's122: record_restock_v1 already original'; return; end if;
  if v_md5 is distinct from '94a9e42b7b2a439852be3c9ae591010d' then
    raise exception 's122: public.record_restock_v1 is neither the body this release was cut from nor the release one (md5 %): re-cut it from the live body', v_md5 using errcode = '55000';
  end if;
  v_new := v_src;
  v_new := replace(v_new, replace($o0$(u.item_id = v_item or u.moved_from_item_id = v_item) and u.notes like '%[key:' || v_key || ']%'$o0$, chr(13), ''), replace($n0$u.item_id = v_item and u.notes like '%[key:' || v_key || ']%'$n0$, chr(13), ''));
  if md5(v_new) is distinct from '490f7db83c6cf1f1dfef72452a4f49e7' then
    raise exception 's122: patching public.record_restock_v1 did not give the expected body (md5 %)', md5(v_new) using errcode = '55000';
  end if;
  execute format($e$create or replace function public.record_restock_v1(p_property_id uuid, p_session_date date, p_logged_by text, p_notes text, p_rows jsonb, p_remember jsonb, p_upkeep jsonb) returns jsonb language plpgsql volatile security definer set search_path to '' as %L$e$, v_new);
end $g$;
revoke all on function public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb) to authenticated, service_role;

-- the patched bodies are back: nothing may still depend on the columns and the table
drop function if exists public.get_inventory_item_moves_v1(uuid);
drop function if exists public.undo_inventory_move_v1(uuid, text);
drop function if exists public.move_inventory_usage_v1(uuid, uuid, text);
drop function if exists public.move_inventory_stock_v1(uuid, uuid, numeric, text, text);
drop function if exists public.s_inventory_move_json_v1(uuid, boolean);
drop function if exists public.s_inventory_move_check_v1(public.inventory_items, public.inventory_items);
drop table if exists public.inventory_item_moves;
alter table public.inventory_usage_intervals drop column if exists moved_between;
alter table public.inventory_usage drop column if exists moved_at;
alter table public.inventory_usage drop column if exists moved_from_item_id;

do $$
begin
  if to_regclass('public.inventory_item_moves') is not null
     or exists (select 1 from information_schema.columns where table_schema = 'public' and column_name in ('moved_between', 'moved_from_item_id', 'moved_at')
                  and table_name in ('inventory_usage_intervals', 'inventory_usage')) then
    raise exception 's122 rollback: the table or a column is still there' using errcode = '55000';
  end if;
  if to_regprocedure('public.move_inventory_stock_v1(uuid,uuid,numeric,text,text)') is not null
     or to_regprocedure('public.move_inventory_usage_v1(uuid,uuid,text)') is not null
     or to_regprocedure('public.undo_inventory_move_v1(uuid,text)') is not null
     or to_regprocedure('public.get_inventory_item_moves_v1(uuid)') is not null then
    raise exception 's122 rollback: a move function is still there' using errcode = '55000';
  end if;
end $$;

commit;
