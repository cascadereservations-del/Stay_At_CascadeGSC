import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');

test('cleaner Edge Functions require named staff authorization', () => {
  for (const slug of ['last-readings', 'upload-photo', 'submit-cleaning']) {
    const source = read(`supabase/functions/${slug}/index.ts`);
    assert.match(source, /requireStaffAccess\(/, `${slug} must authorize named staff`);
  }
  assert.match(read('supabase/functions/last-readings/index.ts'), /\.eq\('property_id', propertyId\)/);
  assert.match(read('supabase/functions/upload-photo/index.ts'), /createSignedUrl/);
  assert.doesNotMatch(read('supabase/functions/upload-photo/index.ts'), /getPublicUrl/);
});

test('cleaner expenses cannot create confirmed transactions', () => {
  const source = read('supabase/functions/submit-cleaning/index.ts');
  assert.match(source, /cleaning_expense_claims/);
  assert.match(source, /pending_review/);
  assert.doesNotMatch(source, /from\('transactions'\)\.insert/);
  assert.doesNotMatch(source, /status:\s*'confirmed'/);
});

test('migration removes anonymous operational and photo access', () => {
  const sql = read('supabase/migrations/20260830002347_named_cleaner_access_boundary.sql');
  assert.match(sql, /revoke all on table public\.inventory_usage from anon/);
  assert.match(sql, /values \([\s\S]*?false,[\s\S]*?on conflict \(id\) do update[\s\S]*?set public = excluded\.public/);
  assert.match(sql, /drop policy if exists "anon upload cleaning photos"/);
  assert.match(sql, /submitted_by_user_id = auth\.uid\(\)/);
});
