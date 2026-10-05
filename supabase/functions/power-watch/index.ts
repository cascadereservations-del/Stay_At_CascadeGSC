// power-watch v2 (D-284, Lloyd 2026-09-29 "A"; D-290, Lloyd 2026-10-02): SOCOTECO II scheduled power interruptions for our feeder 14-3.
// Every 15 minutes from pg_cron (x-cascade-cron-secret, Vault). Reads socoteco2.com's WordPress feed (free), decides each poster by
// its filename where it can (poster.ts) and reads the rest with the vision helper the receipts already use. A poster that
// is ours becomes an ops_notices brownout (the daily digest and Cassy read it), and in the SAME run:
//   - every night the outage touches (plan.ts) is blocked on OUR booking site (calendar_events 'brownout:<night>' manual rows);
//     nothing is written to Airbnb, Marifel blocks that by hand, so ONE OPS card goes out at once with what to block;
//   - a guest already in the house on a touched night is never blocked: the card carries the prep and a draft message for them;
//   - the host inbox gets the e-mail as before.
// Each run then re-checks the notices it holds: "Airbnb block seen" when the iCal feed shows Marifel's block, one reminder after
// 3 hours of silence, a "changed" card when SOCOTECO posts new times for a date, and a cancel card (Unblock button) when it
// cancels or moves one. The taps (pw:done / pw:undo / pw:unblock) are handled in telegram-expense.
// State: app_settings.power_watch_state {done: post ids, images: poster URLs already decided} as before, plus one key per outage date
// power_watch_notice:<date> (brownout.ts NoticeState). A notice already on the board with no state (a photo saved in Telegram, the two
// that predate v2) is adopted on the first run: blocked and announced like a new one, five at most per run.
// What change detection can and cannot catch: it sees a NEW poster image for a date we already hold (a changed time, a cancelled or
// moved notice) among the 10 newest posts. It does not re-read a poster whose image was already decided, so a poster edited in place at
// the same URL is missed; a change announced only on Facebook or by text is missed; an unscheduled outage (SOCOTECO posts it on
// Facebook only; paid scraping, free tier first) is missed; and one OCR misread is carried until a newer poster corrects it. Two
// windows on one date are one notice: the newer poster replaces the older.
// Not told: other guests, who hear about utilities only if they ask (Lloyd 2026-09-29). The staff house fact carries the 24/7 hotline.
// Session 70 (SPEC-41 Part 3, D-299.1): a brownout block stays only while SOCOTECO's CURRENT posts still list the outage (plan.ts scheduleFrom / staleNotices).
// Two clean scrapes in a row without it free its nights (watch.ts, one OPS + Finance card with Keep it blocked); never on an unknown or half-read feed,
// never over a guest, and only for ops_notices.source = socoteco (an NGCP or staff notice ends by its date or an Unblock). The feed is 20 posts deep.
// ?dry=1 decides and logs but writes, alerts and marks nothing.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { parseModelJson, visionExtractText } from '../_shared/cascade-core/vision.ts';
import { classifyFile, isPowerPost, noticeFrom, OCR_PROMPT, posterFor, posterUrls, type Ocr } from './poster.ts';
import { agreedRead, decisionKey, freeReads, usable } from './free-read.ts';
import { scheduleFrom, touchedNights } from './plan.ts';
import { pruneStates, reconcile, type Found } from './watch.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const FEED = 'https://www.socoteco2.com/wp-json/wp/v2/posts?per_page=20&orderby=date&_fields=id,date,link,title,content';
const UA = { 'User-Agent': 'Mozilla/5.0 (compatible; CascadeOpsWatch/1.0)' };
const STATE_KEY = 'power_watch_state';
const MAX_READS = 4;   // poster reads per run; the rest wait for the next run
const READ_BUDGET_MS = 90_000; // no new read after this, so the run saves its state before the platform's wall clock ends it
const KEEP = 300;
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
// deno-lint-ignore no-explicit-any
type Db = any;

/** A card to the OPS chat. Plain text (no parse_mode): the buttons are the card's own. */
async function tg(text: string, markup?: unknown, chatEnv = 'TELEGRAM_CHAT_ID'): Promise<boolean> {
  const token = env('TELEGRAM_BOT_TOKEN'), chat = env(chatEnv);
  if (!token || !chat) return false;
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true, ...(markup ? { reply_markup: markup } : {}) }), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  // Proof of delivery (2026-10-02: two cards were recorded as sent but never showed in OPS): Telegram's own answer, no text, no token.
  const body = r ? await r.json().catch(() => null) : null;
  console.log('power_watch_tg', JSON.stringify({ http: r?.status ?? null, ok: body?.ok ?? null, message_id: body?.result?.message_id ?? null,
    chat_type: body?.result?.chat?.type ?? null, chat_tail: String(body?.result?.chat?.id ?? '').slice(-4), error: body?.description ?? null }));
  return !!r?.ok && body?.ok === true;
}

/** The host inbox through the e-mail relay, the same route as the urgent guest alerts. */
async function mail(db: Db, subject: string, message: string): Promise<boolean> {
  const url = env('EMAIL_RELAY_URL'), token = env('EMAIL_RELAY_TOKEN');
  if (!url || !token) return false;
  const { data } = await db.from('app_settings').select('value').eq('key', 'email_recipients').maybeSingle();
  const to = String(data?.value ?? '').split(',')[0].trim() || 'cascadereservations@gmail.com';
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(45_000),
    body: JSON.stringify({ action: 'guestMessage', token, guest_email: to, guest_name: 'Cascade host', subject, message }) }).catch(() => null);
  return !!r?.ok;
}

async function run(db: Db, dry: boolean): Promise<Record<string, unknown>> {
  const res = await fetch(FEED, { headers: UA, signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`socoteco_feed_${res.status}`);
  // deno-lint-ignore no-explicit-any
  const posts = ((await res.json()) as any[]).filter(isPowerPost);
  const { data: st } = await db.from('app_settings').select('value').eq('key', STATE_KEY).maybeSingle();
  // ours (SPEC-41): a poster the OCR found to be ours -> the date it read, so scheduleFrom can tell which dates SOCOTECO still lists.
  const state = { done: [...(st?.value?.done ?? [])] as number[], images: [...(st?.value?.images ?? [])] as string[], ours: { ...(st?.value?.ours ?? {}) } as Record<string, string> };
  const now = new Date();
  const today = new Date(now.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);
  if (!st?.value?.ours) { // first run after SPEC-41: seed it from the active notices whose poster was read before, so nothing already read looks unlisted
    const { data: nq } = await db.from('ops_notices').select('effective_date').eq('property_id', PROPERTY_ID).eq('notice_type', 'brownout').eq('is_active', true).gte('effective_date', today);
    for (const n of (nq ?? []) as Array<{ effective_date: string }>) { const u = posterFor(n.effective_date, state.images); if (u && classifyFile(u) === 'read') state.ours[u] = n.effective_date; }
  }
  const found: Found[] = [], log: string[] = [];
  let reads = 0;
  const started = Date.now();
  for (const p of posts) {
    if (state.done.includes(p.id)) continue;
    let complete = true;
    for (const url of posterUrls(p.content?.rendered ?? '')) {
      if (state.images.includes(url)) continue;
      const c = classifyFile(url);
      if (c === 'miss') { state.images.push(url); continue; }
      if (reads >= MAX_READS || Date.now() - started > READ_BUDGET_MS) { complete = false; break; }
      reads++;
      try {
        const img = await fetch(url, { headers: UA, signal: AbortSignal.timeout(30_000) });
        if (!img.ok) throw new Error(`poster_${img.status}`);
        const bytes = new Uint8Array(await img.arrayBuffer()), mime = img.headers.get('content-type') ?? 'image/jpeg';
        // Session 69: two free reads that agree on the decision, else the paid reader (free-read.ts).
        const decide = (t: string) => usable<Ocr>(t, (o) => decisionKey(noticeFrom(o, c === 'hit', url), o), url);
        const read = await agreedRead(freeReads(OCR_PROMPT, bytes, mime), decide, () => visionExtractText(OCR_PROMPT, bytes, mime, 'Cascade Power Watch'));
        const o = parseModelJson<Ocr>(read.text.trim().replace(/^```(?:json)?\s*|\s*```$/g, ''), {});
        const n = noticeFrom(o, c === 'hit', url);
        log.push(`${url.split('/').pop()} ${c} ${read.via}${read.why ? `(${read.why})` : ''} -> ${n ? `ours ${n.date} ${n.time ?? ''} ${n.status}` : 'not ours'}`);
        if (n) state.ours[url] = n.date; // hit posters too: a moved poster's filename carries the moved-FROM date (D-295)
        if (n && (n.date >= today || (n.originalDate ?? '') >= today)) found.push({ ...n, postId: p.id });
        state.images.push(url);
      } catch (e) {
        complete = false; // read again next run
        console.warn('power_watch_read_failed', url.split('/').pop(), String(e).slice(0, 200));
      }
    }
    if (complete) state.done.push(p.id);
  }
  // What SOCOTECO's current posts say; null (unknown) when a poster is still unread, so nothing is ever freed on a half-read feed.
  // A poster is decided when it was read, or when its whole post is done (every poster of a done post was decided at the time).
  const sched = posts.map((p) => ({ id: p.id, posters: posterUrls(p.content?.rendered ?? '') }));
  const schedule = scheduleFrom(sched, state.ours, (u) => state.images.includes(u) || sched.some((p) => state.done.includes(p.id) && p.posters.includes(u)));
  let results: string[] = [];
  if (!dry) {
    // Blocks and cards first; the poster state is saved only after them, so a failure re-reads the posters rather than losing a notice.
    results = await reconcile({
      db, propertyId: PROPERTY_ID, today, now,
      send: async (c) => await tg(c.text, c.markup),
      sendFinance: async (c) => await tg(c.text, c.markup, 'TELEGRAM_FINANCE_CHAT_ID'),
      mail: (subject, body) => mail(db, subject, body),
      log: (event, data) => console.log(event, JSON.stringify(data)),
      posters: state.images, schedule,
    }, found);
    const pruned = await pruneStates(db, today);
    if (pruned) results.push(`pruned ${pruned} old notice states`);
    await db.from('app_settings').upsert({ key: STATE_KEY, value: { done: state.done.slice(-KEEP), images: state.images.slice(-KEEP), ours: Object.fromEntries(Object.entries(state.ours).filter(([u]) => state.images.slice(-KEEP).includes(u))) }, updated_at: new Date().toISOString() }, { onConflict: 'key' });
  }
  const out = {
    posts: posts.length, reads, dry, results, log, schedule: schedule ? { listed: [...schedule.listed].sort() } : null,
    found: found.map((n) => `${n.date} ${n.time ?? ''} ${n.hours ?? ''}h ${n.status} nights ${touchedNights(n.date, n.time, n.hours).join('+')}`),
  };
  console.log('power_watch_run', JSON.stringify(out));
  return out;
}

Deno.serve(withObservability({ functionName: 'power-watch', route: 'ops' }, async (req: Request) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);
  const secret = env('CASCADE_CRON_SHARED_SECRET');
  if (!secret || !cronSecretMatches(secret, req.headers.get('x-cascade-cron-secret'))) return json({ ok: false, error: 'unauthorized' }, 401);
  const dry = new URL(req.url).searchParams.get('dry') === '1';
  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
  const hb = heartbeat(db, 'power-watch-hourly');
  if (!dry) await hb('started');
  try {
    const out = await run(db, dry);
    if (!dry) await hb('succeeded');
    return json({ ok: true, ...out });
  } catch (e) {
    console.error('power_watch_failed', String(e).slice(0, 300));
    if (!dry) await hb('failed', String(e).slice(0, 60));
    return json({ ok: false, error: String(e).slice(0, 200) }, 500);
  }
}));
