// cascade-core format (Cassy, 2026-09-13, D-104). The ADHD/ELI5 report shape, owned by code:
// one decision line, at most five lines, one action, then the model that answered.
export type Report = { decision: string; lines: string[]; action: string };

// Models like to number their lines; the bullet is ours, so "1. ", "1) " and leading "• " are dropped.
const clean = (s: unknown) => String(s ?? '').replace(/\s+/g, ' ').trim().replace(/^(?:[•\-*]\s*)?(?:\d{1,2}[.)]\s+)?/, '');

/** Lenient parse of the model's final text: JSON (fenced or bare) first, else first line = decision. */
export function parseReport(text: string): Report {
  const raw = text.replace(/^```(?:json)?\s*|\s*```$/g, '').trim();
  const start = raw.indexOf('{'), end = raw.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      const j = JSON.parse(raw.slice(start, end + 1));
      const lines = Array.isArray(j.lines) ? j.lines.map(clean).filter(Boolean) : clean(j.lines) ? [clean(j.lines)] : [];
      const decision = clean(j.decision);
      // A JSON blob without our keys (a model quoting data) is not a report; read the text instead.
      if (decision || lines.length) return { decision, lines, action: clean(j.action) };
    } catch { /* fall through to plain text */ }
  }
  // Plain text or "decision: … / lines: … / action: …" pseudo-YAML (seen live from flash, 2026-09-13).
  const ls = raw.replace(/[{}[\]"]/g, ' ').split(/\r?\n/).map(clean).filter(Boolean);
  let decision = '', action = '';
  const lines: string[] = [];
  for (const l of ls) {
    const m = /^(decision|lines|action)\s*:\s*(.*)$/i.exec(l);
    if (m) {
      const v = clean(m[2].replace(/^['"]|['"]$/g, ''));
      if (m[1].toLowerCase() === 'decision') decision = v;
      else if (m[1].toLowerCase() === 'action') action = v;
      else if (v) lines.push(v);
      continue;
    }
    const v = clean(l.replace(/^['"]|['"],?$/g, ''));
    if (!decision) decision = v; else lines.push(v);
  }
  return { decision, lines, action };
}

/** Model line names who answered; code-built reports (daily-digest) pass '' and get no signature. */
export function renderReport(r: Report, model = ''): string {
  const out: string[] = [r.decision || 'Nothing needs you right now.'];
  // Session 28 (2026-09-17): an empty entry in r.lines is a group break - one idea per group, a blank
  // line between groups, at most five bulleted lines per group. parseReport() never emits '', so a
  // model cannot break groups; only code-built reports (daily-digest) do.
  const lines: string[] = []; let n = 0;
  for (const l of r.lines) {
    if (l === '') { if (lines.length && lines[lines.length - 1] !== '') { lines.push(''); n = 0; } continue; }
    if (n++ >= 5) continue;
    lines.push(`• ${l}`);
  }
  while (lines[lines.length - 1] === '') lines.pop();
  if (lines.length) out.push('', ...lines);
  if (r.action) out.push('', `Do: ${r.action}`);
  if (model) out.push('', `— ${model}`);
  return out.join('\n');
}

// Telegram plan §5 (session 25, 2026-09-16): one first line per message type, shared by every
// sender. Telegram cannot colour text, so the emoji is the colour. renderReport() is untouched
// (B56: three surfaces and three test files depend on its shape); this wraps its output.
export type HeaderKind = 'daily' | 'attention' | 'alert' | 'booking' | 'guest' | 'cleaning' | 'finance' | 'weekly';
const HEADER: Record<HeaderKind, string> = {
  daily: '🟢 DAILY', attention: '🟡 ATTENTION', alert: '🔴 ALERT', booking: '🏠 NEW BOOKING',
  guest: '💬 GUEST', cleaning: '🧹 CLEANING', finance: '🧾 FINANCE', weekly: '📋 WEEKLY',
};
export function withHeader(kind: HeaderKind, subject: string, body: string): string {
  return `${HEADER[kind]}${subject ? ` · ${subject}` : ''}\n\n${body}`;
}

// Session 28 (Lloyd, 2026-09-17): cards are read on a phone between two other things. groups() puts a
// blank line between ideas (who / when / what / Do) and caps a group at five lines. A Do line that asks
// a human to message someone carries the ready-to-send text on its own 📨 line; the tap handlers in
// telegram-expense read that line back from the tapped message (Telegram hands the tap the message,
// so there is no state), send it as monospace for long-press copy, or ask Cassy to revise it.
export function groups(...gs: Array<Array<string | false | null | undefined>>): string {
  return gs.map((g) => g.filter((l): l is string => typeof l === 'string' && l.trim() !== '').slice(0, 5).join('\n')).filter(Boolean).join('\n\n');
}
export const DASH_URL = 'https://cascadereservations-del.github.io/cascade-admin-dashboard/#/';
export const TEMPLATE_MARK = '📨 ';
/** Do lines for messaging someone: the instruction, then the text itself on the 📨 line. */
export function doSend(to: string, text: string): string[] {
  return [`Do: send ${to} this (Copy, or Revise with Cassy):`, `${TEMPLATE_MARK}${text}`];
}
/** The 📨 text of a card (up to the next blank line), or '' when the card has none. */
export function templateOf(cardText: string): string {
  const i = cardText.indexOf(TEMPLATE_MARK); if (i < 0) return '';
  const rest = cardText.slice(i + TEMPLATE_MARK.length); const end = rest.search(/\n\s*\n/);
  return (end < 0 ? rest : rest.slice(0, end)).trim();
}
export type Btn = { text: string; callback_data?: string; url?: string };
export const BTN: Record<'template' | 'inventory' | 'expense', Btn[]> = {
  template:  [{ text: '📋 Copy', callback_data: 'tpl:copy' }, { text: '✏️ Revise', callback_data: 'tpl:revise' }],
  inventory: [{ text: '📦 Inventory', url: `${DASH_URL}inventory` }, { text: '/inventory', callback_data: 'menu:do:inventory' }],
  expense:   [{ text: '💰 Log expense', callback_data: 'menu:do:log' }, { text: '🧾 Records', url: `${DASH_URL}inventory/purchases` }],
};
/** Buttons a card earns from its own text (📨 -> Copy/Revise, 📦 -> Inventory) plus any the sender adds. */
export function autoKeyboard(text: string, ...more: Btn[][]): { inline_keyboard: Btn[][] } | undefined {
  const rows: Btn[][] = [];
  if (text.includes(TEMPLATE_MARK)) rows.push(BTN.template);
  if (text.includes('📦')) rows.push(BTN.inventory);
  for (const r of more) if (r.length) rows.push(r);
  return rows.length ? { inline_keyboard: rows } : undefined;
}

// SPEC-19 (D-211): a money or count value read off a nested path is null when the path is wrong,
// never 0. On 2026-09-21 a card printed "disagree by ₱0.00" - a claim that the books balance -
// because the amount was read one level too high. A renderer that gets null drops the sentence.
export function moneyOrNull(v: unknown): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
export function pesoOrNull(v: unknown): string | null {
  const n = moneyOrNull(v);
  return n === null ? null : '\u20b1' + n.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
