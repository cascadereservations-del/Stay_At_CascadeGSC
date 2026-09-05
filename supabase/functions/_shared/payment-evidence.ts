export type PaymentCandidateInput = {
  source_type: 'receipt_ocr' | 'openrouter_advice' | 'bank_email' | 'manual_evidence';
  source_artifact_id: string;
  content_hash: string;
  parser_version: string;
  observed_at: string;
  amount: number | null;
  currency: string | null;
  reference: string | null;
  confidence: number | null;
  advisory_labels: string[];
  source_admissibility: 'allowlisted' | 'rejected' | 'missing' | 'not_applicable';
  failure_code: string | null;
};

type MailAuthentication = { spf: string; dkim: string; dmarc: string };

export type BankEmailEnvelope = {
  sender: string;
  reply_to?: string | null;
  subject: string;
  message_id: string;
  received_at: string;
  authentication: MailAuthentication;
  amount?: number | null;
  currency?: string | null;
  reference?: string | null;
};

export type BankEmailAllowlist = {
  senders: string[];
  subject_prefixes: string[];
  parser_version: string;
};

export const OPENROUTER_PAYMENT_TASK_PROFILE = 'cascade-payment-receipt-v1';

const asciiEmail = /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}$/;

function normalizeReference(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
  return normalized.length >= 4 && normalized.length <= 64 ? normalized : null;
}

function normalizeCurrency(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toUpperCase();
  return /^[A-Z]{3}$/.test(normalized) ? normalized : null;
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
}

function failedBankCandidate(
  artifactHash: string,
  contentHash: string,
  parserVersion: string,
  receivedAt: string,
  failureCode: string,
  admissibility: 'rejected' | 'missing',
): PaymentCandidateInput {
  return {
    source_type: 'bank_email',
    source_artifact_id: `bankmsg_${artifactHash}`,
    content_hash: contentHash,
    parser_version: parserVersion,
    observed_at: receivedAt,
    amount: null,
    currency: null,
    reference: null,
    confidence: null,
    advisory_labels: ['manual_review_required'],
    source_admissibility: admissibility,
    failure_code: failureCode,
  };
}

export async function minimizeAllowlistedBankEmail(
  envelope: BankEmailEnvelope | null,
  allowlist: BankEmailAllowlist,
): Promise<PaymentCandidateInput> {
  const missingHash = await sha256('missing-bank-message');
  if (!envelope) {
    return failedBankCandidate(missingHash, missingHash, allowlist.parser_version, new Date(0).toISOString(), 'missing_message', 'missing');
  }

  const sender = envelope.sender.trim().toLowerCase();
  const replyTo = envelope.reply_to?.trim().toLowerCase() || sender;
  const receivedAt = new Date(envelope.received_at);
  const safeReceivedAt = Number.isNaN(receivedAt.valueOf()) ? new Date(0).toISOString() : receivedAt.toISOString();
  const artifactHash = await sha256(envelope.message_id);
  const canonical = JSON.stringify({
    message_id_hash: artifactHash,
    received_at: Number.isNaN(receivedAt.valueOf()) ? null : receivedAt.toISOString(),
    amount: envelope.amount ?? null,
    currency: normalizeCurrency(envelope.currency),
    reference: normalizeReference(envelope.reference),
  });
  const contentHash = await sha256(canonical);

  if (!asciiEmail.test(sender)
    || !allowlist.senders.map(value => value.trim().toLowerCase()).includes(sender)
    || replyTo !== sender
    || Object.values(envelope.authentication).some(value => value.toLowerCase() !== 'pass')) {
    return failedBankCandidate(artifactHash, contentHash, allowlist.parser_version, safeReceivedAt, 'sender_not_allowlisted', 'rejected');
  }
  if (!allowlist.subject_prefixes.some(prefix => envelope.subject.startsWith(prefix))) {
    return failedBankCandidate(artifactHash, contentHash, allowlist.parser_version, safeReceivedAt, 'subject_not_allowlisted', 'rejected');
  }
  if (Number.isNaN(receivedAt.valueOf()) || !envelope.message_id || envelope.amount == null || envelope.amount <= 0) {
    return failedBankCandidate(artifactHash, contentHash, allowlist.parser_version, safeReceivedAt, 'malformed_message', 'rejected');
  }

  return {
    source_type: 'bank_email',
    source_artifact_id: `bankmsg_${artifactHash}`,
    content_hash: contentHash,
    parser_version: allowlist.parser_version,
    observed_at: receivedAt.toISOString(),
    amount: envelope.amount,
    currency: normalizeCurrency(envelope.currency),
    reference: normalizeReference(envelope.reference),
    confidence: null,
    advisory_labels: ['allowlisted_bank_message'],
    source_admissibility: 'allowlisted',
    failure_code: null,
  };
}

export async function normalizeOpenRouterReceiptAdvice(
  value: unknown,
  artifactId: string,
  parserVersion: string,
): Promise<PaymentCandidateInput> {
  const input = value as Record<string, unknown> | null;
  const canonical = JSON.stringify(input ?? null);
  const contentHash = await sha256(canonical);
  const observedAt = typeof input?.observed_at === 'string' ? new Date(input.observed_at) : new Date(Number.NaN);
  const safeObservedAt = Number.isNaN(observedAt.valueOf()) ? new Date(0).toISOString() : observedAt.toISOString();
  const base = {
    source_type: 'openrouter_advice' as const,
    source_artifact_id: artifactId,
    content_hash: contentHash,
    parser_version: parserVersion,
    observed_at: safeObservedAt,
    source_admissibility: 'not_applicable' as const,
  };

  const allowedKeys = new Set(['schema_version','task_profile','status','observed_at','amount','currency','reference','confidence','labels']);
  const validShape = input
    && Object.keys(input).every(key => allowedKeys.has(key))
    && input.schema_version === 1
    && input.task_profile === OPENROUTER_PAYMENT_TASK_PROFILE
    && input.status === 'extracted'
    && !Number.isNaN(observedAt.valueOf())
    && typeof input.amount === 'number' && input.amount > 0
    && typeof input.confidence === 'number' && input.confidence >= 0 && input.confidence <= 1
    && Array.isArray(input.labels)
    && input.labels.length <= 12
    && input.labels.every(label => typeof label === 'string' && /^[a-z0-9_]{2,40}$/.test(label));

  if (!validShape) {
    return {
      ...base,
      amount: null, currency: null, reference: null, confidence: null,
      advisory_labels: ['manual_review_required'],
      failure_code: 'schema_invalid',
    };
  }
  return {
    ...base,
    amount: input.amount as number,
    currency: normalizeCurrency(input.currency),
    reference: normalizeReference(input.reference),
    confidence: input.confidence as number,
    advisory_labels: input.labels as string[],
    failure_code: null,
  };
}
