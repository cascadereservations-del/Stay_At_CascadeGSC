// Lane B (s81, fix round 1): the EXPLICIT signals that open Cassy's notice card. Shared by telegram-expense (routing) and telegram-cassy (the card).
// A message opens the card only when it
//   * contains a link to facebook.com/gscwaterdistrict (the GSCWD page, any post under it)   -> water notice, source gscwd
//   * contains a link to facebook.com/socoteco2.EC (SOCOTECO II, the brownout backup page)   -> brownout notice, entered by staff
//   * starts with "water notice:" or "brownout notice:" followed by the pasted post text.
// Nothing else counts: no keyword guessing on forwarded text (a guest writing "no water in the shower", a water bill and a receipt photo are not signals).
// Pure, no network, no clock.
// deno-lint-ignore-file no-explicit-any

export type B_Signal = { kind: 'water' | 'brownout'; via: 'link' | 'prefix'; body: string };

const WATER_LINK = /(?:https?:\/\/)?(?:[\w-]+\.)?facebook\.com\/gscwaterdistrict\b[^\s]*/i;
const POWER_LINK = /(?:https?:\/\/)?(?:[\w-]+\.)?facebook\.com\/socoteco2\.ec\b[^\s]*/i;
const PREFIX = /^\s*(water|brownout)\s+notice\s*:\s*([\s\S]*)$/i;

export function B_noticeSignal(text: unknown): B_Signal | null {
  const t = typeof text === 'string' ? text : '';
  if (!t) return null;
  const p = PREFIX.exec(t);
  if (p) return { kind: p[1].toLowerCase() as 'water' | 'brownout', via: 'prefix', body: p[2].trim() };
  if (WATER_LINK.test(t)) return { kind: 'water', via: 'link', body: t.replace(WATER_LINK, ' ').replace(/\s+/g, ' ').trim() };
  if (POWER_LINK.test(t)) return { kind: 'brownout', via: 'link', body: t.replace(POWER_LINK, ' ').replace(/\s+/g, ' ').trim() };
  return null;
}

/** telegram-expense's routing condition: a human message (text or photo caption) with a notice signal goes to telegram-cassy, ahead of every other path. */
export function B_noticeRoute(update: any): boolean {
  const m = update?.message;
  if (!m || m.from?.is_bot) return false;
  return B_noticeSignal(typeof m.text === 'string' ? m.text : typeof m.caption === 'string' ? m.caption : '') !== null;
}
