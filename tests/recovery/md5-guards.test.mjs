import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { buildPreparedChain, ALLOWLIST } from '../../scripts/ci/check-md5-guards.mjs';
import {
  bodyMd5,
  normalizeType,
  parseSignatureLiteral,
  simulateMd5Guards,
  splitStatements,
  summarizeMd5Guards,
} from '../../scripts/recovery/md5-guards.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

// md5 of the text between the dollar tags, computed by hand with a reference md5 tool.
const MD5_SELECT_1 = '39c08f9ac64cba938b7de8d1bd6bc0f0'; // "\n  select 1;\n"
const MD5_SELECT_2 = 'd46ae197bc66070e871d301286647ca3'; // "\n  select 2;\n"
const MD5_SELECT_3 = '7c29bddad36f4f6d2f2615f1d100c7d9'; // "select 3"

const base = sql => ({ label: 'base.sql', kind: 'base', sql });
const forward = (label, sql) => ({ label, kind: 'forward', sql });
const rowsFor = (...chain) => simulateMd5Guards(chain);

const guardInline = (sig, hex) => `do $$ begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = '${sig}'::regprocedure) <> '${hex}' then raise exception 'x'; end if;
end $$;`;
const guardInto = (sig, hex) => `do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('${sig}');
  if v_got is distinct from '${hex}' then raise exception 'x'; end if;
end $$;`;

test('the md5 is taken over the text between the dollar tags with carriage returns removed', () => {
  assert.equal(bodyMd5('\r\n  select 1;\r\n'), MD5_SELECT_1);
  assert.equal(bodyMd5('select 3'), MD5_SELECT_3);
});

test('types are normalized to one spelling', () => {
  assert.equal(normalizeType('int4'), 'integer');
  assert.equal(normalizeType('"int4"'), 'integer');
  assert.equal(normalizeType('timestamp with time zone'), 'timestamptz');
  assert.equal(normalizeType('character varying(20)'), 'varchar');
  assert.equal(normalizeType('bool'), 'boolean');
  assert.equal(normalizeType('numeric(10,4)'), 'numeric');
  assert.equal(normalizeType('public.citext'), 'citext');
  assert.equal(normalizeType('"text"[]'), 'text[]');
  assert.equal(normalizeType('double precision'), 'float8');
});

test('a guard signature written with aliases resolves to the same key as the definition', () => {
  assert.equal(parseSignatureLiteral('public.f(int, timestamptz, "text")'), 'public.f(integer,timestamptz,text)');
  assert.equal(parseSignatureLiteral('f(p_a uuid, bool)'), 'public.f(uuid,boolean)');
});

test('the inline guard shape matches a body created earlier, whatever the argument names, defaults and aliases', () => {
  const definition = base(`create or replace function public.f(p_a integer default 5, p_when timestamp with time zone default now(), p_note varchar(20) default 'a,b')
returns void language plpgsql as $$
  select 1;
$$;`);
  const rows = rowsFor(definition, forward('m1.sql', guardInline('public.f(int4,timestamptz,character varying)', MD5_SELECT_1)));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, 'MATCH');
  assert.equal(rows[0].got, MD5_SELECT_1);
  assert.match(rows[0].source, /^base\.sql:\d+$/);
});

test('the select-into guard shape matches and a different expected hash is a DIFF', () => {
  const definition = base('create function public.f(uuid) returns void language sql as $$\n  select 1;\n$$;');
  assert.equal(rowsFor(definition, forward('m1.sql', guardInto('public.f(uuid)', MD5_SELECT_1)))[0].status, 'MATCH');
  const rows = rowsFor(definition, forward('m1.sql', guardInto('public.f(uuid)', MD5_SELECT_2)));
  assert.equal(rows[0].status, 'DIFF');
  assert.equal(rows[0].got, MD5_SELECT_1);
  assert.equal(rows[0].expected, MD5_SELECT_2);
});

test('the most recent definition wins and a CRLF source hashes like an LF one', () => {
  const first = base('create function public.f() returns void language sql as $$\n  select 1;\n$$;');
  const second = forward('m1.sql', 'create or replace function public.f() returns void language sql as $$\r\n  select 2;\r\n$$;');
  const rows = rowsFor(first, second, forward('m2.sql', guardInline('public.f()', MD5_SELECT_2)), forward('m3.sql', guardInline('public.f()', MD5_SELECT_1)));
  assert.deepEqual(rows.map(row => row.status), ['MATCH', 'DIFF']);
  assert.equal(rows[0].source, 'm1.sql:1');
});

test('a function that was never defined, or was dropped, is MISSING', () => {
  assert.equal(rowsFor(forward('m1.sql', guardInline('public.nope()', MD5_SELECT_1)))[0].status, 'MISSING');
  const defined = base('create function public.f(uuid) returns void language sql as $$\n  select 1;\n$$;');
  const dropped = forward('m1.sql', 'drop function if exists public.f(uuid);');
  assert.equal(rowsFor(defined, dropped, forward('m2.sql', guardInto('public.f(uuid)', MD5_SELECT_1)))[0].status, 'MISSING');
});

test('an overload with other argument types is a different function', () => {
  const defined = base('create function public.f(uuid) returns void language sql as $$\n  select 1;\n$$;');
  assert.equal(rowsFor(defined, forward('m1.sql', guardInto('public.f(uuid,text)', MD5_SELECT_1)))[0].status, 'MISSING');
});

test('pg_dump style quoted names, dollar tags with digits and a body that mentions a semicolon are read correctly', () => {
  const dump = base(`CREATE OR REPLACE FUNCTION "public"."f1"("p_id" "uuid", "p_when" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $f1$select 3$f1$;
ALTER FUNCTION "public"."f1"("p_id" "uuid", "p_when" timestamp with time zone) OWNER TO "postgres";`);
  const rows = rowsFor(dump, forward('m1.sql', guardInto('public.f1(uuid,timestamptz)', MD5_SELECT_3)));
  assert.equal(rows[0].status, 'MATCH');
});

test('a comment holding a hash or a signature is not a guard', () => {
  const defined = base('create function public.f() returns void language sql as $$\n  select 1;\n$$;');
  const commented = forward('m1.sql', `-- guard: md5(prosrc) of public.f() is '${MD5_SELECT_2}'\nselect 1;`);
  assert.equal(rowsFor(defined, commented).length, 0);
});

test('an existence check on another function does not take over the hash that follows it', () => {
  const sql = `do $$
declare v_src text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.f(uuid)');
  if to_regprocedure('public.f(uuid,text)') is not null then return; end if;
  if md5(v_src) <> '${MD5_SELECT_1}' then raise exception 'x'; end if;
end $$;`;
  const defined = base('create function public.f(uuid) returns void language sql as $$\n  select 1;\n$$;');
  const rows = rowsFor(defined, forward('m1.sql', sql));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].signature, 'public.f(uuid)');
  assert.equal(rows[0].status, 'MATCH');
});

test('an old-or-new row passes when either signature has its expected body', () => {
  const row = (oldHex, newHex) => `do $g$
declare r record; v text; v2 text;
begin
  for r in select * from (values
    ('public.f(uuid)', '${oldHex}', 'public.f(uuid,text)', '${newHex}')
  ) t(sig_old, m_old, sig_new, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig_old);
    select md5(replace(p.prosrc, chr(13), '')) into v2 from pg_proc p where p.oid = to_regprocedure(r.sig_new);
  end loop;
end $g$;`;
  const defined = base('create function public.f(uuid) returns void language sql as $$\n  select 1;\n$$;');
  const ok = rowsFor(defined, forward('m1.sql', row(MD5_SELECT_1, MD5_SELECT_2)));
  assert.deepEqual(ok.map(item => item.status), ['MATCH']);
  const bad = rowsFor(defined, forward('m1.sql', row(MD5_SELECT_2, MD5_SELECT_3)));
  assert.deepEqual(bad.map(item => item.status), ['DIFF']);
});

test('a body created by an earlier migration is seen, and one created after the guard is not', () => {
  const guard = forward('m1.sql', guardInto('public.f()', MD5_SELECT_1));
  const create = forward('m2.sql', 'create function public.f() returns void language sql as $$\n  select 1;\n$$;');
  assert.equal(rowsFor(guard, create)[0].status, 'MISSING');
  assert.equal(rowsFor(create, forward('m3.sql', guardInto('public.f()', MD5_SELECT_1)))[0].status, 'MATCH');
});

test('a body rewritten at run time cannot be replayed: later guards on it are DYNAMIC, not DIFF', () => {
  const patch = forward('m1.sql', `do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.f(uuid)');
  if md5(v_src) <> '${MD5_SELECT_1}' then raise exception 'x'; end if;
  v_new := replace(v_src, 'select 1', 'select 9');
  execute format($e$create or replace function public.f(p_id uuid) returns void language sql as %L$e$, v_new);
  select md5(replace(p.prosrc, chr(13), '')) into v_src from pg_proc p where p.oid = to_regprocedure('public.f(uuid)');
  if v_src <> '${MD5_SELECT_3}' then raise exception 'post-patch'; end if;
end $g$;`);
  const defined = base('create function public.f(uuid) returns void language sql as $$\n  select 1;\n$$;');
  const rows = rowsFor(defined, patch, forward('m2.sql', guardInto('public.f(uuid)', MD5_SELECT_3)));
  assert.deepEqual(rows.map(row => row.status), ['MATCH', 'DYNAMIC', 'DYNAMIC']);
  assert.deepEqual(summarizeMd5Guards(rows).failing, []);
});

test('the pre-patch guard of a run-time patch is still checked', () => {
  const patch = forward('m1.sql', `do $g$
declare v_src text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.f(uuid)');
  if md5(v_src) <> '${MD5_SELECT_2}' then raise exception 'x'; end if;
  execute format($e$create or replace function public.f(p_id uuid) returns void language sql as %L$e$, v_src);
end $g$;`);
  const defined = base('create function public.f(uuid) returns void language sql as $$\n  select 1;\n$$;');
  assert.deepEqual(rowsFor(defined, patch).map(row => row.status), ['DIFF']);
});

test('only a DIFF or MISSING outside the allowlist fails the run', () => {
  const guard = forward('m1.sql', guardInto('public.nope()', MD5_SELECT_1));
  assert.equal(summarizeMd5Guards(simulateMd5Guards([guard])).failing.length, 1);
  const allowed = simulateMd5Guards([guard], { allowlist: [{ migration: 'm1.sql', signature: 'public.nope()', reason: 'test' }] });
  assert.equal(allowed[0].status, 'MISSING');
  assert.equal(summarizeMd5Guards(allowed).failing.length, 0);
});

test('statements are split on top-level semicolons only', () => {
  const statements = splitStatements("select ';'; /* a; b */ do $x1$ begin perform 1; end $x1$; -- c; d\nselect 2;");
  assert.equal(statements.length, 3);
  assert.equal(statements[1].segments[0].content, ' begin perform 1; end ');
});

test('the real prepared chain: every md5 guard matches or is patched at run time, and the hand-verified guards match', () => {
  const rows = simulateMd5Guards(buildPreparedChain(path.join(repoRoot, 'supabase')), { allowlist: ALLOWLIST });
  assert.ok(rows.length > 100);
  assert.deepEqual(summarizeMd5Guards(rows).failing.map(row => `${row.migration}:${row.signature}`), []);
  const find = (migration, fn) => rows.find(row => row.migration.startsWith(migration) && row.signature.includes(fn));
  assert.equal(find('20261015010000_s82_checklist', 'get_cleanable_bookings').status, 'MATCH');
  assert.equal(find('20261015010000_s82_checklist', 'get_cleanable_bookings').got.slice(0, 8), '7306b530');
  assert.equal(find('20261015010000_s82_checklist', 'get_booking_for_date').got.slice(0, 8), 'e1202ee7');
  assert.equal(find('20261017010000_s84_calendar', 'admin_stays_v1').got.slice(0, 8), 'e2f41dcc');
  assert.equal(find('20261017010000_s84_calendar', 'staff_pay_admin_step_v1').got.slice(0, 8), 'ee76bfac');
});
