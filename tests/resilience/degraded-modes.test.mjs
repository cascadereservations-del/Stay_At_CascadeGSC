import test from 'node:test';
import assert from 'node:assert/strict';

const contract = {
  openrouter: 'acknowledge and create human-review task; never fabricate an answer',
  n8n: 'retain canonical outbox event for retry; never roll back a confirmed booking',
  gmail: 'allow manual payment review; missing email is not non-payment',
  chatwoot: 'handoff to owner/admin without auto-reply loop',
  airbnb: 'preserve existing calendar blocks; require manual review if feed health is stale',
};

test('degraded-mode contract has a non-destructive path for every provider', () => {
  for (const [provider, action] of Object.entries(contract)) {
    assert.match(action, /never|manual|retain|preserve|handoff/i, provider);
  }
});
