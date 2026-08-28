import test from 'node:test';
import assert from 'node:assert/strict';
import { checkEdgeAuth } from '../../scripts/audit/check-edge-auth.mjs';
import { scanTrackedFiles } from '../../scripts/audit/scan-secrets.mjs';

test('every deployed and local Edge Function has an explicit authority boundary', () => {
  const result = checkEdgeAuth();
  assert.deepEqual(result.errors, []);
  assert.ok(result.entries >= 22);
});

test('known unsafe recovered endpoints remain deployment-blocked', () => {
  const { blocked } = checkEdgeAuth();
  for (const slug of ['last-readings', 'upload-photo', 'submit-cleaning', 'calendar-sync', 'daily-digest', 'rain-alert', 'airbnb-email-sync', 'missed-cleaning-alert']) {
    assert.ok(blocked.includes(slug), `${slug} must not be silently treated as public`);
  }
});

test('tracked source contains no high-confidence credential patterns', () => {
  assert.deepEqual(scanTrackedFiles(), []);
});
