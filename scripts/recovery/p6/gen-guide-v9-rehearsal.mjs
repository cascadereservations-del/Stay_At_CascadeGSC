// Generates the temporary files of the guide v9 rehearsal (s137), for scripts/recovery/p6/guide-v9-rehearsal.sh. Writes temp migrations into supabase/migrations
// (names contain "zzrh" or "zzmut"; the driver deletes them), a temp release contract and a manifest into .rehearsal-logs/harness/. Nothing tracked is modified.
//
// node scripts/recovery/p6/gen-guide-v9-rehearsal.mjs full            apply -> forward checks -> rollback -> checks -> re-apply -> checks, fingerprints compared
// node scripts/recovery/p6/gen-guide-v9-rehearsal.mjs mutant <name>   the same stack with ONE mutated copy of a release migration (the suite must fail)
// node scripts/recovery/p6/gen-guide-v9-rehearsal.mjs list            mutant names
//
// full: the two release migrations are applied FROM THE COMMITTED FILES, the rollbacks run from the COMMITTED rollback files: each temp rollback migration is the committed
// rollback file's bytes followed by check SQL, and the generator asserts that prefix and prints the sha256 of the committed file and of that prefix (they must be equal).
// Order: guide v8 + s136_followups (as in production), snapshot, v9, bound, checks, rollback of bound, rollback of v9, checks, re-apply v9, re-apply bound, checks.
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const R = f => path.join(root, f);
const MIG = 'supabase/migrations/';
const V8 = '20261206000000_guide_v8_messages_analytics.sql', FU = '20261206100000_s136_followups.sql';
const V9 = '20261207000000_guide_v9_secrets.sql', BD = '20261207000100_verify_admin_pin_bound.sql';
const RB9 = 'supabase/rollbacks/20261207_guide_v9_secrets.sql', RBB = 'supabase/rollbacks/20261207_verify_admin_pin_bound.sql';
const CONTRACT = 'supabase/releases/20261207_guide_v9_secrets.release.json';
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const read = f => fs.readFileSync(R(f), 'utf8');

// mutants: [file, find, replace, expected]. Every find must match exactly the stated number of times, else the generator stops (a mutant that changes nothing proves nothing).
const MUT = {
  'R3-secrets-stable': [V9, "create function public.guide_secrets_v1(p_token text) returns jsonb\nlanguage plpgsql volatile", "create function public.guide_secrets_v1(p_token text) returns jsonb\nlanguage plpgsql stable", 1],
  'R4-no-fingerprint-check': [V9, "\n       and s.pin_fp = md5(coalesce((select a.value #>> '{}' from public.app_settings a where a.key = 'admin_pin_hash'), ''));", ";", 1],
  'R4-mint-keeps-stale': [V9, "expires_at <= now() or pin_fp <> v_fp", "expires_at <= now()", 1],
  'old-B-cap-5000': [V9, "if v_live >= 50 then", "if v_live >= 5000 then", 1],
  'old-C-whitelist-wifi': [V9, "'property_lng', 'concierge_mode'])", "'property_lng', 'concierge_mode', 'wifi_password'])", 1],
  'old-D-staff-expiry-off': [V9, " and s.expires_at > now()\n       and s.pin_fp", "\n       and s.pin_fp", 1],
  'old-E-expired-not-deleted': [V9, "expires_at <= now() or pin_fp <> v_fp", "pin_fp <> v_fp", 1],
  'old-F-wifi-from-ssid': [V9, "a.key = 'wifi_password'", "a.key = 'wifi_ssid'", 1],
  'R1a-leftmost-xff': [BD, "btrim(v_xff[cardinality(v_xff)])", "btrim(v_xff[1])", 1],
  'R1a-xff-before-cf': [BD, "array[btrim(v_hdr->>'cf-connecting-ip'), btrim(v_xff[cardinality(v_xff)])]", "array[btrim(v_xff[cardinality(v_xff)]), btrim(v_hdr->>'cf-connecting-ip')]", 1],
  'R1a-header-ignored': [BD, "case when v_addr is not null then 'ip:' || v_addr else", "case when false then 'ip:' || v_addr else", 1],
  'R1a-no-header-ignores-p_client': [BD, "else coalesce(p_client, 'unknown') end", "else 'unknown' end", 1],
  'R1b-empty-code-inserts': [BD, "if p_code is null or length(p_code) = 0 then\n    return jsonb_build_object('ok', false);",
    "if p_code is null or length(p_code) = 0 then\n    insert into public.admin_auth_attempts (ip_hash, succeeded) values (v_ip, false);\n    return jsonb_build_object('ok', false);", 1],
  'R1c-trim-off': [BD, "limit 200 for update skip locked", "limit 0 for update skip locked", 1],
  'R1d-cap-off': [BD, "> 400 then", "> 400000000 then", 2],
  'R1d-cap-off-by-one': [BD, "> 400 then", ">= 400 then", 2],
  'R1d-no-recount': [BD, "  perform pg_advisory_xact_lock(hashtext('verify_admin_pin_attempts'));\n  if (select count(*) from public.admin_auth_attempts where attempted_at > now() - interval '15 minutes') > 400 then\n    return jsonb_build_object('ok', false, 'throttled', true);\n  end if;\n", "  perform pg_advisory_xact_lock(hashtext('verify_admin_pin_attempts'));\n", 1]
};

const [mode, arg] = process.argv.slice(2);
if (mode === 'list') { console.log(Object.keys(MUT).join('\n')); process.exit(0); }
if (mode !== 'full' && mode !== 'mutant') { console.error('usage: full | mutant <name> | list'); process.exit(2); }

const c = JSON.parse(read(CONTRACT));
const written = [];
const put = (name, text) => { fs.writeFileSync(R(MIG + name), text); written.push(MIG + name); };
fs.mkdirSync(R('.rehearsal-logs/harness'), { recursive: true });
let migrations; let label;

if (mode === 'mutant') {
  const m = MUT[arg];
  if (!m) { console.error('unknown mutant ' + arg); process.exit(2); }
  const [file, find, repl, expected] = m;
  const out = {};
  for (const f of [V9, BD]) out[f] = read(MIG + f);
  const n = out[file].split(find).length - 1;
  if (n !== expected) { console.error(`mutant ${arg}: pattern matched ${n} times, expected ${expected}`); process.exit(3); }
  out[file] = out[file].split(find).join(repl);
  put('20261207000000_zzmut_guide_v9_secrets.sql', out[V9]);
  put('20261207000100_zzmut_verify_admin_pin_bound.sql', out[BD]);
  migrations = [V8, FU, '20261207000000_zzmut_guide_v9_secrets.sql', '20261207000100_zzmut_verify_admin_pin_bound.sql'];
  label = 'mutant-' + arg;
} else {
  // forward checks as DO blocks that raise, from the contract (the runner prints them too; these make the cycle stop at the first failure)
  const checks = c.forward_verification.map(v => `do $zz$ begin if not coalesce((${v.query.replace(/\s+/g, ' ')}), false) then raise exception 'forward check failed: ${v.name}'; end if; end $zz$;`).join('\n');
  const vraw = read('supabase/sql/2026-12-07-guide-v9-verify.sql').replace(/^--.*$/gm, '').replace(/begin transaction read only;/, '').replace(/rollback;\s*$/, '').trim().replace(/;$/, '');
  const N = c.forward_verification.length;
  const verify = `do $zz$ declare zzr record; zzn int := 0; begin for zzr in ${vraw} loop zzn := zzn + 1; if not coalesce(zzr.ok, false) then raise exception 'verify.sql check failed: %', zzr."check"; end if; end loop; if zzn <> ${N} then raise exception 'verify.sql returned % rows', zzn; end if; raise notice 'verify.sql executed: % checks ok', zzn; end $zz$;`;
  const SQL_FP = `
create or replace function zzrh.vap() returns text language sql as $f$
  select concat_ws('|', md5(p.prosrc), md5(pg_get_functiondef(p.oid)), p.prosecdef::text, p.provolatile::text, coalesce(p.proconfig::text, ''), coalesce(obj_description(p.oid, 'pg_proc'), ''),
    (select string_agg(coalesce(r.rolname, 'PUBLIC') || ':' || a.privilege_type || ':' || a.is_grantable::text, ',' order by coalesce(r.rolname, 'PUBLIC'), a.privilege_type)
       from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a left join pg_roles r on r.oid = a.grantee where a.grantee <> p.proowner))
  from pg_proc p where p.oid = 'public.verify_admin_pin(text,text)'::regprocedure;
$f$;
create or replace function zzrh.vap_acl() returns text language sql as $f$
  select (select string_agg(coalesce(r.rolname, 'PUBLIC') || ':' || a.privilege_type, ',' order by coalesce(r.rolname, 'PUBLIC'), a.privilege_type)
       from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a left join pg_roles r on r.oid = a.grantee where a.grantee <> p.proowner)
  from pg_proc p where p.oid = 'public.verify_admin_pin(text,text)'::regprocedure;
$f$;
create or replace function zzrh.vap_md5() returns text language sql as $f$ select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.verify_admin_pin(text,text)'::regprocedure $f$;
create or replace function zzrh.aaa_idx() returns text language sql as $f$ select string_agg(indexdef, E'\\n' order by indexname) from pg_indexes where schemaname = 'public' and tablename = 'admin_auth_attempts' and indexname <> 'admin_auth_attempts_attempted_at_idx' $f$;
-- everything the release adds or changes
create or replace function zzrh.fp() returns text language sql as $f$
  select md5(concat_ws('|',
    (select string_agg(pg_get_functiondef(p.oid) || coalesce(p.proacl::text, ''), E'\\n' order by p.proname) from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname in ('guide_staff_session_v1', 'guide_secrets_v1', 'get_public_settings', 'verify_admin_pin')),
    zzrh.vap(),
    (select string_agg(c.relname || ':' || coalesce(c.relacl::text, '') || ':' || c.relrowsecurity::text, E'\\n' order by c.relname) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = 'guide_staff_sessions'),
    (select string_agg(column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, ''), E'\\n' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'guide_staff_sessions'),
    (select string_agg(indexdef, E'\\n' order by indexname) from pg_indexes where schemaname = 'public' and (tablename = 'guide_staff_sessions' or indexname = 'admin_auth_attempts_attempted_at_idx')),
    (select string_agg(pg_get_constraintdef(k.oid), E'\\n' order by k.conname) from pg_constraint k where k.conrelid = to_regclass('public.guide_staff_sessions'))));
$f$;
-- everything the release must NOT change: every other public function, table ACL, default privilege, the schema ACL, the other indexes of admin_auth_attempts
create or replace function zzrh.other_fp() returns text language sql as $f$
  select md5(concat_ws('|',
    (select string_agg(c.relname || ':' || coalesce(c.relacl::text, ''), E'\\n' order by c.relname) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname <> 'guide_staff_sessions' and c.relkind in ('r', 'S', 'v', 'm')),
    (select string_agg(pg_get_functiondef(p.oid) || coalesce(p.proacl::text, ''), E'\\n' order by p.oid::regprocedure::text) from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname not in ('guide_staff_session_v1', 'guide_secrets_v1', 'get_public_settings', 'verify_admin_pin')),
    (select string_agg(coalesce(defaclacl::text, ''), E'\\n' order by oid) from pg_default_acl),
    (select nspacl::text from pg_namespace where nspname = 'public'),
    zzrh.aaa_idx()));
$f$;`;
  const snapshot = `create schema zzrh;
${SQL_FP}
-- the copy is a --no-acl restore: give verify_admin_pin the ACL production has (read 2026-11-25: postgres, anon, authenticated, service_role execute; PUBLIC none) so before and after compare like for like
revoke all on function public.verify_admin_pin(text, text) from public, anon, authenticated, service_role;
grant execute on function public.verify_admin_pin(text, text) to anon, authenticated, service_role;
create table zzrh.s(k text primary key, v text, n bigint);
insert into zzrh.s values ('other', zzrh.other_fp(), 0), ('vap0', zzrh.vap(), 0), ('acl0', zzrh.vap_acl(), 0), ('md50', zzrh.vap_md5(), 0),
  ('tables', 'x', (select count(*) from pg_tables where schemaname = 'public' and tablename <> 'guide_staff_sessions'));
do $zz$ begin
  if to_regclass('public.guide_staff_sessions') is not null or to_regclass('public.admin_auth_attempts_attempted_at_idx') is not null then raise exception 'snapshot: v9 objects already present'; end if;
  if (select v from zzrh.s where k = 'md50') <> 'ca4ade3f91d42574c9176d2331e10f41' then raise exception 'snapshot: the restored verify_admin_pin is not the live body (md5 %)', (select v from zzrh.s where k = 'md50'); end if;
  if (select v from zzrh.s where k = 'acl0') <> 'anon:EXECUTE,authenticated:EXECUTE,service_role:EXECUTE' then raise exception 'snapshot: unexpected verify_admin_pin ACL %', (select v from zzrh.s where k = 'acl0'); end if;
end $zz$;
`;
  const state1 = `${checks}
${verify}
insert into zzrh.s values ('fp1', zzrh.fp(), 0), ('md51', zzrh.vap_md5(), 0), ('acl1', zzrh.vap_acl(), 0);
do $zz$ begin
  if (select v from zzrh.s where k = 'md51') = (select v from zzrh.s where k = 'md50') then raise exception 'state1: verify_admin_pin body did not change'; end if;
  if (select v from zzrh.s where k = 'acl1') <> (select v from zzrh.s where k = 'acl0') then raise exception 'state1: verify_admin_pin ACL differs before and after the apply (% vs %)', (select v from zzrh.s where k = 'acl0'), (select v from zzrh.s where k = 'acl1'); end if;
  if zzrh.other_fp() <> (select v from zzrh.s where k = 'other') then raise exception 'state1: something outside the release changed (other fingerprint)'; end if;
end $zz$;
`;
  const rb9 = fs.readFileSync(R(RB9)), rbb = fs.readFileSync(R(RBB));
  const afterRb = `
do $zz$ begin
  if to_regclass('public.guide_staff_sessions') is not null then raise exception 'rollback: guide_staff_sessions left'; end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('guide_staff_session_v1', 'guide_secrets_v1', 'get_public_settings')) then raise exception 'rollback: a v9 function left'; end if;
  if to_regclass('public.admin_auth_attempts_attempted_at_idx') is not null then raise exception 'rollback: the attempted_at index is left'; end if;
  if zzrh.vap_md5() <> (select v from zzrh.s where k = 'md50') or zzrh.vap_md5() <> 'ca4ade3f91d42574c9176d2331e10f41' then raise exception 'rollback: verify_admin_pin body is not the previous one (md5 %)', zzrh.vap_md5(); end if;
  if zzrh.vap() <> (select v from zzrh.s where k = 'vap0') then raise exception 'rollback: verify_admin_pin (body, definition, attributes, comment, ACL) differs from before the apply'; end if;
  if zzrh.vap_acl() <> (select v from zzrh.s where k = 'acl0') then raise exception 'rollback: verify_admin_pin ACL differs from before the apply'; end if;
  if (select count(*) from pg_tables where schemaname = 'public' and tablename <> 'guide_staff_sessions') <> (select n from zzrh.s where k = 'tables') then raise exception 'rollback: public table count changed'; end if;
  if zzrh.other_fp() <> (select v from zzrh.s where k = 'other') then raise exception 'rollback: something outside the release differs from the snapshot (other fingerprint)'; end if;
end $zz$;
`;
  const state2 = `${checks}
${verify}
do $zz$ begin
  if zzrh.fp() <> (select v from zzrh.s where k = 'fp1') then raise exception 'state2: fingerprint after re-apply differs from the first apply'; end if;
  if zzrh.vap_md5() <> (select v from zzrh.s where k = 'md51') or zzrh.vap_acl() <> (select v from zzrh.s where k = 'acl1') then raise exception 'state2: verify_admin_pin body or ACL differs from the first apply'; end if;
  if zzrh.other_fp() <> (select v from zzrh.s where k = 'other') then raise exception 'state2: non-release fingerprint differs'; end if;
end $zz$;
drop schema zzrh cascade;
`;
  const rbText = Buffer.concat([rbb, Buffer.from('\n'), rb9, Buffer.from(afterRb)]);
  // the committed bytes are the first bytes of the temp migration: print both hashes, stop if they differ
  const head = rbText.subarray(0, rbb.length);
  const rbbPrefixOk = sha(head) === sha(rbb);
  const mid = rbText.subarray(rbb.length + 1, rbb.length + 1 + rb9.length);
  const rb9PrefixOk = sha(mid) === sha(rb9);
  console.error(`rollback bound  committed sha256 ${sha(rbb)}  in temp migration ${sha(head)}  ${rbbPrefixOk ? 'EQUAL' : 'DIFFERENT'}`);
  console.error(`rollback v9     committed sha256 ${sha(rb9)}  in temp migration ${sha(mid)}  ${rb9PrefixOk ? 'EQUAL' : 'DIFFERENT'}`);
  if (!rbbPrefixOk || !rb9PrefixOk) process.exit(4);
  put('20261206999990_zzrh_snapshot.sql', snapshot);
  put('20261207000200_zzrh_state1_forward_checks.sql', state1);
  put('20261207000300_zzrh_rollback_then_checks.sql', rbText.toString('utf8'));
  put('20261207000400_zzrh_reapply_v9.sql', read(MIG + V9));
  put('20261207000500_zzrh_reapply_bound.sql', read(MIG + BD));
  put('20261207000600_zzrh_state2_forward_checks_fingerprint_cleanup.sql', state2);
  migrations = [V8, FU, '20261206999990_zzrh_snapshot.sql', V9, BD, '20261207000200_zzrh_state1_forward_checks.sql', '20261207000300_zzrh_rollback_then_checks.sql',
    '20261207000400_zzrh_reapply_v9.sql', '20261207000500_zzrh_reapply_bound.sql', '20261207000600_zzrh_state2_forward_checks_fingerprint_cleanup.sql'];
  label = 'full';
  console.error(`release migrations applied from the committed files: ${V9} sha256 ${sha(read(MIG + V9))}, ${BD} sha256 ${sha(read(MIG + BD))}`);
}
const tmp = structuredClone(c);
tmp.migrations = migrations;
tmp.migration_sha256 = {};
fs.writeFileSync(R('.rehearsal-logs/harness/tmp-' + label + '.release.json'), JSON.stringify(tmp, null, 2));
fs.writeFileSync(R('.rehearsal-logs/harness/manifest.txt'), written.join('\n') + '\n');
console.log('.rehearsal-logs/harness/tmp-' + label + '.release.json');
