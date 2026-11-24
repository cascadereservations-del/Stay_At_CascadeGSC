import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { checkProdSeedGuards, findUnguardedSeeds, loadMigrationFiles } from '../../scripts/ci/check-prod-seed-guards.mjs';

const P = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const manifest = { forward_migrations_from: '20260824002834' };
const check = (files, extra = {}) => checkProdSeedGuards(files, { ...manifest, ...extra });
const NAME = '20260926020000_a.sql';

test('an unguarded insert naming the production property is a violation', () => {
  const sql = `insert into public.rate_x (property_id)\nselect '${P}'\nwhere not exists (select 1 from public.rate_x);\n`;
  assert.deepEqual(check([{ name: NAME, sql }]), [{ file: NAME, firstLine: 'insert into public.rate_x (property_id)' }]);
});

test('an unguarded insert reading an owner out of staff_access_profiles is a violation', () => {
  const sql = "insert into public.t (approved_by)\nselect (select user_id from public.staff_access_profiles where role = 'owner' limit 1);";
  assert.equal(check([{ name: NAME, sql }]).length, 1);
});

test('an insert with an exists-on-properties guard passes', () => {
  const sql = `insert into public.t (property_id)\nselect '${P}'\nwhere exists (select 1 from public.properties where id = '${P}');`;
  assert.deepEqual(check([{ name: NAME, sql }]), []);
});

test('inserts that do not touch production data pass, and so do inserts inside function and DO bodies and comments', () => {
  const sql = [
    'insert into public.t (a) values (1);',
    `create function public.f() returns void language plpgsql as $function$ begin insert into public.t (p) select '${P}'; end $function$;`,
    `do $$ begin insert into public.t (p) select '${P}'; end $$;`,
    `-- insert into public.t select '${P}';`,
  ].join('\n');
  assert.deepEqual(findUnguardedSeeds(sql), []);
});

test('a listed omission, an excluded file and a pre-baseline file are not violations', () => {
  const sql = `insert into public.rate_x (property_id)\nselect '${P}';\n`;
  const first = 'insert into public.rate_x (property_id)';
  assert.deepEqual(check([{ name: NAME, sql }], { recovery_statement_omissions: { [NAME]: [{ first_line: first, sha256: 'x' }] } }), []);
  assert.deepEqual(check([{ name: NAME, sql }], { recovery_excluded_migrations: [NAME] }), []);
  assert.deepEqual(check([{ name: '20260801000000_old.sql', sql }]), []);
  assert.equal(check([{ name: NAME, sql }], { recovery_statement_omissions: { [NAME]: [{ first_line: 'insert into public.other', sha256: 'x' }] } }).length, 1);
});

test('the real migrations pass, and without the manifest omissions only the two rate card seeds fail', () => {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'supabase');
  const real = JSON.parse(readFileSync(path.join(root, 'recovery', 'baseline.json'), 'utf8'));
  const files = loadMigrationFiles(root);
  assert.deepEqual(checkProdSeedGuards(files, real), []);
  const bare = { ...real };
  delete bare.recovery_statement_omissions;
  assert.deepEqual(checkProdSeedGuards(files, bare).map(v => v.file), ['20260926020000_rate_card.sql', '20260926020000_rate_card.sql']);
});
