-- Session 89, lane backlog-sql: release s89_backlog_20261024.
-- Part 1: save_staff_details_v1 refuses a QR Ph payload with a bad suffix or a bad CRC (22023, not the table CHECK's 23514) and queues one payout-change
--         notice per real change; qrph_crc16_v1 matches the client algorithm. Part 2: unit_cost keeps 4 decimals, total_cost still 2, the view and its grants
--         are as before, record_inventory_receipt_v1 stores 100 for a pack of 12 as 8.3333 on the purchase and on the item.
-- Hermetic: its own users and property (uuids e8900000-...). Everything rolls back. The md5 guards at the head of the migrations cannot run inside pgTAP;
-- the rehearsal proves them separately.
begin;
select plan(44);

grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
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

insert into auth.users(id, email, raw_user_meta_data) values
  ('e8900000-0000-4000-8000-0000000000a1', 'zz89-honey@example.com', '{"display_name":"Honey Cruz"}'),
  ('e8900000-0000-4000-8000-0000000000a3', 'zz89-admin@example.com', '{"display_name":"Marifel Santos"}'),
  ('e8900000-0000-4000-8000-0000000000a4', 'zz89-finance@example.com', '{}');
insert into public.staff_access_profiles(user_id, role) values
  ('e8900000-0000-4000-8000-0000000000a1', 'cleaner'), ('e8900000-0000-4000-8000-0000000000a3', 'admin'), ('e8900000-0000-4000-8000-0000000000a4', 'finance');
insert into public.properties(id, name, is_active) values ('e8900000-0000-4000-8000-0000000000b0', 'Zz S89 fixture property', true);
insert into public.staff_property_access(user_id, property_id) values
  ('e8900000-0000-4000-8000-0000000000a3', 'e8900000-0000-4000-8000-0000000000b0'), ('e8900000-0000-4000-8000-0000000000a1', 'e8900000-0000-4000-8000-0000000000b0');

-- ============================== Part 1 ==============================
-- the CRC: the standard check string, and a payload built the way the client builds one
select is(public.qrph_crc16_v1('123456789'), '29B1', 'CRC-16/CCITT-FALSE of the standard check string');
select is(public.qrph_crc16_v1('0002010102116304'), 'AD0A', 'CRC of a minimal payload up to and including 6304 (same as C_crc16 in the Staff app)');
select ok(not has_function_privilege('anon', 'public.qrph_crc16_v1(text)', 'execute') and not has_function_privilege('authenticated', 'public.qrph_crc16_v1(text)', 'execute')
  and not has_function_privilege('service_role', 'public.qrph_crc16_v1(text)', 'execute'), 'the CRC helper is internal: no role can call it directly');

-- a good payload (CRC 7424), the same with one character changed and the old CRC kept, bad suffixes
select pg_temp.as_user('e8900000-0000-4000-8000-0000000000a3');
insert into _t select 'ok1', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_bank_label":"MariBank","payout_qrph":"00020101021128260012ph.ppmi.p2m0106ZZ89Q1520400005303608540510.005802PH5906HONEY 63047424"}'::jsonb, null, 'good qr')$$);
insert into _t select 'bad_crc', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"00020101021128260012ph.ppmi.p2m0106ZZ89X1520400005303608540510.005802PH5906HONEY 63047424"}'::jsonb, null, 'tampered')$$);
insert into _t select 'low_hex', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"0002010102116304ad0a"}'::jsonb, null, 'lowercase')$$);
insert into _t select 'no_hex', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"0002010102116304ZZZZ"}'::jsonb, null, 'not hex')$$);
insert into _t select 'no_6304', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"000201010211ABCDEFGH"}'::jsonb, null, 'no 6304')$$);
insert into _t select 'nonascii', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', jsonb_build_object('payout_qrph', '000201010211' || chr(233) || '6304AD0A'), null, 'non ascii')$$);
insert into _t select 'space_end', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"  00020101021128260012ph.ppmi.p2m0106ZZ89Q1520400005303608540510.005802PH5906HONEY 63047424  "}'::jsonb, null, 'padded good qr, same value')$$);
insert into _t select 'ok_clear', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":null}'::jsonb, null, 'clear')$$);
reset role;

select is((select v->>'ok' from _t where k = 'ok1'), 'true', 'a QR with a valid suffix and CRC saves');
select is((select v->>'err' from _t where k = 'bad_crc'), '22023', 'a tampered payload (wrong CRC) is refused with 22023, not a raw check violation');
select ok((select v->>'msg' like '%check characters%' from _t where k = 'bad_crc'), 'the CRC message says what to do');
select is((select v->>'err' from _t where k = 'low_hex'), '22023', 'lowercase hex in the suffix is refused with 22023 (the table CHECK is capital hex)');
select is((select v->>'err' from _t where k = 'no_hex'), '22023', 'a suffix that is not four hex characters is 22023, not 23514');
select is((select v->>'err' from _t where k = 'no_6304'), '22023', 'a payload that does not end 6304 + four hex is 22023');
select is((select v->>'err' from _t where k = 'nonascii'), '22023', 'a non-ASCII payload is refused with 22023, like the client');
select is((select v->>'ok' from _t where k = 'space_end'), 'true', 'surrounding spaces are trimmed before the checks, as before');
select is((select v->>'ok' from _t where k = 'ok_clear'), 'true', 'null still clears the QR');

-- notices: ok1 (qr + label) -> 1 row; refused saves -> none; same value again -> none; clear -> 'removed'
select is((select count(*)::int from public.staff_payout_change_notices where user_id = 'e8900000-0000-4000-8000-0000000000a1'), 2,
  'two real changes (set, then clear) queued two notices; the refused saves and the unchanged re-save queued none');
select is((select finance_text from public.staff_payout_change_notices where user_id = 'e8900000-0000-4000-8000-0000000000a1' and changed_what = 'both'),
  'Honey''s payout QR and bank name was changed by Marifel. Check it before the next payment.', 'the Finance sentence leads with what happened, first names only');
select is((select staff_text from public.staff_payout_change_notices where user_id = 'e8900000-0000-4000-8000-0000000000a1' and changed_what = 'both'),
  'Your payout QR and bank name was changed by Marifel. If this is not right, tell Marifel.', 'her own sentence says the same, with what to do');
select is((select finance_text from public.staff_payout_change_notices where user_id = 'e8900000-0000-4000-8000-0000000000a1' and changed_what = 'qr'),
  'Honey''s payout QR was removed by Marifel. Add a new one before the next payment.', 'removing the QR says removed');
select ok(not exists (select 1 from public.staff_payout_change_notices where finance_text like '%0002%' or staff_text like '%0002%' or finance_text ~ '[0-9]{6}' or staff_text ~ '[0-9]{6}'),
  'no notice holds a QR payload or any long number');
select ok((select bool_and(finance_sent_at is null and staff_sent_at is null) from public.staff_payout_change_notices), 'new notices are unsent');

-- a label-only change, and a no-op label
select pg_temp.as_user('e8900000-0000-4000-8000-0000000000a3');
insert into _t select 'lab', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_bank_label":"GCash"}'::jsonb, null, 'label only')$$);
insert into _t select 'lab_same', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_bank_label":"GCash"}'::jsonb, null, 'label same')$$);
insert into _t select 'contact', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"contact_number":"09170000000"}'::jsonb, null, 'contact only')$$);
reset role;
select is((select count(*)::int from public.staff_payout_change_notices where user_id = 'e8900000-0000-4000-8000-0000000000a1' and changed_what = 'bank_label'), 1,
  'a bank-name change queues one notice; the same name again and a contact-only save queue none');
select is((select finance_text from public.staff_payout_change_notices where changed_what = 'bank_label'), 'Honey''s payout bank name was changed by Marifel. Check it before the next payment.', 'bank-name sentence');
select is((select count(*)::int from public.staff_details_history where user_id = 'e8900000-0000-4000-8000-0000000000a1' and after_state::text like '%000201%'), 0, 'history still never holds the payload');

-- refused roles
select pg_temp.as_user('e8900000-0000-4000-8000-0000000000a1');
insert into _t select 'cleaner', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"0002010102116304AD0A"}'::jsonb, null, 'cleaner')$$);
insert into _t select 'cl_read', pg_temp.try($$select to_jsonb(count(*)) from public.staff_payout_change_notices$$);
reset role;
select pg_temp.as_user('e8900000-0000-4000-8000-0000000000a4');
insert into _t select 'fin', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"0002010102116304AD0A"}'::jsonb, null, 'finance')$$);
insert into _t select 'fin_read', pg_temp.try($$select to_jsonb(count(*)) from public.staff_payout_change_notices$$);
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
select set_config('role', 'anon', true);
insert into _t select 'anon_save', pg_temp.try($$select public.save_staff_details_v1('e8900000-0000-4000-8000-0000000000a1', '{"payout_qrph":"0002010102116304AD0A"}'::jsonb, null, 'anon')$$);
insert into _t select 'anon_read', pg_temp.try($$select to_jsonb(count(*)) from public.staff_payout_change_notices$$);
reset role;
select is((select v->>'err' from _t where k = 'cleaner'), '42501', 'a cleaner cannot save a QR, even her own');
select is((select v->>'err' from _t where k = 'fin'), '42501', 'finance cannot save a QR');
select is((select v->>'err' from _t where k = 'anon_save'), '42501', 'anon cannot call save_staff_details_v1');
select is((select v->>'err' from _t where k = 'cl_read') || (select v->>'err' from _t where k = 'fin_read') || (select v->>'err' from _t where k = 'anon_read'), '425014250142501',
  'cleaner, finance and anon cannot read the notice table');
select ok(not has_table_privilege('authenticated', 'public.staff_payout_change_notices', 'select') and not has_table_privilege('authenticated', 'public.staff_payout_change_notices', 'insert')
  and has_table_privilege('service_role', 'public.staff_payout_change_notices', 'select') and not has_table_privilege('service_role', 'public.staff_payout_change_notices', 'insert')
  and has_column_privilege('service_role', 'public.staff_payout_change_notices', 'finance_sent_at', 'update') and not has_column_privilege('service_role', 'public.staff_payout_change_notices', 'finance_text', 'update'),
  'service_role reads the rows and stamps the sent columns, nothing else');
select ok((select relrowsecurity from pg_class where oid = 'public.staff_payout_change_notices'::regclass), 'row level security is on for the notice table');
select ok((select p.prosecdef and p.proconfig @> array['search_path=""'] from pg_proc p where p.oid = 'public.save_staff_details_v1(uuid,jsonb,integer,text)'::regprocedure)
  and has_function_privilege('authenticated', 'public.save_staff_details_v1(uuid,jsonb,integer,text)', 'execute') and not has_function_privilege('anon', 'public.save_staff_details_v1(uuid,jsonb,integer,text)', 'execute'),
  'save_staff_details_v1 is still definer with an empty search_path, executable by authenticated and not by anon');

-- ============================== Part 2 ==============================
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.inventory_purchases'::regclass and attname = 'unit_cost'), 'numeric(12,4)', 'inventory_purchases.unit_cost is numeric(12,4)');
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.inventory_items'::regclass and attname = 'unit_cost'), 'numeric(12,4)', 'inventory_items.unit_cost is numeric(12,4)');
select is((select format_type(a.atttypid, a.atttypmod) || ' ' || a.attgenerated || ' ' || pg_get_expr(d.adbin, d.adrelid) from pg_attribute a join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
            where a.attrelid = 'public.inventory_purchases'::regclass and a.attname = 'total_cost'), 'numeric(10,2) s (qty * unit_cost)', 'total_cost is still numeric(10,2), stored generated from qty * unit_cost');
select is((select string_agg(attname, ',' order by attnum) from pg_attribute where attrelid = 'public.price_history_by_item'::regclass and attnum > 0 and not attisdropped),
  'item_id,item_name,supplier,unit_cost,purchased_at,recency_rank', 'the view has the same six columns in the same order');
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.price_history_by_item'::regclass and attname = 'unit_cost'), 'numeric(12,4)', 'the view shows the 4 dp price');
select ok((select 'security_invoker=true' = any(reloptions) from pg_class where oid = 'public.price_history_by_item'::regclass), 'the view is still security_invoker');
select ok(not has_table_privilege('anon', 'public.price_history_by_item', 'select') and has_table_privilege('authenticated', 'public.price_history_by_item', 'select')
  and not has_table_privilege('authenticated', 'public.price_history_by_item', 'insert') and not has_table_privilege('authenticated', 'public.price_history_by_item', 'update')
  and not has_table_privilege('authenticated', 'public.price_history_by_item', 'delete') and has_table_privilege('service_role', 'public.price_history_by_item', 'select'),
  'view grants as before: anon nothing, authenticated read only, service_role all');
select is(obj_description('public.price_history_by_item'::regclass), 'Inventory purchase price history ranked newest-first per item.', 'the view comment is back');
select ok((select prosrc like '%nullif(units_per_purchase, 0), 1), 4) end, unit_cost)%' from pg_proc where oid = 'public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)'::regprocedure),
  'record_inventory_receipt_v1 sets the item cost to 4 dp');

insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, units_per_purchase, purchase_unit) values
  ('e8900000-0000-4000-8000-0000000000c1', 'e8900000-0000-4000-8000-0000000000b0', 'Zz89 Rice', 'Pantry', 'pc', 0, true, 12, 'pack');
select pg_temp.as_user('e8900000-0000-4000-8000-0000000000a3');
insert into _t select 'rcpt', pg_temp.try($$select public.record_inventory_receipt_v1('e8900000-0000-4000-8000-0000000000c1', 1, 100, 'Zz89 Store', null, null, null, 'zz89-receipt-key-0001')$$);
select is((select count(*)::int from public.price_history_by_item where item_id = 'e8900000-0000-4000-8000-0000000000c1'), 1, 'a staff member with manage_inventory reads the view through RLS');
reset role;
select is((select v->>'ok' from _t where k = 'rcpt'), 'true', 'the admin records a receipt: 1 pack at PHP 100, 12 per pack');
select is((select unit_cost from public.inventory_purchases where item_id = 'e8900000-0000-4000-8000-0000000000c1'), 8.3333::numeric, 'the purchase keeps PHP 8.3333 per unit, not 8.33');
select is((select total_cost from public.inventory_purchases where item_id = 'e8900000-0000-4000-8000-0000000000c1'), 100.00::numeric, 'total_cost = 12 x 8.3333 = 99.9996, stored to 2 dp as 100.00');
select is((select unit_cost from public.inventory_items where id = 'e8900000-0000-4000-8000-0000000000c1'), 8.3333::numeric, 'the item cost is 8.3333 too');
select is((select unit_cost from public.price_history_by_item where item_id = 'e8900000-0000-4000-8000-0000000000c1'), 8.3333::numeric, 'the view returns the 4 dp price');
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
select set_config('role', 'anon', true);
insert into _t select 'anon_view', pg_temp.try($$select to_jsonb(count(*)) from public.price_history_by_item$$);
reset role;
select is((select v->>'err' from _t where k = 'anon_view'), '42501', 'anon cannot read the view');

select * from finish();
rollback;
