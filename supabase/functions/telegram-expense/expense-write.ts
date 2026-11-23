// s134 L3 (D-405): the Telegram expense writes. Every save goes through telegram_expense_save_v1 and every void, confirm or total edit through
// telegram_expense_review_v1 (both service_role only, written by L1). index.ts keeps the messages and buttons; this file holds the keys, the RPC calls,
// the plain-language answers and the category keyboard, so each can be tested without a webhook.
// Imported by index.ts only. Nothing else bundles it (telegram-cassy/B_notice.test.ts reads index.ts as text, not this file).

/** The two slugs the bot never offers: they belong to the refund flow and the Airbnb adjustment, not to a typed expense. */
export const SYSTEM_SLUGS: readonly string[] = ['guest_refund', 'airbnb_adjustment'];

/** What the keyboard shows when the category list could not be read: the seven slugs the bot always had. */
export const FALLBACK_CATEGORIES: Array<{ slug: string; label: string }> = [
  { slug: 'supplies', label: 'Supplies' }, { slug: 'utilities', label: 'Utilities' }, { slug: 'cleaning', label: 'Cleaning' },
  { slug: 'maintenance', label: 'Maintenance' }, { slug: 'repairs', label: 'Repairs' }, { slug: 'platform_fees', label: 'Platform Fees' },
  { slug: 'other', label: 'Other' },
];

const EMOJI: Record<string, string> = { supplies: '🛒', utilities: '⚡', cleaning: '🧹', maintenance: '🔧', repairs: '🔨', platform_fees: '💼', other: '📌' };

/** The categories a person may pick: the live list without the two system slugs. */
export function pickableCategories<T extends { slug: string }>(cats: T[] | null | undefined): T[] {
  return (cats ?? []).filter((c) => c && typeof c.slug === 'string' && c.slug && !SYSTEM_SLUGS.includes(c.slug));
}

/** The /log keyboard: two buttons a row, from the category list given (callers pass the pickable list), `cat:<slug>:<detected amount>`. */
export function categoryKeyboardFrom(cats: Array<{ slug: string; label: string }>, pre: number) {
  const list = pickableCategories(cats);
  const use = list.length ? list : FALLBACK_CATEGORIES;
  const rows: Array<Array<{ text: string; callback_data: string }>> = [];
  for (let i = 0; i < use.length; i += 2) {
    rows.push(use.slice(i, i + 2).map((c) => ({ text: `${EMOJI[c.slug] ? EMOJI[c.slug] + ' ' : ''}${c.label || c.slug}`, callback_data: `cat:${c.slug}:${pre}` })));
  }
  return { inline_keyboard: rows };
}

/** `"a"|"b"|"c"` for the OCR prompt's category_hint, from the pickable slugs; slugs with odd characters are left out. */
export function categoryUnion(slugs: string[]): string {
  const ok = pickableCategories(slugs.map((slug) => ({ slug }))).map((c) => c.slug).filter((s) => /^[a-z0-9_]{1,40}$/.test(s));
  return (ok.length ? ok : FALLBACK_CATEGORIES.map((c) => c.slug)).map((s) => `"${s}"`).join('|');
}

// ---- keys: stable across a webhook retry of the same message or tap, different for every other message ----

/** A typed message or the answer to a prompt: one key per Telegram message. */
export const keyForMessage = (chatId: unknown, messageId: unknown): string | null =>
  chatId == null || messageId == null || String(chatId) === '' || String(messageId) === '' ? null : `tg:${chatId}:${messageId}`;
/** A button tap that consumed a stored question (duplicate warning, large amount, LLM confirm): one key per stored question. */
export const keyForPending = (pendingId: unknown): string | null => (pendingId == null || String(pendingId) === '' ? null : `tgp:${pendingId}`);
/** A receipt photo: one key per stored object. `again` tells a second pass over the same object (the "different receipt" tap) from the first. */
export const keyForPhoto = (objectPath: string, again?: string | null): string | null =>
  objectPath ? `tgocr:${objectPath}${again ? `#${again}` : ''}` : null;

// ---- save ----

export type Lookalike = { id?: string; date?: string; amount?: number; chip?: string } | null;
export type SaveOutcome =
  | { ok: true; id: string; replayed: boolean; lookalike: Lookalike }
  | { ok: false; error: string; message: string };

/** What a refused or failed save says to a person. No row exists in any of these cases. */
export function saveRefusal(code: string): string {
  if (code === 'bad_category') return 'That category is not available any more, so nothing was saved. Pick another one.';
  return 'Nothing was saved.';
}

// deno-lint-ignore no-explicit-any
export async function saveExpense(db: any, propertyId: string, txn: Record<string, unknown>, key: string | null): Promise<SaveOutcome> {
  if (!key) return { ok: false, error: 'no_key', message: saveRefusal('no_key') };
  // deno-lint-ignore no-explicit-any
  let res: any;
  try { res = await db.rpc('telegram_expense_save_v1', { p_property_id: propertyId, p_txn: txn, p_key: key }); }
  catch (e) { return { ok: false, error: 'rpc_failed', message: String((e as Error)?.message ?? e).slice(0, 120) }; }
  if (res?.error) return { ok: false, error: 'rpc_failed', message: String(res.error.message ?? res.error).slice(0, 120) };
  const d = res?.data;
  if (!d || d.ok !== true || !d.id) { const code = String(d?.error ?? 'save_failed'); return { ok: false, error: code, message: saveRefusal(code) }; }
  return { ok: true, id: String(d.id), replayed: d.replayed === true, lookalike: d.lookalike && typeof d.lookalike === 'object' ? d.lookalike : null };
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** 2026-11-21 -> "21 Nov"; anything else -> null (never a guess). */
export function shortDate(d: unknown): string | null {
  const m = /^\d{4}-(\d{2})-(\d{2})/.exec(String(d ?? ''));
  if (!m) return null;
  const mo = Number(m[1]), day = Number(m[2]);
  return mo >= 1 && mo <= 12 && day >= 1 && day <= 31 ? `${day} ${MONTHS[mo - 1]}` : null;
}

/** The one extra line on a confirmation when the save found a look-alike. `ref` is the short reference of the row just saved. */
export function lookalikeLine(la: Lookalike, ref: string): string | null {
  if (!la || typeof la !== 'object' || !ref) return null;
  const when = shortDate(la.date);
  const what = la.chip === 'stock' ? 'Stock bought' : 'An expense logged';
  return `Looks like ${what}${when ? ` ${when}` : ''}. If it is the same purchase: /void ${ref}`;
}

// ---- review: confirm, void, amount ----

export type ReviewOutcome = { ok: true } | { ok: false; error: string; where?: string; message: string };

const WHERE: Record<string, string> = { bills: 'Bills', pay: 'Pay staff' };

/** What a refused review says to a person. A locked row is undone in the app, never here. */
export function reviewRefusal(code: string, where?: string): string {
  if (code === 'locked') return `That one is undone in the app: ${WHERE[String(where)] ?? 'Bills / Pay staff'}`;
  if (code === 'not_found') return 'That entry was not found.';
  if (code === 'not_pending') return 'That receipt is no longer waiting for review.';
  if (code === 'bad_category') return 'Its category is not available any more. Change it in the app.';
  return 'The entry was not changed.';
}

// deno-lint-ignore no-explicit-any
export async function reviewExpense(db: any, id: string, action: 'confirm' | 'void' | 'amount', payload: Record<string, unknown>, actor: string): Promise<ReviewOutcome> {
  // deno-lint-ignore no-explicit-any
  let res: any;
  try { res = await db.rpc('telegram_expense_review_v1', { p_id: id, p_action: action, p_payload: payload, p_actor: actor }); }
  catch (e) { return { ok: false, error: 'rpc_failed', message: String((e as Error)?.message ?? e).slice(0, 120) }; }
  if (res?.error) return { ok: false, error: 'rpc_failed', message: String(res.error.message ?? res.error).slice(0, 120) };
  const d = res?.data;
  if (!d || d.ok !== true) {
    const code = String(d?.error ?? 'review_failed'), where = d?.where == null ? undefined : String(d.where);
    return { ok: false, error: code, where, message: reviewRefusal(code, where) };
  }
  return { ok: true };
}

/** A void keeps the row's own note: only the reason and the actor are sent, the RPC adds the marker. */
export const voidExpense = (db: unknown, id: string, reason: string, actor: string) => reviewExpense(db, id, 'void', { reason }, actor);
export const confirmExpense = (db: unknown, id: string, actor: string) => reviewExpense(db, id, 'confirm', {}, actor);
export const setExpenseAmount = (db: unknown, id: string, amount: number, actor: string) => reviewExpense(db, id, 'amount', { amount }, actor);

/** Void several rows one by one (the natural-language "void these"): how many went through and the first refusal. */
export async function voidMany(db: unknown, ids: string[], reason: string, actor: string): Promise<{ done: number; total: number; firstFailure: string | null }> {
  let done = 0, firstFailure: string | null = null;
  for (const id of ids) {
    const r = await voidExpense(db, id, reason, actor);
    if (r.ok) done++; else if (!firstFailure) firstFailure = r.message;
  }
  return { done, total: ids.length, firstFailure };
}
