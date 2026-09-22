// telegram-cassy policy (2026-09-13, D-104). Pure functions, code-owned, proven in policy.test.ts.
export type Surface = 'finance' | 'ops';
export type GateEnv = { financeChat: string; opsChat: string; dmUserIds: string[] };
export type Gate = { allowed: false; reason: string } | { allowed: true; surface: Surface };

/** Chat membership is the access control (D-070). DMs only from allowlisted Telegram ids; a DM is finance. */
export function gate(chatId: unknown, chatType: unknown, fromId: unknown, env: GateEnv): Gate {
  const c = String(chatId ?? ''), f = String(fromId ?? '');
  if (env.financeChat && c === env.financeChat) return { allowed: true, surface: 'finance' };
  if (env.opsChat && c === env.opsChat) return { allowed: true, surface: 'ops' };
  if (chatType === 'private' && f && env.dmUserIds.includes(f)) return { allowed: true, surface: 'finance' };
  return { allowed: false, reason: chatType === 'private' ? 'dm_not_allowlisted' : 'chat_not_allowed' };
}

/** The message must address Cassy by name; returns the question without the address, or null. */
export function addressed(text: string): string | null {
  const m = /^\s*@?cassy\b[\s,:!.-]*/i.exec(text);
  if (!m) return null;
  const q = text.slice(m[0].length).trim();
  return q || 'status';
}

/** Forwarded text (deploy 3): drop a leading "cassy" or an @bot mention anywhere; null when nothing is left. */
export function unmention(text: string): string | null {
  const q = (addressed(text) ?? text).replace(/@\w+bot\b/gi, '').replace(/\s+/g, ' ').trim();
  return q || null;
}

/** Deep tier (deploy 4): an explicit "/deep" anywhere at the start (before or after the address) escalates.
 *  ponytail: explicit flag only; add the intent classifier from D-070 when routine answers prove too shallow. */
export function deepRequest(text: string): { deep: boolean; text: string } {
  const re = /(^|\s)\/deep(@\w+)?\b/i;
  return re.test(text) ? { deep: true, text: text.replace(re, ' ').replace(/\s+/g, ' ').trim() } : { deep: false, text };
}

/** Daily cap on deep answers, counted per Manila day in app_settings. */
export function deepAllowed(usedToday: number, cap: number): boolean {
  return Number.isFinite(cap) && cap > 0 && usedToday < cap;
}

/** Code-owned intent: money spent, with an amount, in the finance chat → log_expense must be called. */
const SPENT_RE = /\b(bought|buy|paid|pay|spent|spend|binili|bili|nagbayad|bayad|gastos|nagastos|purchase[d]?|expense)\b/i;
const AMOUNT_RE = /(?:₱|php\s?|p\s?)\d[\d,]*(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:pesos?|php|k\b)/i;
export function wantsExpense(text: string, surface: Surface): boolean {
  return surface === 'finance' && SPENT_RE.test(text) && AMOUNT_RE.test(text);
}

/** Code owns the truth about cards: without one, "tap the card" wording is replaced. */
export function honestAboutCard(r: { decision: string; lines: string[]; action: string }, cardSent: boolean) {
  if (cardSent) return r;
  const lines = r.lines.filter((l) => !/\bcard\b/i.test(l));
  const claims = /\bcard\b/i.test(r.decision + ' ' + r.action);
  if (!claims && lines.length === r.lines.length) return r;
  // A leftover "tap the card" after a read-only answer is stale history; a card claim on a write is a lie.
  const writeClaim = /\b(log|logged|record|recorded|save|saved|schedule|scheduled|confirm)\b/i.test(r.decision);
  const action = /\bcard\b/i.test(r.action) ? (writeClaim ? 'No card was sent. Say the amount and category again, e.g. "bought water 500".' : '') : r.action;
  return { decision: r.decision.replace(/\bcard\b/gi, 'entry'), lines, action };
}

const MONEY_KEY = /amount|payout|revenue|cost|total|price|earn|fee|php|peso|balance/i;
/** Ops surface never sees money: delete money-named keys anywhere in a tool result (code, not prompt). */
export function stripMoney(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(stripMoney);
  if (v && typeof v === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) if (!MONEY_KEY.test(k)) out[k] = stripMoney(val);
    return out;
  }
  return v;
}

/** SPEC-23 (D-215): a stock list may only appear when a stock tool ran this turn. Found live 2026-09-22:
 *  "list Ashley's stays" answered with five low-stock bullets copied from the previous reply in history. */
const STOCK_LINE = /\b(stock|reorder|reorder point|refill|pcs?\b|bottles?|left\b|low\b)/i;
export function onlyAskedFor(r: { decision: string; lines: string[]; action: string }, toolCalls: string[]) {
  if (toolCalls.some((t) => t === 'low_stock' || t === 'inventory_report')) return r;
  return { ...r, lines: r.lines.filter((l) => !STOCK_LINE.test(l)) };
}

/** What a turn leaves in history: the decision only. Rendered bullets replayed as history read to the model
 *  as its own last answer, and a rigid JSON contract then reuses them for an unrelated question. */
export function memoOf(r: { decision: string; lines: string[]; action: string }): string {
  return (r.decision || r.lines[0] || '').trim();
}
