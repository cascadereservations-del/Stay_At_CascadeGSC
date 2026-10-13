// Lane B (s81, fix round 1): the EXPLICIT signals that open Cassy's notice card. Shared by telegram-expense (routing) and telegram-cassy (the card).
// A message opens the card only when it
//   * contains a link to facebook.com/gscwaterdistrict (the GSCWD page, any post under it)   -> water notice, source gscwd
//   * contains a link to facebook.com/socoteco2.EC (SOCOTECO II, the brownout backup page)   -> brownout notice, entered by staff
//   * starts with "water notice:" or "brownout notice:" followed by the pasted post text.
// Nothing else counts: no keyword guessing on forwarded text (a guest writing "no water in the shower", a water bill and a receipt photo are not signals).
// Pure, no network, no clock.
// deno-lint-ignore-file no-explicit-any

export type B_Signal = { kind: 'water' | 'brownout' | 'ask'; via: 'link' | 'prefix'; body: string };

// Hosts are anchored: facebook.com, www./m./web.facebook.com and fb.watch only (notfacebook.com/gscwaterdistrict does not match).
const HOST = String.raw`(?<![\w.-])(?:https?:\/\/)?(?:(?:www|m|web)\.)?facebook\.com`;
// A page-named link counts only at the START of the text. Pasting a mobile "Copy link" (facebook.com/share/..., m.facebook.com/story.php..., fb.watch/...)
// has no page name, so a message that is ONLY such a link gets the "which kind?" ask card, never a save.
const WATER_LINK = new RegExp(String.raw`^\s*${HOST}\/gscwaterdistrict\b[^\s]*`, 'i');
const POWER_LINK = new RegExp(String.raw`^\s*${HOST}\/socoteco2\.ec\b[^\s]*`, 'i');
const ANY_LINK_ONLY = new RegExp(String.raw`^\s*(?:${HOST}\/[^\s]*|(?<![\w.-])(?:https?:\/\/)?fb\.watch\/[^\s]*)\s*$`, 'i');
const PREFIX = /^\s*(water|brownout)\s+notice\s*:\s*([\s\S]*)$/i;

export function B_noticeSignal(text: unknown): B_Signal | null {
  const t = typeof text === 'string' ? text : '';
  if (!t) return null;
  const p = PREFIX.exec(t);
  if (p) return { kind: p[1].toLowerCase() as 'water' | 'brownout', via: 'prefix', body: p[2].trim() };
  if (WATER_LINK.test(t)) return { kind: 'water', via: 'link', body: t.replace(WATER_LINK, ' ').replace(/\s+/g, ' ').trim() };
  if (POWER_LINK.test(t)) return { kind: 'brownout', via: 'link', body: t.replace(POWER_LINK, ' ').replace(/\s+/g, ' ').trim() };
  if (ANY_LINK_ONLY.test(t)) return { kind: 'ask', via: 'link', body: '' };
  return null;
}

/** telegram-expense's routing condition: a human message (text or photo caption) with a notice signal goes to telegram-cassy, ahead of every other path.
 *  It does NOT fire for a reply to a bot prompt, while an answer is awaited from this chat/user (`awaiting`), when the text starts with "cassy" or a slash
 *  command, or when a photo's caption is more than just the link. */
export function B_noticeRoute(update: any, awaiting = false): boolean {
  const m = update?.message;
  if (!m || m.from?.is_bot || awaiting) return false;
  if (m.reply_to_message?.from?.is_bot) return false;
  const text = typeof m.text === 'string' ? m.text : typeof m.caption === 'string' ? m.caption : '';
  if (/^\s*(?:@?cassy\b|\/)/i.test(text)) return false;
  const sig = B_noticeSignal(text);
  if (!sig) return false;
  if (Array.isArray(m.photo) && m.photo.length && (sig.via !== 'link' || sig.body !== '')) return false;
  return true;
}
