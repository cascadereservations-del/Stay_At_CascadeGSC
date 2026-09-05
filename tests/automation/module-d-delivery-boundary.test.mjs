import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const detail = await readFile(new URL('../../supabase/functions/automation-event-detail/logic.ts', import.meta.url), 'utf8');
const detailEndpoint = await readFile(new URL('../../supabase/functions/automation-event-detail/index.ts', import.meta.url), 'utf8');
const callback = await readFile(new URL('../../supabase/functions/automation-callback/index.ts', import.meta.url), 'utf8');
const migration = await readFile(new URL('../../supabase/migrations/20260905020000_payment_review_queue.sql', import.meta.url), 'utf8');

test('workflow detail uses a closed event/workflow/audience matrix', () => {
  for (const workflow of ['CH-W01', 'CH-W02', 'CH-W03', 'CH-W09', 'CH-W10', 'CH-W11']) assert.match(detail, new RegExp(workflow));
  assert.match(detail, /audience === 'finance'/);
  assert.match(detail, /audience === 'guest'/);
  assert.match(detailEndpoint, /buildEventDetail/);
  assert.doesNotMatch(detailEndpoint, /detail\.total_amount|detail\.guest_email/);
});

test('OPS/internal payload construction contains no financial or guest-contact fields', () => {
  const internalBranch = detail.slice(detail.indexOf("if (event.event_type === 'calendar.projection_requested')"));
  assert.doesNotMatch(internalBranch, /total_amount|deposit_amount|guest_email|guest_phone/);
});

test('signed callbacks delegate only to idempotent delivery-state RPC', () => {
  assert.match(callback, /verifyAutomationSignature/);
  assert.match(callback, /record_automation_delivery_callback/);
  assert.match(migration, /callback_id[\s\S]*unique index/i);
  assert.match(migration, /attempt_count = attempt_count \+ 1/);
  assert.doesNotMatch(callback, /booking_inquiries|payment_finance_reviews|calendar_events|transactions/);
  const callbackFunction = migration.slice(migration.indexOf('create or replace function public.record_automation_delivery_callback'));
  assert.doesNotMatch(callbackFunction, /update public\.(?:booking_inquiries|payment_finance_reviews|calendar_events|transactions)/i);
});
