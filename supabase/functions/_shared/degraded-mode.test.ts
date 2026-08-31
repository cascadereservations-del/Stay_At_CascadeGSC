import { degradedModeDecision } from './degraded-mode.ts';

type Provider = 'openrouter' | 'n8n' | 'gmail' | 'chatwoot' | 'airbnb';
type Decision = {
  provider: Provider;
  correlation_id: string;
  reason_code: string;
  acknowledge: true;
  human_review: boolean;
  preserve_canonical_state: true;
  retry_policy: string;
  automatic_financial_decision: false;
  action: string;
};
type Api = { degradedModeDecision: (provider: Provider, correlationId: string) => Decision };
const api = { degradedModeDecision } as Api;

const expectations: Record<Provider, string> = {
  openrouter: 'create_human_review_without_fabricating_output',
  n8n: 'retain_canonical_outbox_event_and_retry_idempotently',
  gmail: 'allow_manual_evidence_review_without_nonpayment_inference',
  chatwoot: 'stop_automated_replies_and_prevent_webhook_echo',
  airbnb: 'preserve_calendar_blocks_and_require_manual_review',
};

Deno.test('simulates every provider failure with a deterministic safe decision', async () => {
  for (const [provider, action] of Object.entries(expectations) as [Provider, string][]) {
    const decision = api.degradedModeDecision(provider, 'cascade_outage_1234');
    if (decision.provider !== provider || decision.action !== action) throw new Error(`${provider}: action mismatch`);
    if (decision.correlation_id !== 'cascade_outage_1234') throw new Error(`${provider}: correlation mismatch`);
    if (!decision.acknowledge || !decision.preserve_canonical_state) throw new Error(`${provider}: destructive decision`);
    if (decision.automatic_financial_decision) throw new Error(`${provider}: automatic financial decision`);
  }
});

Deno.test('rejects unknown providers and unsafe correlation IDs', async () => {
  let providerRejected = false;
  let correlationRejected = false;
  try { api.degradedModeDecision('unknown' as Provider, 'cascade_outage_1234'); } catch { providerRejected = true; }
  try { api.degradedModeDecision('gmail', 'bad id'); } catch { correlationRejected = true; }
  if (!providerRejected || !correlationRejected) throw new Error('closed degraded-mode boundary failed');
});

Deno.test('returns defensive copies of provider decisions', async () => {
  const first = api.degradedModeDecision('n8n', 'cascade_outage_1234');
  (first as unknown as Record<string, unknown>).action = 'unsafe';
  const second = api.degradedModeDecision('n8n', 'cascade_outage_1234');
  if (second.action !== expectations.n8n) throw new Error('contract state was mutated');
});
