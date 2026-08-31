import contractDocument from '../../../docs/architecture/degraded-mode-contract.json' with { type: 'json' };

export type DegradedProvider = 'openrouter' | 'n8n' | 'gmail' | 'chatwoot' | 'airbnb';

export type DegradedModeDecision = {
  provider: DegradedProvider;
  correlation_id: string;
  reason_code: string;
  acknowledge: boolean;
  human_review: boolean;
  preserve_canonical_state: boolean;
  retry_policy: string;
  automatic_financial_decision: boolean;
  action: string;
};

type ContractDecision = Omit<DegradedModeDecision, 'provider' | 'correlation_id'>;
const providers = contractDocument.providers as Record<DegradedProvider, ContractDecision>;

export function degradedModeDecision(provider: DegradedProvider, correlationId: string): DegradedModeDecision {
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(correlationId)) throw new TypeError('invalid correlation ID');
  if (!Object.hasOwn(providers, provider)) throw new TypeError('unsupported degraded provider');
  return {
    provider,
    correlation_id: correlationId,
    ...structuredClone(providers[provider]),
  };
}
