// deno test supabase/functions/telegram-expense/refund.test.ts - SPEC-42 item 9a: /refund goes only to the account that paid (invariant I3).
// Pure helpers for handleRefundCommand: reference parsing, the payer match, the reason gate and the card. No I/O here.
// D-306: a refund is booking money. /refund runs in the Finance group only; nothing in this file is ever sent to OPS.

export const DIFFERENT_ACCOUNT = 'different account:';

// DIR-1A2B3C4D or a bare 8-character id prefix. `explicit` is true when the DIR- prefix was typed.
export function parseDirRef(token: string): { prefix: string; explicit: boolean } | null {
  const m = /^(DIR-)?([0-9a-f]{8})$/i.exec(String(token ?? '').trim());
  return m ? { prefix: m[2].toLowerCase(), explicit: !!m[1] } : null;
}

// Case, accents, punctuation and spacing folded away: "Juan  dela-Cruz" and "JUAN DELA CRUZ" are the same payer.
export function foldName(s: unknown): string {
  return String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

// The note a host types after the second pipe must start with "different account:" and say why.
export function differentAccountReason(note: string | null | undefined): string | null {
  const n = String(note ?? '').trim();
  if (!n.toLowerCase().startsWith(DIFFERENT_ACCOUNT)) return null;
  const why = n.slice(DIFFERENT_ACCOUNT.length).trim();
  return why.length >= 3 ? why : null;
}

export type Payer = { name: string | null; channel: string | null };
export type Gate = { state: 'match' | 'mismatch' | 'unknown' | 'reasoned'; canConfirm: boolean; warning: string | null };

// Direct bookings only. A recipient that folds to the payer's name passes. Anything else (or no payer on record, which cannot be
// shown to match) needs the reason; with it the refund can go ahead and the reason is saved in the ledger notes.
export function refundGate(recipient: string, payer: Payer, note: string | null | undefined): Gate {
  const known = foldName(payer.name) !== '';
  if (known && foldName(recipient) === foldName(payer.name)) return { state: 'match', canConfirm: true, warning: null };
  if (differentAccountReason(note)) return { state: 'reasoned', canConfirm: true, warning: null };
  const warning = known
    ? '⚠️ Not the paying account. A refund goes back to the account that paid.'
    : '⚠️ No paying account is on record for this booking, so the recipient cannot be checked. A refund goes back to the account that paid.';
  return { state: known ? 'mismatch' : 'unknown', canConfirm: false, warning };
}

export const DIFFERENT_ACCOUNT_HINT = 'To send it elsewhere, add a note after the second bar that starts with `different account:` and says why.';

// The card for a refund. `lines` are the facts already built by the caller; this adds the payer line, the warning and the buttons.
// A Confirm button is only ever shown when it can work: the gate is open AND the pending row was saved. If the save failed, the card
// says nothing was saved (the old card showed Confirm with an empty id and the tap consumed nothing).
export function refundCard(
  lines: string[],
  gate: Gate,
  pid: string,
  nothingChanged: (verb: string, why: string) => string,
  mdEsc: (s: unknown) => string,
  payer: Payer | null,
): { text: string; keyboard: { text: string; callback_data: string }[][] | null } {
  const out = [...lines];
  if (payer) out.push(`Paid from: ${payer.name ? mdEsc(payer.name) : '_not recorded_'}${payer.channel ? ` · ${mdEsc(payer.channel)}` : ''}`);
  if (gate.warning) out.push('', gate.warning, DIFFERENT_ACCOUNT_HINT);
  if (!gate.canConfirm) return { text: out.join('\n'), keyboard: null };
  if (!pid) return { text: out.join('\n') + '\n' + nothingChanged('prepare the refund', 'The confirmation could not be saved. Send the command again.'), keyboard: null };
  return {
    text: out.join('\n'),
    keyboard: [[{ text: '✅ Confirm Refund', callback_data: `refund_ok:${pid}` }, { text: '❌ Cancel', callback_data: `llm_cancel:${pid}` }]],
  };
}
