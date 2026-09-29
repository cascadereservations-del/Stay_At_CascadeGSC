// power-watch v1 (D-284, Lloyd 2026-09-29 "A"): SOCOTECO II scheduled power interruptions for our feeder 14-3.
// Hourly from pg_cron (x-cascade-cron-secret, Vault). Reads socoteco2.com's WordPress feed (free), decides each poster by
// its filename where it can (poster.ts) and reads the rest with the vision helper the receipts already use. A poster that
// is ours becomes an ops_notices brownout (the daily digest and Cassy read it) and one alert to Telegram OPS and the host
// inbox. An outage someone already put on the board (same day and start) is not repeated. Guests are not told: they hear
// about utilities only if they ask (Lloyd 2026-09-29).
// State: app_settings.power_watch_state {done: post ids, images: poster URLs already decided}; an image is only marked
// once it was decided, so a many-poster notice is read across runs (the Apps Script marked the whole post after 4).
// Not covered: unscheduled outages, which SOCOTECO posts on Facebook only (paid scraping; free tier first). The staff
// house fact carries their 24/7 hotline.
// ?dry=1 decides and logs but writes, alerts and marks nothing.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { withHeader } from '../_shared/cascade-core/format.ts';
import { parseModelJson, visionExtractText } from '../_shared/cascade-core/vision.ts';
import { alertText, classifyFile, FEEDER, isPowerPost, noticeFrom, OCR_PROMPT, posterUrls, type Notice, type Ocr } from './poster.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const FEED = 'https://www.socoteco2.com/wp-json/wp/v2/posts?per_page=10&orderby=date&_fields=id,date,link,title,content';
const UA = { 'User-Agent': 'Mozilla/5.0 (compatible; CascadeOpsWatch/1.0)' };
const STATE_KEY = 'power_watch_state';
const MAX_READS = 4;   // poster reads per run; the rest wait for the next hour
const KEEP = 300;
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
// deno-lint-ignore no-explicit-any
type Db = any;

async function tg(text: string): Promise<boolean> {
  const token = env('TELEGRAM_BOT_TOKEN'), chat = env('TELEGRAM_CHAT_ID');
  if (!token || !chat) return false;
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  return !!r?.ok;
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

/** Board + alert, once per outage: skipped when a brownout for that day and start (or with no start) is already on it. */
async function publish(db: Db, n: Notice): Promise<'new' | 'known'> {
  const { data: same } = await db.from('ops_notices').select('id, effective_time').eq('notice_type', 'brownout').eq('effective_date', n.date).eq('is_active', true);
  if ((same ?? []).some((r: { effective_time: string | null }) => !r.effective_time || !n.time || r.effective_time === n.time)) return 'known';
  const { error } = await db.from('ops_notices').insert({
    property_id: PROPERTY_ID, notice_type: 'brownout', title: n.title, description: `${n.purpose ? n.purpose + ' | ' : ''}poster ${n.poster}`,
    effective_date: n.date, effective_time: n.time, duration_hours: n.hours, feeder: `Feeder ${FEEDER}`, posted_by_name: 'Power watch (socoteco2.com)',
  });
  if (error) throw new Error(`ops_notices: ${error.message}`);
  const a = alertText(n);
  const [t, m] = await Promise.all([tg(withHeader('attention', `brownout ${a.subject.replace('Brownout at Cascade: ', '')}`, a.body)), mail(db, a.subject, a.body)]);
  console.log('power_watch_alert', JSON.stringify({ date: n.date, time: n.time, telegram: t, email: m }));
  return 'new';
}

async function run(db: Db, dry: boolean): Promise<Record<string, unknown>> {
  const res = await fetch(FEED, { headers: UA, signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`socoteco_feed_${res.status}`);
  // deno-lint-ignore no-explicit-any
  const posts = ((await res.json()) as any[]).filter(isPowerPost);
  const { data: st } = await db.from('app_settings').select('value').eq('key', STATE_KEY).maybeSingle();
  const state = { done: [...(st?.value?.done ?? [])] as number[], images: [...(st?.value?.images ?? [])] as string[] };
  const today = new Date(Date.now() + 8 * 3_600_000).toISOString().slice(0, 10);
  const found: Notice[] = [], log: string[] = [];
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
        log.push(`${url.split('/').pop()} ${c} -> ${n ? `ours ${n.date} ${n.time ?? ''}` : 'not ours'}`);
        if (n && n.date >= today) found.push(n);
        state.images.push(url);
      } catch (e) {
        complete = false; // read again next hour
        console.warn('power_watch_read_failed', url.split('/').pop(), String(e).slice(0, 200));
      }
    }
    if (complete) state.done.push(p.id);
  }
  const results: string[] = [];
  if (!dry) {
    for (const n of found) results.push(`${n.date}: ${await publish(db, n)}`);
    await db.from('app_settings').upsert({ key: STATE_KEY, value: { done: state.done.slice(-KEEP), images: state.images.slice(-KEEP) }, updated_at: new Date().toISOString() }, { onConflict: 'key' });
  }
  const out = { posts: posts.length, reads, found: found.map((n) => `${n.date} ${n.time ?? ''} ${n.hours ?? ''}h`), results, log, dry };
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
