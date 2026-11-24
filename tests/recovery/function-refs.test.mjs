import assert from 'node:assert/strict';
import test from 'node:test';

import { findFunctionGaps, findTestFunctionGaps, loadPreparedPlan, loadTestFiles } from '../../scripts/ci/check-function-refs.mjs';

test('grant on a function no earlier file creates is a gap', () => {
  const gaps = findFunctionGaps([
    { name: 'a.sql', sql: 'create function public.one() returns int language sql as $$ select 1 $$;' },
    { name: 'b.sql', sql: 'revoke execute on function public.two(uuid) from public;\ngrant execute on function public.one() to anon;' },
  ]);
  assert.deepEqual(gaps, [{ file: 'b.sql', fn: 'two' }]);
});

test('quoted pg_dump names, comments and renames are understood', () => {
  const gaps = findFunctionGaps([
    { name: 'a.sql', sql: 'CREATE OR REPLACE FUNCTION "public"."one"("x" "text") RETURNS "int" AS $$ select 1 $$;' },
    { name: 'b.sql', sql: 'alter function public.one(text) rename to uno;\n-- grant execute on function public.ghost() to anon;\ncomment on function public.uno(text) is \'x\';' },
  ]);
  assert.deepEqual(gaps, []);
});

test('the prepared recovery plan has no function reference gaps', () => {
  assert.deepEqual(findFunctionGaps(loadPreparedPlan()), []);
});

test('pgTAP has_function_privilege and regprocedure references are checked against the whole plan', () => {
  const plan = [{ name: 'a.sql', sql: 'create function public.one() returns int language sql as $$ select 1 $$;' }];
  const tests = [{
    name: 't.sql',
    sql: [
      "select ok(has_function_privilege('anon', 'public.one()', 'execute'));",
      "select ok(has_function_privilege('anon', 'public.ghost()', 'execute'));",
      "select ok(not has_function_privilege(current_user, 'public.phantom(uuid, text)', 'execute'));",
      "select 'public.spectre(uuid)'::regprocedure;",
      "-- select has_function_privilege('anon', 'public.commented()', 'execute');",
    ].join('\n'),
  }];
  assert.deepEqual(findTestFunctionGaps(plan, tests).map(gap => gap.fn).sort(), ['ghost', 'phantom', 'spectre']);
});

test('the pgTAP files reference only functions the prepared plan creates', () => {
  assert.deepEqual(findTestFunctionGaps(loadPreparedPlan(), loadTestFiles()), []);
});
