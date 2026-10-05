// SPEC-41 Part 1: the OPS "blocked date" card's taps and the two follow-up questions. Pure texts, so block.test.ts reads every line;
// index.ts owns the Telegram calls. The follow-ups ride the existing 'awaiting_reply' pending kind (flows block_brownout, block_other).

/** What the card says after a tap: `Recorded: brownout, by Marifel.` */
export const BLOCK_LABEL: Record<string, string> = {
  brownout: 'brownout', maint: 'maintenance', owner: 'owner use', other: 'something else',
  direct: 'a direct booking is coming', unblock: 'to be unblocked on Airbnb',
};
export const blockRecorded = (answer: string, who: string) => `Recorded: ${BLOCK_LABEL[answer] ?? answer}, by ${who}.`;

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
