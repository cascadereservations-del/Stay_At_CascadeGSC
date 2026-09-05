import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(new URL('../../supabase/migrations/20260905010000_payment_evidence_finance_review.sql', import.meta.url), 'utf8');
const approveBooking = readFileSync(new URL('../../supabase/functions/approve-booking/index.ts', import.meta.url), 'utf8');
const submitBooking = readFileSync(new URL('../../supabase/functions/submit-booking/index.ts', import.meta.url), 'utf8');

test('evidence and comparison entry points cannot invoke the booking decision', () => {
  const evidenceFunction = migration.match(/create or replace function public\.record_payment_evidence_candidate[\s\S]*?\n\$\$;/i)?.[0] ?? '';
  const comparisonFunction = migration.match(/create or replace function public\.compare_booking_payment_evidence[\s\S]*?\n\$\$;/i)?.[0] ?? '';
  assert.ok(evidenceFunction && comparisonFunction);
  assert.doesNotMatch(evidenceFunction + comparisonFunction, /decide_direct_booking\s*\(/i);
  assert.match(migration, /revoke all on function public\.record_payment_finance_review\(uuid,text,text\)[\s\S]*from public, anon, service_role/i);
  assert.match(migration, /grant execute on function public\.record_payment_finance_review\(uuid,text,text\)[\s\S]*to authenticated/i);
});

test('canonical decision requires an immutable named Finance review', () => {
  assert.match(migration, /p_finance_review_id uuid/i);
  assert.match(migration, /named Finance review required/i);
  assert.match(migration, /v_review\.reviewer_user_id/i);
  assert.match(migration, /revoke all on function public\.decide_direct_booking_without_finance_review[\s\S]*service_role/i);
  assert.match(migration, /revoke all on public\.booking_decisions[\s\S]*service_role/i);
  assert.match(migration, /grant execute on function public\.decide_direct_booking\(uuid,text,text,uuid\)[\s\S]*to service_role/i);
});

test('canonical decision verifies the persisted Finance review after the serialized write', () => {
  const reviewedDecision = migration.match(/create or replace function public\.decide_direct_booking\([\s\S]*?\n\$\$;/i)?.[0] ?? '';
  assert.ok(reviewedDecision);
  assert.match(reviewedDecision, /v_result := public\.decide_direct_booking_without_finance_review[\s\S]*update public\.booking_decisions[\s\S]*select \* into v_existing from public\.booking_decisions/i);
  assert.match(reviewedDecision, /v_existing\.finance_review_id is distinct from p_finance_review_id[\s\S]*decision key is linked to another Finance review/i);
});

test('approval source has no signed-link or unauthenticated payment-decision path', () => {
  assert.doesNotMatch(approveBooking, /SIG_PREFIX|hmacHex|timingSafeEqual|searchParams\.get\('sig'\)/);
  assert.match(approveBooking, /record_payment_finance_review/);
  assert.match(approveBooking, /p_finance_review_id/);
  assert.doesNotMatch(submitBooking, /approve-booking:v1:|approve_url:\s*approveUrl|decline_url:\s*declineUrl/);
});

test('Finance evidence remains unavailable to operational roles', () => {
  assert.match(migration, /current_staff_authorized\('read_finance', property_id\)/g);
  assert.doesNotMatch(migration, /read_operations|submit_cleaning|manage_operations/);
  assert.doesNotMatch(migration, /grant (?:select|insert|update|delete|all)[^;]+payment_(?:evidence|finance)[^;]+service_role/is);
});
