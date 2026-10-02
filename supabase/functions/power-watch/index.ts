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
// ?dry=1 decides and logs but writes, alerts and marks nothing.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { parseModelJson, visionExtractText } from '../_shared/cascade-core/vision.ts';
import { classifyFile, isPowerPost, noticeFrom, OCR_PROMPT, posterUrls, type Ocr } from './poster.ts';
import { touchedNights } from './plan.ts';
import { pruneStates, reconcile, type Found } from './watch.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const FEED = 'https://www.socoteco2.com/wp-json/wp/v2/posts?per_page=10&orderby=date&_fields=id,date,link,title,content';
const UA = { 'User-Agent': 'Mozilla/5.0 (compatible; CascadeOpsWatch/1.0)' };
const STATE_KEY = 'power_watch_state';
const MAX_READS = 4;   // poster reads per run; the rest wait for the next run
const KEEP = 300;
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
// deno-lint-ignore no-explicit-any
type Db = any;

/** A card to the OPS chat. Plain text (no parse_mode): the buttons are the card's own. */
async function tg(text: string, markup?: unknown): Promise<boolean> {
  const token = env('TELEGRAM_BOT_TOKEN'), chat = env('TELEGRAM_CHAT_ID');
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
  const state = { done: [...(st?.value?.done ?? [])] as number[], images: [...(st?.value?.images ?? [])] as string[] };
  const now = new Date();
  const today = new Date(now.getTime() + 8 * 3_600_000).toISOString().slice(0, 10);
  const found: Found[] = [], log: string[] = [];
  let reads = 0;
  for (const p of posts) {
    if (state.done.includes(p.id)) continue;
    let complete = true;
    for (const url of posterUrls(p.content?.rendered ?? '')) {
      if (state.images.includes(url)) continue;
      const c = classifyFile(url);
      if (c === 'miss') { state.images.push(url); continue; }
      if (reads >= MAX_READS) { complete = false; break; }
      reads++;
      try {
        const img = await fetch(url, { headers: UA, signal: AbortSignal.timeout(30_000) });
        if (!img.ok) throw new Error(`poster_${img.status}`);
        const o = parseModelJson<Ocr>(await visionExtractText(OCR_PROMPT, new Uint8Array(await img.arrayBuffer()), img.headers.get('content-type') ?? 'image/jpeg', 'Cascade Power Watch'), {});
        const n = noticeFrom(o, c === 'hit', url);
        log.push(`${url.split('/').pop()} ${c} -> ${n ? `ours ${n.date} ${n.time ?? ''} ${n.status}` : 'not ours'}`);
        if (n && (n.date >= today || (n.originalDate ?? '') >= today)) found.push({ ...n, postId: p.id });
        state.images.push(url);
      } catch (e) {
        complete = false; // read again next run
        console.warn('power_watch_read_failed', url.split('/').pop(), String(e).slice(0, 200));
      }
    }
    if (complete) state.done.push(p.id);
  }
  let results: string[] = [];
  if (!dry) {
    // Blocks and cards first; the poster state is saved only after them, so a failure re-reads the posters rather than losing a notice.
    results = await reconcile({
      db, propertyId: PROPERTY_ID, today, now,
      send: async (c) => await tg(c.text, c.markup),
      mail: (subject, body) => mail(db, subject, body),
      log: (event, data) => console.log(event, JSON.stringify(data)),
    }, found);
    const pruned = await pruneStates(db, today);
    if (pruned) results.push(`pruned ${pruned} old notice states`);
    await db.from('app_settings').upsert({ key: STATE_KEY, value: { done: state.done.slice(-KEEP), images: state.images.slice(-KEEP) }, updated_at: new Date().toISOString() }, { onConflict: 'key' });
  }
  const out = {
    posts: posts.length, reads, dry, results, log,
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
