// telegram-cassy lane B (s81): a post forwarded to Cassy becomes a pending WATER notice card; nothing is saved until the Save tap.
// The tap is telegram-expense's existing llm_confirm handler (executeNoticeFromLLM inserts ops_notices with the params below).
// The title is BUILT from what was read (kind, times, place), never copied from the post, so a phone number, e-mail or amount in
// the post cannot reach the notice. Pure functions: the clock is passed in.
// deno-lint-ignore-file no-explicit-any

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
  january: 1, february: 2, march: 3, april: 4, june: 6, july: 7, august: 8, september: 9, october: 10, november: 11, december: 12,
};
const MON = '(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)';

export const B_isForward = (msg: any): boolean =>
  !!(msg && (msg.forward_origin || msg.forward_date || msg.forward_from_chat || msg.forward_from || msg.forward_sender_name));

const manilaYmd = (ms: number) => new Date(ms).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
const pad = (n: number) => String(n).padStart(2, '0');

/** Looks like a water-supply post: the word water or tubig with an interruption or advisory cue. */
export function B_looksLikeWater(text: string): boolean {
  return /\b(water|tubig|gscwd)\b/i.test(text) &&
    /\b(interrupt\w*|advisory|shut\s?-?down|no water|walang tubig|service|maintenance|repair|pipe|leak|low pressure|supply)\b/i.test(text);
}

export function B_findDate(text: string, yearHint: number): string | null {
  const iso = /\b(20\d\d)-(\d\d)-(\d\d)\b/.exec(text);
  if (iso) return iso[0];
  const md = new RegExp(`\\b${MON}\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:\\s*,?\\s*(20\\d\\d))?\\b`, 'i').exec(text);
  const dm = new RegExp(`\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?${MON}\\.?(?:\\s*,?\\s*(20\\d\\d))?\\b`, 'i').exec(text);
  const hit = md ? { m: md[1], d: md[2], y: md[3] } : dm ? { m: dm[2], d: dm[1], y: dm[3] } : null;
  if (!hit) return null;
  const month = MONTHS[hit.m.toLowerCase()], day = Number(hit.d);
  if (!month || day < 1 || day > 31) return null;
  const y = hit.y ? Number(hit.y) : yearHint;
  const probe = new Date(Date.UTC(y, month - 1, day));
  return probe.getUTCMonth() === month - 1 ? `${y}-${pad(month)}-${pad(day)}` : null;
}

const to24 = (h: number, mer: string) => (mer === 'pm' ? (h % 12) + 12 : h % 12);
const merOf = (s: string) => (s.toLowerCase().startsWith('p') ? 'pm' : 'am');

/** "8:00 AM to 5:00 PM", "8am-5pm", "8-5pm", "1:00 to 4:00 PM": start as HH:MM:00 and the hours long. Null when there is no range. */
export function B_findTimes(text: string): { start: string; hours: number; label: string } | null {
  const m = /\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\s*(?:to|-|–|—|until|hanggang|up to)\s*(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)/i.exec(text);
  if (!m) return null;
  const h1 = Number(m[1]), m1 = Number(m[2] ?? 0), h2 = Number(m[4]), m2 = Number(m[5] ?? 0);
  if (h1 > 12 || h2 > 12 || m1 > 59 || m2 > 59 || h1 < 1 || h2 < 1) return null;
  const mer2 = merOf(m[6]);
  let s = to24(h1, m[3] ? merOf(m[3]) : mer2) * 60 + m1;
  const e = to24(h2, mer2) * 60 + m2;
  if (!m[3] && s >= e) s = to24(h1, 'am') * 60 + m1; // "8-5pm" reads 8 am to 5 pm
  const span = (e - s + 1440) % 1440;
  if (span === 0) return null;
  const f = (min: number) => { const h = Math.floor(min / 60) % 24; return `${h % 12 === 0 ? 12 : h % 12}:${pad(min % 60)} ${h >= 12 ? 'pm' : 'am'}`; };
  return { start: `${pad(Math.floor(s / 60))}:${pad(s % 60)}:00`, hours: Math.round((span / 60) * 10) / 10, label: `${f(s)} to ${f(e)}` };
}

export type B_WaterParams = { notice_type: 'water'; title: string; effective_date: string; effective_time: string | null; duration_hours: number | null };
export type B_WaterRead = { params: B_WaterParams; dateFound: boolean; namesUs: boolean };

/** Reads one forwarded post. postedAtMs (frozen by the caller) supplies the year, and the date when the post names none. */
export function B_readWaterPost(text: string, postedAtMs: number): B_WaterRead {
  const today = manilaYmd(postedAtMs);
  const found = B_findDate(text, Number(today.slice(0, 4)));
  const t = B_findTimes(text);
  const namesUs = /san\s+isidro/i.test(text);
  const title = ['Water interruption', t ? t.label : '', namesUs ? 'in San Isidro' : ''].filter(Boolean).join(' ');
  return { params: { notice_type: 'water', title, effective_date: found ?? today, effective_time: t?.start ?? null, duration_hours: t?.hours ?? null }, dateFound: !!found, namesUs };
}

/** The confirm card text: plain sentences, and it says plainly what the post did not say. */
export function B_waterCard(r: B_WaterRead): string {
  const p = r.params;
  const lines = [
    `Save a water notice on ${p.effective_date}${p.effective_time ? ' at ' + p.effective_time.slice(0, 5) : ''}${p.duration_hours ? ' for ' + p.duration_hours + 'h' : ''}?`,
    p.title,
  ];
  if (!r.dateFound) lines.push('The post names no date, so this uses the day it was forwarded.');
  if (!r.namesUs) lines.push('The post does not name Brgy. San Isidro. Save it only if it affects us.');
  return lines.join('\n');
}

type Send = (chatId: unknown, text: string, replyTo: number | undefined, keyboard: Array<Array<{ text: string; callback_data: string }>>) => Promise<boolean>;
/** Stores the pending notice (telegram_pending kind llm_notice, the row telegram-expense llm_confirm consumes) and sends the Save / Cancel card. */
export async function B_waterForward(db: any, msg: any, text: string, send: Send): Promise<void> {
  const r = B_readWaterPost(text, Number(msg.date ?? 0) * 1000);
  const { data, error } = await db.from('telegram_pending').insert({
    chat_id: msg.chat.id, kind: 'llm_notice',
    payload: { params: r.params, from: { first_name: msg.from?.first_name, username: msg.from?.username, id: msg.from?.id } },
  }).select('id').single();
  if (error || !data?.id) {
    console.error('cassy_water_pending_failed', String(error?.message ?? 'no id').slice(0, 200));
    await send(msg.chat.id, 'I could not prepare that notice. Nothing was saved. Try again in a minute.', msg.message_id, []);
    return;
  }
  await send(msg.chat.id, B_waterCard(r), msg.message_id, [[
    { text: '✅ Save it', callback_data: `llm_confirm:${data.id}` },
    { text: '❌ Cancel', callback_data: `llm_cancel:${data.id}` },
  ]]);
}
