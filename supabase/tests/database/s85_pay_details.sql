-- Session 85, lane pay-details: release s85_pay_details_20261019. save_staff_details_v1 takes payout_bank_label and validates payout_qrph;
-- staff_payout_details_v1 reads them for owner/admin only. Hermetic: its own users (uuids d8510000-...). Everything rolls back.
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

insert into auth.users(id, email) values
  ('d8510000-0000-4000-8000-0000000000a1', 'zz85p-honey@example.com'), ('d8510000-0000-4000-8000-0000000000a5', 'zz85p-owner@example.com'),
  ('d8510000-0000-4000-8000-0000000000a4', 'zz85p-finance@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('d8510000-0000-4000-8000-0000000000a1', 'cleaner'), ('d8510000-0000-4000-8000-0000000000a5', 'owner'), ('d8510000-0000-4000-8000-0000000000a4', 'finance');

-- a QR Ph shaped payload: starts 000201, ends 6304 + 4 hex with a valid CRC (s89: the function checks it too)
-- 1. owner saves label and QR, reads them back
select pg_temp.as_user('d8510000-0000-4000-8000-0000000000a5');
insert into _t select 's1', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_bank_label":"  MariBank ","payout_qrph":"00020101021128260012ph.ppmi.p2m0106ZZ85P1520400005303608540510.005802PH5906HONEY 6304D4E0"}'::jsonb, null, 'owner sets payout')$$);
insert into _t select 'r1', pg_temp.try($$select public.staff_payout_details_v1('d8510000-0000-4000-8000-0000000000a1')$$);
-- invalid QR text, wrong type, bad label
insert into _t select 'bq', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_qrph":"hello world"}'::jsonb, null, 'bad qr')$$);
insert into _t select 'bn', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_qrph":12345}'::jsonb, null, 'number qr')$$);
insert into _t select 'be', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_qrph":""}'::jsonb, null, 'empty qr')$$);
insert into _t select 'bl', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', jsonb_build_object('payout_bank_label', repeat('x', 41)), null, 'long label')$$);
insert into _t select 'bs', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_bank_label":"x"}'::jsonb, null, 'short label')$$);
-- nothing changed by the refused saves
insert into _t select 'r2', pg_temp.try($$select public.staff_payout_details_v1('d8510000-0000-4000-8000-0000000000a1')$$);
-- a save without payout keys leaves them alone
insert into _t select 's2', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"contact_number":"09170000000"}'::jsonb, null, 'contact only')$$);
insert into _t select 'r3', pg_temp.try($$select public.staff_payout_details_v1('d8510000-0000-4000-8000-0000000000a1')$$);
-- null clears the QR
insert into _t select 's3', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_qrph":null}'::jsonb, null, 'remove qr')$$);
insert into _t select 'r4', pg_temp.try($$select public.staff_payout_details_v1('d8510000-0000-4000-8000-0000000000a1')$$);
reset role;

-- 2. a cleaner (herself), finance, and anon are refused on both
select pg_temp.as_user('d8510000-0000-4000-8000-0000000000a1');
insert into _t select 'cs', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_bank_label":"Mine"}'::jsonb, null, 'cleaner')$$);
insert into _t select 'cr', pg_temp.try($$select public.staff_payout_details_v1('d8510000-0000-4000-8000-0000000000a1')$$);
reset role;
select pg_temp.as_user('d8510000-0000-4000-8000-0000000000a4');
insert into _t select 'fs', pg_temp.try($$select public.save_staff_details_v1('d8510000-0000-4000-8000-0000000000a1', '{"payout_bank_label":"Fin"}'::jsonb, null, 'finance')$$);
insert into _t select 'fr', pg_temp.try($$select public.staff_payout_details_v1('d8510000-0000-4000-8000-0000000000a1')$$);
reset role;

select is((select v->>'ok' from _t where k = 's1'), 'true', 'owner saves label and QR');
select is((select v->>'payout_bank_label' || '|' || (v->>'has_qr') from _t where k = 'r1'), 'MariBank|true', 'owner reads the trimmed label and has_qr');
select ok((select v->>'qr_payload' like '000201%6304D4E0' from _t where k = 'r1'), 'owner reads the QR payload');
select is((select v->>'err' from _t where k = 'bq'), '22023', 'text that is not a QR Ph payload is refused');
select is((select v->>'err' from _t where k = 'bn'), '22023', 'a non-text QR value is refused');
select is((select v->>'err' from _t where k = 'be'), '22023', 'an empty QR string is refused (null clears)');
select is((select v->>'err' || (select v->>'err' from _t where k = 'bs') from _t where k = 'bl'), '2202322023', 'a label under 2 or over 40 characters is refused');
select is((select v from _t where k = 'r2'), (select v from _t where k = 'r1'), 'refused saves changed nothing');
select is((select v->>'payout_bank_label' || '|' || (v->>'has_qr') from _t where k = 'r3'), 'MariBank|true', 'a save without payout keys leaves them alone');
select is((select v->>'has_qr' || '|' || coalesce(v->>'qr_payload', 'none') from _t where k = 'r4'), 'false|none', 'null clears the QR');
select is((select v->>'err' from _t where k = 'cs'), '42501', 'a cleaner cannot save payout details, even her own');
select is((select v->>'err' from _t where k = 'cr'), '42501', 'a cleaner cannot read payout details, even her own');
select is((select v->>'err' || (select v->>'err' from _t where k = 'fr') from _t where k = 'fs'), '4250142501', 'finance is refused on both');
select ok(not has_function_privilege('anon', 'public.staff_payout_details_v1(uuid)', 'execute'), 'anon cannot read payout details');
select ok(not has_function_privilege('anon', 'public.save_staff_details_v1(uuid,jsonb,integer,text)', 'execute'), 'anon cannot save staff details');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'public.staff_payout_details_v1(uuid)'::regprocedure), 'the read is definer with an empty search_path');
select is((select count(*)::int from public.staff_details_history where user_id = 'd8510000-0000-4000-8000-0000000000a1' and after_state::text like '%000201%'), 0, 'history never holds the QR payload');
select is((select count(*)::int from public.staff_details_history where user_id = 'd8510000-0000-4000-8000-0000000000a1'), 3, 'three accepted saves wrote three history rows');
select ok(has_function_privilege('authenticated', 'public.staff_payout_details_v1(uuid)', 'execute'), 'signed-in users can call the read (the gate is inside)');

select * from finish();
rollback;
