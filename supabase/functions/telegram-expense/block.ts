// SPEC-41 Part 1: the OPS "blocked date" card's taps and the two follow-up questions. Pure texts, so block.test.ts reads every line;
// index.ts owns the Telegram calls. The follow-ups ride the existing 'awaiting_reply' pending kind (flows block_brownout, block_other).

/** What the card says after a tap: `Recorded: brownout, by Marifel.` */
export const BLOCK_LABEL: Record<string, string> = {
  brownout: 'brownout', maint: 'maintenance', owner: 'owner use', other: 'something else',
  direct: 'Facebook / direct booking', unblock: 'to be unblocked on Airbnb',
};
/** The Staff app (GitHub Pages root of the Cascade-Staff repo; same host and repo as BANK_PAGE in _shared/cascade-core/staffpay.ts). */
export const STAFF_URL = 'https://cascadereservations-del.github.io/Cascade-Staff/';
/** B4: a recorded `direct` tap also says where to log the guest: the Staff calendar opens the record form on the blocked check-in date (`checkin` YYYY-MM-DD, optional). */
export const recordLink = (checkin?: string | null) => `${STAFF_URL}#calendar${/^\d{4}-\d{2}-\d{2}$/.test(checkin ?? '') ? `/${checkin}` : ''}?record=1`;
export const blockRecorded = (answer: string, who: string, checkin?: string | null) =>
  `Recorded: ${BLOCK_LABEL[answer] ?? answer}, by ${who}.${answer === 'direct' ? ` Log the guest: ${recordLink(checkin)}` : ''}`;

/** The RPC's refusals, for a person. `keep` = the buttons stay for someone who may answer. */
export function blockRefusal(reason: string, who: string): { line: string; keep: boolean } {
  const lines: Record<string, string> = {
    unmapped_telegram_user: `⛔ ${who}, your Telegram account is not mapped to a staff profile — ask Lloyd to map it.`,
    not_authorized: `⛔ ${who} is not allowed to answer for the calendar.`,
    not_pending: 'ℹ️ Already answered.',
  };
  return { line: lines[reason] ?? `⚠️ ${reason || 'unknown result'}`, keep: reason === 'unmapped_telegram_user' || reason === 'not_authorized' };
}

export const BLOCK_BROWNOUT_PROMPT = '⚡ Which outage was it? Reply to this message with the day, start, hours and who announced it, like: 10-11 8am 8h NGCP. You may skip this; the date is already recorded as a brownout.';
export const BLOCK_OTHER_PROMPT = '✏️ What is it? Reply to this message in a few words.';
export const BLOCK_PROMPTS: Record<string, string> = { brownout: BLOCK_BROWNOUT_PROMPT, other: BLOCK_OTHER_PROMPT };

/** After "Something else": the thanks line. */
export const blockNoted = (text: string, who: string) => `Noted: ${text.trim().slice(0, 200)}. Thank you, ${who}.`;
