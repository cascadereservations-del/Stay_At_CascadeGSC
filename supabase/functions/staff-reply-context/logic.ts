// staff-reply-context (record-booking B5): what the Staff app's reply panel needs to fill a template for ONE chat: the guest's first
// name, dates, party, money and, only for a stay we can prove is theirs, the arrival details. Read-only; nothing is sent or written.
// Auth is host-reply's: an active owner or admin (current_staff_active, called with the caller's own JWT). Every service-role read
// (thread, booking, ID flag, settings) is a Deps call made AFTER that check passes. All I/O comes in through Deps so the rules are
// tested without a network.
//
// Binding rule (B5, privacy): `gated` and `pin_allowed` come ONLY from (a) booking_flow.booking_id of THIS psid, or (b) a booking_id the
// staff member picked, and only while that booking is confirmed with check-out today or later. A name or dates that merely match a
// stay never bind. The door PIN does not exist in the system and is never read or returned. No guest text, name or PSID is logged.
import { bearerToken, StaffAuthError } from '../_shared/staff-auth.ts';
import { datesOf, detectLang, quoteTotal, type Flow } from '../messenger-concierge/booking.ts'; // not edited; imported only
import { fillPlaceholders } from '../_shared/cascade-core/house.ts';
import { GUIDE_URL, SITE_URL } from '../_shared/cascade-core/facts.ts';
import { isNewLongStay, legacyBalance, SECURITY_DEPOSIT_PHP, type RateCard } from '../_shared/cascade-core/pricing.ts';

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
/** Meta's HUMAN_AGENT tag delivers up to 7 days after the guest's last message (host-reply/logic.ts WINDOW_MS; copied, not imported). */
export const WINDOW_MS = 7 * 24 * 3_600_000;
/** Images may be sent only inside Meta's standard 24 h window. */
export const IMAGE_MS = 24 * 3_600_000;
const SCAN_TURNS = 8;
const MAX_TEXT = 4000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// House constants (the same lines the confirmation message states: guest-messages/templates.ts). Only ever returned inside `gated`.
export const ADDRESS = 'Blk 47 Lot 39, Bria Homes, Conel Road, Brgy. San Isidro, General Santos City';
export const MAPS_LINK = 'https://maps.app.goo.gl/9vn8KyDwNrXPmJqT9';
export const CHECKIN_TIME = '2:00 PM';
export const CHECKOUT_TIME = '12:00 noon';

export type Turn = { role: 'guest' | 'bot'; text: string; at: string };
export type Thread = { psid: string; guest_name: string | null; history: Turn[]; booking_flow: Flow | null };
export type Booking = {
  id: string; guest_id: string | null; guest_name: string | null; checkin_date: string; checkout_date: string; pax: number | null;
  total_amount: number | null; deposit_amount: number | null; status: string; channel: string | null;
};
type Src = 'booking' | 'chat' | 'facebook' | 'quote' | null;
export type Val<T extends string | number = string | number> = { v: T | null; src: Src; at: string | null };
export type Stage = 'asking' | 'awaiting_payment' | 'booked' | 'staying' | 'checked_out';

export interface Deps {
  /** The caller's session -> an active owner or admin, or the HTTP status to refuse with. */
  authenticate(token: string): Promise<{ ok: true } | { ok: false; status: number; error: string }>;
  loadThread(psid: string): Promise<Thread | null>;
  loadBooking(id: string): Promise<Booking | null>;
  idOnFile(guestId: string): Promise<boolean>;
  /** app_settings rows wifi_ssid, wifi_password, onground_name, onground_phone. Called only when `gated` is built. */
  settings(): Promise<{ key: string; value: unknown }[]>;
  /** The live rate card (loadCard), so a quote matches what Cassy and the site say. */
  rateCard(): Promise<RateCard>;
  now(): Date;
}

/** loadThread could not read (a database error, not a missing row): answered 503, never as thread_not_found. */
export class ThreadReadError extends Error { constructor() { super('thread_unavailable'); } }

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

/** Today in Manila (UTC+8), yyyy-mm-dd. */
export const manilaDay = (now: Date) => new Date(now.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);
const nightsBetween = (a: string, b: string) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);
const isDay = (s: unknown): s is string => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) && Number.isFinite(Date.parse(`${s}T00:00:00Z`));
const ms = (iso: unknown) => { const t = Date.parse(String(iso ?? '')); return Number.isFinite(t) ? t : NaN; };
const peso = (n: number) => `₱${n.toLocaleString('en-PH')}`;
const first = (name: string | null | undefined) => String(name ?? '').trim().split(/\s+/)[0] || null;
function val<T extends string | number = never>(v: null | undefined, src: null): Val<T>;
function val<T extends string | number>(v: T | null | undefined, src: Src, at?: string | null): Val<T>;
function val<T extends string | number>(v: T | null | undefined, src: Src, at: string | null = null): Val<T> { return v == null ? { v: null, src: null, at: null } : { v, src, at }; }

/** The HUMAN_AGENT window (open up to 7 days after the last guest turn) and whether an image may go (inside 24 h). */
export function replyWindow(history: Turn[], now: Date): { open: boolean; closes_at: string | null; image_ok: boolean } {
  let last = 0;
  for (const t of history ?? []) {
    if (t?.role !== 'guest') continue;
    const m = ms(t.at);
    if (Number.isFinite(m) && m > last) last = m;
  }
  if (!last) return { open: false, closes_at: null, image_ok: false };
  const age = now.getTime() - last;
  return { open: age < WINDOW_MS, closes_at: new Date(last + WINDOW_MS).toISOString(), image_ok: age < IMAGE_MS };
}

type Said = { dates: string[]; pax: number | null; at: string; text: string };
/** The newest guest messages (plus the pasted text, stamped now), newest first. `text` is what staff pasted for Airbnb. */
function recentGuest(history: Turn[], pasted: string, now: Date): { at: string; text: string }[] {
  const turns = (history ?? []).filter((t) => t?.role === 'guest' && typeof t.text === 'string' && Number.isFinite(ms(t.at)))
    .sort((a, b) => ms(b.at) - ms(a.at)).slice(0, SCAN_TURNS).map((t) => ({ at: new Date(ms(t.at)).toISOString(), text: t.text }));
  return pasted ? [{ at: now.toISOString(), text: pasted }, ...turns] : turns;
}
function newestDates(msgs: { at: string; text: string }[], now: Date): Said | null {
  for (const m of msgs) {
    const d = datesOf(m.text, now);
    if (d.length) return { dates: d.slice(0, 2), pax: null, at: m.at, text: m.text };
  }
  return null;
}
const NUM: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8,
  isa: 1, dalawa: 2, tatlo: 3, apat: 4, lima: 5, anim: 6, pito: 7, walo: 8, usa: 1, duha: 2, tulo: 3, upat: 4, unom: 6,
};
const W = String.raw`\d{1,2}|${Object.keys(NUM).join('|')}`;
const MONTH = String.raw`jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|enero|pebrero|marso|abril|mayo|hunyo|hulyo|agosto|setyembre|oktubre|nobyembre|disyembre`;
/** A number that is part of a date (right after a month, a dash or "to/until/hanggang") is never a party size. */
const NOT_DATE = String.raw`(?<!(?:\b(?:${MONTH})[a-z]*\.?\s*)|(?:[-–]\s*)|(?:\b(?:to|until|hanggang|til)\s+))`;
/** "for N" that is a length of stay ("for 2 weeks") or a date range ("for 3 to 5 Dec", "for 3 Dec") is not a party. */
const STAY_LEN = String.raw`(?!\s*(?:nights?|days?|weeks?|months?|wks?|gabi|araw|linggo|buwan|semana|bulan)\b)(?!\s*(?:[-–]|to\b|until\b|hanggang\b)\s*\d)(?!\s*(?:${MONTH})[a-z]*\b)`;
const ADULT_W = 'adults?|matanda|dagko', KID_W = 'kids?|children|child|bata|anak|toddlers?|infants?|baby|babies';
const ANY_W = 'pax|persons?|people|guests?|tao|tawo|heads?';
const CNT = (words: string) => new RegExp(String.raw`${NOT_DATE}\b(${W})\s*(?:po|pa|ka|ba|po\s+ba|na)?\s*(?:${words})\b`, 'gi');
const FOR_N = new RegExp(String.raw`\b(?:for|para sa|para|kaming|kami|we are|we're)\s+(?:po\s+)?(${W})\b${STAY_LEN}`, 'i');
const TRAIL = /(?:\?|(?:-|–|\bto|\buntil|\bhanggang)\s*(?:[a-z]+\.?\s*)?\d{1,2}\s*,)\s*([1-8])\s*[.!]?\s*$/i;
const num = (t: string) => { const k = t.toLowerCase(); return /^\d+$/.test(k) ? Number(k) : NUM[k] ?? NaN; };
const sum = (re: RegExp, text: string) => { let n = 0, hit = false; for (const m of text.matchAll(re)) { n += num(m[1]); hit = true; } return hit ? n : null; };
/** B6 (contract 0.3 items 6 and 8): the party size a guest message states, read FROM the cue itself (audit B r2 N-2: the gate and the
 *  reader are one regex), or null. "N guests/pax/people" wins; else adults + kids; else "for / para sa / kami N" (not a length of stay
 *  or a date range); else the trailing "dates?, N" form. A bare number ("Dec 3 to 5 po available?") is never a party. Outside 1..8 ->
 *  null, never a fallback to another number. */
export function paxFromCue(text: string): number | null {
  const t = String(text ?? '').slice(0, MAX_TEXT).replace(/\s+/g, ' '); // one space per run: keeps the lookbehinds linear
  const pick = (): number | null => {
    const total = sum(CNT(ANY_W), t); if (total != null) return total;
    const a = sum(CNT(ADULT_W), t), k = sum(CNT(KID_W), t); if (a != null || k != null) return (a ?? 0) + (k ?? 0);
    const f = FOR_N.exec(t); if (f) return num(f[1]);
    const tr = TRAIL.exec(t); if (tr) return Number(tr[1]);
    return null;
  };
  const n = pick();
  return n != null && Number.isInteger(n) && n >= 1 && n <= 8 ? n : null;
}
export const hasGuestCue = (text: string) => paxFromCue(text) != null;
function newestPax(msgs: { at: string; text: string }[]): { n: number; at: string } | null {
  for (const m of msgs) {
    const n = paxFromCue(m.text);
    if (n != null) return { n, at: m.at };
  }
  return null;
}

function stageOf(b: Booking | null, flow: Flow | null, today: string): Stage {
  if (b) {
    if (b.status === 'pending') return 'awaiting_payment';
    if (b.status === 'confirmed') return today < b.checkin_date ? 'booked' : today <= b.checkout_date ? 'staying' : 'checked_out';
  }
  if (flow && (flow.step === 'await_receipt' || flow.step === 'receipt_sent')) return 'awaiting_payment';
  return 'asking';
}

export async function handleReplyContext(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  let token: string;
  try { token = bearerToken(req); } catch (e) {
    if (e instanceof StaffAuthError) return json({ ok: false, error: e.code }, e.status);
    throw e;
  }
  const who = await deps.authenticate(token);
  if (!who.ok) return json({ ok: false, error: who.error }, who.status); // nothing below runs for a refused caller
  try { return await respond(req, deps); } catch (e) {
    if (e instanceof ThreadReadError) return json({ ok: false, error: 'thread_unavailable' }, 503);
    console.log('staff_reply_context_error', 'context_failed'); // the code only: never the error text, which could carry guest data
    return json({ ok: false, error: 'context_failed' }, 500);
  }
}

async function respond(req: Request, deps: Deps): Promise<Response> {
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'invalid_json' }, 400); }
  if (!body || typeof body !== 'object') return json({ ok: false, error: 'invalid_json' }, 400);
  const psid = typeof body.psid === 'string' ? body.psid.trim() : '';
  const pasted = typeof body.text === 'string' ? body.text.trim() : '';
  if (!psid && !pasted) return json({ ok: false, error: 'psid_or_text_required' }, 400);
  if (psid.length > 64) return json({ ok: false, error: 'invalid_psid' }, 400);
  if (pasted.length > MAX_TEXT) return json({ ok: false, error: 'text_too_long' }, 400);
  const platform = body.platform === 'airbnb' ? 'airbnb' : 'messenger';
  if (body.platform != null && body.platform !== 'airbnb' && body.platform !== 'messenger') return json({ ok: false, error: 'invalid_platform' }, 400);
  const picked = body.booking_id == null || body.booking_id === '' ? null : String(body.booking_id);
  if (picked !== null && !UUID_RE.test(picked)) return json({ ok: false, error: 'invalid_booking_id' }, 400);

  const now = deps.now(), today = manilaDay(now), nowIso = now.toISOString();
  const thread = psid ? await deps.loadThread(psid) : null;
  if (psid && !thread && !pasted) return json({ ok: false, error: 'thread_not_found' }, 404);
  const flow = thread?.booking_flow ?? null;
  const history = thread?.history ?? [];
  const msgs = recentGuest(history, pasted, now);

  // ---- binding: the picked booking, else this thread's own flow. Never a name or a date match. ----
  const flowId = typeof flow?.booking_id === 'string' && UUID_RE.test(flow.booking_id) ? flow.booking_id : null;
  const live = async (id: string) => { const b = await deps.loadBooking(id); return b && (b.status === 'confirmed' || b.status === 'pending') ? b : null; };
  // A confirmed pick that is already checked out still binds (post-stay replies, stage checked_out); staff chose it and see
  // picked_differs_from_thread when it is not this thread's booking. gated and pin_allowed stay off for it (provenStay).
  let booking: Booking | null = null, bound: 'flow' | 'picked' | 'none' = 'none';
  if (picked) { booking = await live(picked); if (booking) bound = 'picked'; }
  if (!booking && flowId && flowId !== picked) { booking = await live(flowId); if (booking) bound = 'flow'; } // a rejected pick falls back to this thread's own booking
  const pickedDiffers = !!picked && !!flowId && picked !== flowId;
  const stage = stageOf(booking, flow, today);

  // ---- dates and party: booking > newest guest message (only if newer than the flow) > stored flow; a past check-in is dropped ----
  const dateSrc = (() => {
    if (booking) return { ci: booking.checkin_date, co: booking.checkout_date, src: 'booking' as const, at: null as string | null };
    const chat = newestDates(msgs, now);
    const flowDates = isDay(flow?.checkin) ? { ci: flow!.checkin!, co: isDay(flow?.checkout) ? flow!.checkout! : null, at: flow?.updated_at ?? null } : null;
    const flowAt = ms(flow?.updated_at);
    const cands: { ci: string; co: string | null; at: string | null }[] = [];
    const chatC = chat ? { ci: chat.dates[0], co: chat.dates[1] ?? null, at: chat.at } : null;
    if (chatC && flowDates && flowAt >= ms(chatC.at)) cands.push(flowDates, chatC); // the flow is newer than the message: the flow wins
    else { if (chatC) cands.push(chatC); if (flowDates) cands.push(flowDates); }
    const ok = cands.find((c) => isDay(c.ci) && c.ci >= today);
    if (!ok) return null;
    const co = ok.co && isDay(ok.co) && ok.co > ok.ci ? ok.co : null;
    return { ci: ok.ci, co, src: 'chat' as const, at: ok.at };
  })();
  const ci = dateSrc?.ci ?? null, co = dateSrc?.co ?? null;
  const nights = ci && co ? nightsBetween(ci, co) : null;

  const paxVal: Val<number> = (() => {
    if (booking) return val(booking.pax, 'booking');
    const chat = newestPax(msgs), flowPax = Number(flow?.pax) >= 1 ? Number(flow!.pax) : null, flowAt = ms(flow?.updated_at);
    if (chat && !(flowPax && flowAt >= ms(chat.at))) return val(chat.n, 'chat', chat.at);
    return flowPax ? val(flowPax, 'chat', flow?.updated_at ?? null) : chat ? val(chat.n, 'chat', chat.at) : val(null, null);
  })();

  // ---- name: booking, else the flow's name slot, else the Facebook profile name. parseName is never run on free chat. ----
  const nameVal: Val<string> = booking && first(booking.guest_name) ? val(first(booking.guest_name), 'booking')
    : first(flow?.name) ? val(first(flow?.name), 'chat', flow?.updated_at ?? null)
    : first(thread?.guest_name) ? val(first(thread?.guest_name), 'facebook') : val(null, null);

  // ---- money ----
  let total: Val<number> = val(null, null), deposit: Val<number> = val(null, null), paid: Val<number> = val(null, null), balance: Val<number> = val(null, null);
  let balanceLine: Val<string> = val(null, null);
  if (booking) {
    const t = Number(booking.total_amount), d = Number(booking.deposit_amount);
    total = booking.total_amount == null || !Number.isFinite(t) ? val(null, null) : val(t, 'booking');
    deposit = val(SECURITY_DEPOSIT_PHP, 'booking'); // the refundable security deposit, never the amount paid (contract 0.3 item 4)
    if (booking.status === 'confirmed' && booking.deposit_amount != null && Number.isFinite(d)) {
      paid = val(d, 'booking');
      if (total.v != null) {
        balance = val(Math.max(0, t - d), 'booking');
        const nts = nightsBetween(booking.checkin_date, booking.checkout_date);
        balanceLine = val(isNewLongStay(t, d, nts) ? `First month paid, ${peso(balance.v!)} to follow monthly` : balance.v! > 0 ? `Balance ${peso(balance.v!)}, due a day before check-in` : 'Paid in full', 'booking');
      }
    }
  } else if (ci && co) {
    const card = await deps.rateCard();
    const q = quoteTotal(ci, co, card);
    if (Number.isFinite(q.total) && q.total > 0) { total = val(q.total, 'quote', nowIso); deposit = val(SECURITY_DEPOSIT_PHP, 'quote', nowIso); }
  }

  // ---- language: the flow's register, else read now from the newest guest message ----
  const langV = flow?.lang ?? (msgs[0] ? detectLang(msgs[0].text) : null);
  const lang: Val<string> = langV ? val(langV, 'chat', flow?.lang ? flow.updated_at ?? null : msgs[0]?.at ?? null) : val(null, null);

  const values = {
    first_name: nameVal,
    checkin_date: val(ci, dateSrc?.src ?? null, dateSrc?.at ?? null),
    checkout_date: val(co, dateSrc?.src ?? null, dateSrc?.at ?? null),
    nights: val(nights, dateSrc?.src ?? null, dateSrc?.at ?? null),
    guests: paxVal,
    checkin_time: val(CHECKIN_TIME, 'booking'), checkout_time: val(CHECKOUT_TIME, 'booking'), // house policy, the same on every stay
    total, paid, balance, balance_line: balanceLine, deposit,
    booking_link: platform === 'airbnb' ? val(null, null) : val(SITE_URL, 'booking'),
    lang,
  };

  // ---- gated: only a bound, confirmed stay that has not ended; the PIN is never part of it ----
  let gated: Record<string, string | null> | undefined;
  let pinAllowed = false;
  const provenStay = !!booking && bound !== 'none' && booking.status === 'confirmed' && booking.checkout_date >= today && (stage === 'booked' || stage === 'staying');
  if (provenStay && booking) {
    const rows = await deps.settings();
    const get = (k: string) => { const v = rows.find((r) => r.key === k)?.value; return typeof v === 'string' && v.trim() ? v.trim() : null; };
    const name = get('onground_name'), phone = get('onground_phone');
    gated = {
      address: ADDRESS, maps_link: MAPS_LINK, guide_link: GUIDE_URL,
      onground_contact: name || phone ? fillPlaceholders('{{ONGROUND}}', rows) : null,
      wifi_name: get('wifi_ssid'), wifi_password: get('wifi_password'),
    };
    const idOk = booking.guest_id ? await deps.idOnFile(booking.guest_id) : false;
    // the shared rule: nothing owing now (a new long stay owes monthly, later); the amount paid must be known and above 0
    pinAllowed = idOk && paid.v != null && paid.v > 0 && total.v != null && legacyBalance({ total: total.v, deposit: paid.v, nights: nightsBetween(booking.checkin_date, booking.checkout_date) }) === null;
  }

  const flowAt = ms(flow?.updated_at), newestGuest = Math.max(0, ...history.filter((t) => t?.role === 'guest').map((t) => ms(t.at)).filter(Number.isFinite));
  const stale = !!flow && Number.isFinite(flowAt) && newestGuest > flowAt;
  const window = platform === 'airbnb' || !thread ? { open: true, closes_at: null, image_ok: false } : replyWindow(history, now);

  console.log('staff_reply_context', JSON.stringify({ stage, link: bound, gated: !!gated, stale })); // counts and states only: no guest text, name or PSID
  return json({
    ok: true, stage, link: bound, picked_differs_from_thread: pickedDiffers,
    booking: booking ? { id: booking.id, ref: `DIR-${booking.id.slice(0, 8).toUpperCase()}`, status: booking.status, channel: booking.channel } : null,
    values,
    ...(gated ? { gated } : {}),
    pin_allowed: pinAllowed,
    needs_input: ['door_pin', 'outage_date', 'outage_times'],
    reply_window: window,
    read_at: nowIso, stale,
  });
}
