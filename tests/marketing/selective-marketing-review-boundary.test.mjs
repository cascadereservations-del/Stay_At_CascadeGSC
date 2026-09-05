import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migrationPath = new URL('../../supabase/migrations/20260905090000_selective_marketing_review.sql', import.meta.url);
const rollbackPath = new URL('../../supabase/rollbacks/20260905090000_selective_marketing_review.sql', import.meta.url);
const sql = await readFile(migrationPath, 'utf8');
const rollback = await readFile(rollbackPath, 'utf8');

test('drafts retain ciphertext and hashes without guest contact or delivery state', () => {
  assert.match(sql, /content_ciphertext text not null/);
  assert.match(sql, /content_hash text not null/);
  assert.doesNotMatch(sql, /recipient_email|recipient_phone|provider_message_id|insert into public\.automation_outbox/i);
});

test('draft and approval recheck purpose-specific marketing eligibility', () => {
  assert.equal((sql.match(/public\.crm_marketing_eligible\(/g) ?? []).length, 2);
  assert.match(sql, /marketing consent or lifecycle no longer eligible/);
  assert.match(sql, /p_content_hash is distinct from v_draft\.content_hash/);
});

test('named AAL2 owner or admin remains the authority', () => {
  assert.match(sql, /public\.crm_human_authorized\(v_profile\.property_id\)/);
  assert.match(sql, /public\.crm_human_authorized\(v_draft\.property_id\)/);
  assert.match(sql, /reviewed_by_user_id uuid not null references auth\.users/);
  assert.match(sql, /revoke all on function[\s\S]+from public, anon, service_role/);
});

test('targeting, discounts, and claims require explicit review while publication stays false', () => {
  assert.match(sql, /not coalesce\(p_targeting_approved, false\)/);
  assert.match(sql, /v_draft\.includes_discount and not coalesce\(p_discount_approved, false\)/);
  assert.match(sql, /v_draft\.includes_claim and not coalesce\(p_claim_approved, false\)/);
  assert.match(sql, /publication_authorized boolean not null default false check \(not publication_authorized\)/);
  assert.doesNotMatch(sql, /fetch\s*\(|http_post|net\.http|send_message/i);
});

test('rollback removes only Wave 7 objects', () => {
  assert.match(rollback, /drop table public\.marketing_draft_reviews/);
  assert.match(rollback, /drop table public\.marketing_drafts/);
  assert.doesNotMatch(rollback, /cascade|crm_guest_profiles|crm_consent_events/i);
});
