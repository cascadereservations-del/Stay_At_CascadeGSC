import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../../supabase/migrations/20260828000400_staff_roles_and_sessions.sql', import.meta.url), 'utf8');
const operationalSql = readFileSync(new URL('../../supabase/migrations/20260828000500_db_backed_operational_authorization.sql', import.meta.url), 'utf8');
const config = readFileSync(new URL('../../supabase/config.toml', import.meta.url), 'utf8');

test('local auth enables TOTP enrollment and verification for AAL2 tests', () => {
  const totp = config.match(/^\[auth\.mfa\.totp\]\s*$([\s\S]*?)(?=^\[|\z)/im)?.[1] ?? '';
  assert.match(totp, /^\s*enroll_enabled\s*=\s*true\s*$/im);
  assert.match(totp, /^\s*verify_enabled\s*=\s*true\s*$/im);
});

test('normalizes staff property scope and keeps audit append-only', () => {
  assert.match(sql, /create table public\.staff_property_access/i);
  assert.doesNotMatch(sql, /grant all on public\.staff_access_profiles, public\.staff_access_audit/i);
  assert.match(sql, /grant select, insert on public\.staff_access_audit to service_role/i);
});

test('management RPC derives actor, MFA and session state from verified JWT context', () => {
  assert.match(sql, /create or replace function public\.manage_staff_access/i);
  assert.match(sql, /auth\.uid\(\)/i);
  assert.match(sql, /auth\.jwt\(\).*aal/is);
  assert.match(sql, /sessions_revoked_after/is);
  assert.match(sql, /auth\.jwt\(\)\s*->>\s*'aal'\s+is distinct from\s+'aal2'/i);
  assert.match(sql, /p_property_id is not null/is);
});

test('self-service profile RPC exposes only the authenticated staff record and current session state', () => {
  assert.match(sql, /create or replace function public\.current_staff_access\(\)/i);
  assert.match(sql, /where p\.user_id = auth\.uid\(\)/is);
  assert.match(sql, /'session_current'/i);
  assert.match(sql, /grant execute on function public\.current_staff_access\(\) to authenticated/i);
  assert.doesNotMatch(sql, /grant execute on function public\.current_staff_access\(\) to (?:anon|service_role)/i);
});

test('role changes synchronize immutable auth metadata in the same transaction', () => {
  assert.match(sql, /update auth\.users/is);
  assert.match(sql, /raw_app_meta_data/is);
  assert.match(sql, /staff_access_audit/is);
});

test('bootstrap is not exposed to client roles', () => {
  assert.match(sql, /revoke all on function public\.bootstrap_cascade_owner/is);
  assert.doesNotMatch(sql, /grant execute on function public\.bootstrap_cascade_owner[^;]+(?:anon|authenticated|service_role)/is);
});

test('operational policies use DB-backed staff state instead of JWT role claims', () => {
  assert.match(operationalSql, /from public\.staff_access_profiles p/is);
  assert.match(operationalSql, /p\.disabled_at is null/is);
  assert.match(operationalSql, /sessions_revoked_after/is);
  assert.match(operationalSql, /public\.current_staff_authorized\('read_operations', property_id\)/i);
  assert.match(operationalSql, /public\.current_staff_authorized\('submit_cleaning', property_id\)/i);
  assert.doesNotMatch(operationalSql, /auth\.jwt\(\)\s*->\s*'app_metadata'\s*->>\s*'role'/i);
});
