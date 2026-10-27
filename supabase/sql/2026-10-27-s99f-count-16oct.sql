-- 2026-10-27 (session 99f, lane sql): apply Lloyd's handwritten stock count of the printout "Printed 16 Oct 2026, 08:21". NOT a migration; Lloyd's block runs it with
-- scripts/migrations/run-sql-on-host.sh AFTER release s99f_count_as_of_20261103 is applied (it calls telegram_apply_inventory_count_v2). Owner decision D-351.
--
-- A count taken at 16 Oct 08:21 Manila says what was on the shelf then. Cleaner usage and purchases logged since then still happened, so each item becomes
--   counted + (qty_now - qty_at(16 Oct 08:21)),  never below 0 (a clamp is reported in the NOTICE).
-- Acts as Lloyd's Telegram user (staff_access_profiles where role = owner; refuses unless there is exactly one with a Telegram id).
-- NOT changed (unclear on the sheet, D-351): Tea, Tissues / Paper Towels.
--
-- Refuses (raises, nothing written):
--   * release s99f not applied (telegram_apply_inventory_count_v2 or inventory_qty_at_v1 missing)
--   * not exactly one owner with a Telegram id
--   * any counted name that matches no item, or more than one item, of the Cascade property (exact name)
--   * any item that is movement-controlled (v2 refuses it; the whole count aborts)
--   * v2 refuses for any reason (stock_changed, bad_as_of, ...), or any after-check fails
-- IDEMPOTENT: every audit row carries the marker note below. When any telegram_count row with that note exists the script changes nothing (raises a notice).
-- One transaction: either every row lands or none does.

begin;
do $$
declare
  c_prop  constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  c_note  constant text := 'Count of 16 Oct 08:21 printout (Lloyd, s99f)';
  c_asof  constant timestamptz := timestamptz '2026-10-16 08:21:00+08';
  v_tg    bigint;
  v_n     integer;
  v_rows  jsonb := '[]'::jsonb;
  v_res   jsonb;
  v_row   jsonb;
  v_id    uuid;
  v_qty   numeric;
  v_name  text;
  v_cnt   numeric;
  v_after numeric;
  v_audit integer;
begin
  -- a second run is a no-op
  if exists (select 1 from public.inventory_audit_log where action = 'telegram_count' and after ->> 'note' = c_note) then
    raise notice 'already recorded: the count with note "%" is in the audit log; nothing changed', c_note;
    return;
  end if;

  if to_regprocedure('public.telegram_apply_inventory_count_v2(bigint,jsonb,text,timestamptz)') is null
     or to_regprocedure('public.inventory_qty_at_v1(uuid,timestamptz)') is null then
    raise exception 'release s99f_count_as_of_20261103 is not applied (v2 or qty_at missing); nothing changed';
  end if;

  select count(*) into v_n from public.staff_access_profiles where role = 'owner' and telegram_user_id is not null;
  if v_n <> 1 then raise exception '% owner profiles with a Telegram id, expected exactly 1; nothing changed', v_n; end if;
  select telegram_user_id into v_tg from public.staff_access_profiles where role = 'owner' and telegram_user_id is not null;

  -- the sheet, by exact item name
  for v_name, v_cnt in
    select * from (values
      ('Liquid Hand Soap (Safeguard)', 4::numeric),
      ('Breeze Fabric Conditioner Liquid', 38),
      ('Garbage Bags (Small)', 1),
      ('Lysol Disinfectant Spray', 1),
      ('Mr Muscle Glass Cleaner (Blue)', 1),
      ('Natural Air', 1),
      ('Liquid Body Soap (Dove)', 4),
      ('Ambi Pur', 1),
      ('Garbage Bags (Large)', 1),
      ('Mr Muscle Mold & Mildew (Orange)', 3),
      ('Baygon Spray', 3),
      ('Bottled Water', 20),
      ('Coffee (3-in-1)', 17),
      ('Sugar & Creamer Sticks', 10),
      ('Shampoo (Palmolive)', 2),
      ('Dishwashing Liquid (Joy)', 0.5),
      ('Toiletries (toothbrush, toothpaste, soap)', 2)
    ) t(name, counted)
  loop
    select count(*) into v_n from public.inventory_items where property_id = c_prop and name = v_name;
    if v_n <> 1 then raise exception 'item "%" matches % rows in the Cascade property, expected exactly 1; nothing changed', v_name, v_n; end if;
    select id, qty_on_hand into v_id, v_qty from public.inventory_items where property_id = c_prop and name = v_name;
    v_rows := v_rows || jsonb_build_object('item_id', v_id, 'counted', v_cnt, 'expected_before', v_qty);
  end loop;
  if jsonb_array_length(v_rows) <> 17 then raise exception 'expected 17 count rows, built %; nothing changed', jsonb_array_length(v_rows); end if;

  v_res := public.telegram_apply_inventory_count_v2(v_tg, v_rows, c_note, c_asof);
  if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'count refused: %; nothing changed', v_res; end if;
  if (v_res ->> 'updated')::integer <> 17 then raise exception 'count updated % rows, expected 17', v_res ->> 'updated'; end if;

  -- one NOTICE per item, then check every row landed
  for v_row in select * from jsonb_array_elements(v_res -> 'rows') loop
    raise notice '% | counted % | since_delta % | % -> % %', v_row ->> 'name', v_row ->> 'counted', v_row ->> 'since_delta', v_row ->> 'before', v_row ->> 'after',
      case when (v_row ->> 'clamped')::boolean then ' (clamped at 0)' else '' end;
  end loop;

  for v_row in select * from jsonb_array_elements(v_res -> 'rows') loop
    select qty_on_hand into v_after from public.inventory_items where property_id = c_prop and name = v_row ->> 'name';
    if v_after is distinct from (v_row ->> 'after')::numeric then
      raise exception 'after: % is % on the shelf, the count said %', v_row ->> 'name', v_after, v_row ->> 'after';
    end if;
    if (v_row ->> 'after')::numeric < 0 then raise exception 'after: % went negative', v_row ->> 'name'; end if;
  end loop;
  select count(*) into v_audit from public.inventory_audit_log
   where action = 'telegram_count' and after ->> 'note' = c_note and (after ->> 'as_of')::timestamptz = c_asof;
  if v_audit <> 17 then raise exception 'after: % audit rows carry the marker note and the count time, expected 17', v_audit; end if;
  if exists (select 1 from public.inventory_items i join public.inventory_audit_log l on l.entity_id = i.id and l.after ->> 'note' = c_note
              where i.property_id = c_prop and i.name in ('Tea', 'Tissues / Paper Towels')) then
    raise exception 'after: Tea or Tissues / Paper Towels was counted; D-351 leaves them out';
  end if;
  raise notice 's99f count of 16 Oct 08:21 recorded: 17 items, % clamped at 0', (select count(*) from jsonb_array_elements(v_res -> 'rows') e where (e ->> 'clamped')::boolean);
end $$;
commit;

-- Forward checks (all true):
-- select count(*) = 17 from public.inventory_audit_log where action = 'telegram_count' and after ->> 'note' = 'Count of 16 Oct 08:21 printout (Lloyd, s99f)' and (after ->> 'as_of')::timestamptz = '2026-10-16 00:21:00+00';
-- select count(*) = 0 from public.inventory_items i join public.inventory_audit_log a on a.entity_id = i.id and a.after ->> 'note' = 'Count of 16 Oct 08:21 printout (Lloyd, s99f)' where i.name in ('Tea', 'Tissues / Paper Towels');
-- select count(*) = 0 from public.inventory_items where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and qty_on_hand < 0;
