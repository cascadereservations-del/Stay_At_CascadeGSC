// verify-meter-photo v1 — reads the meter photo and checks it against the
// number the cleaner typed. Cascade Hideaway, 2026-09-13.
//
// Source of record: this file was pulled from the deployed v22 on 2026-09-16
// (Sprint 0) because no local copy existed; the only change since is the
// job heartbeat at the bottom of the handler.
//
// Why this exists. The checklist already checks the arithmetic (D-084), the
// file's timestamp, whether the same file was used twice, and whether the file
// looks like a screenshot (2026-09-13). None of that opens the image. A
// plausible number attached to a photo of last week's meter passes every one
// of those checks. This layer actually looks.
//
// It runs AFTER the fact, never in the submit path. A cleaner standing at the
// meter at 6am must not wait on a vision model, and a provider outage must
// never cost a report. A verdict of 'error' is our problem, not hers, and the
// sweep simply tries again.
//
// Provider-agnostic on purpose (Lloyd, 2026-09-13): the Cascade estate already
// holds a Gemini key and an OpenRouter key, so the provider is an env var and
// switching is config, not a rewrite. Same contract either way.
//
//   VISION_PROVIDER    gemini (default) | openrouter
//   CASCADE_GEMINI_BOT_KEY       (the only Gemini key; no fallback, D-204.3)
//   CASCADE_OPENROUTER_BOT_KEY   (falls back to OPENROUTER_API_KEY)
//   VISION_MODEL       optional per-provider override
//   TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID   the OPS group, as everywhere else
//   TELEGRAM_FINANCE_CHAT_ID               mirrored to for money verdicts only
//
// POST body, every field optional:
//   { submission_id?: string,  // check one report
//     property_id?: string,
//     lookback?: number,       // sweep mode, days back      (default 7)
//     limit?: number,          // sweep mode, how many       (default 10)
//     notify?: boolean }       // default true; false = write the verdict only

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { heartbeat } from '../_shared/heartbeat.ts';

// Deliberately NOT importing ../_shared/observability.ts. Every other ops
// function wraps itself in it for redacted logging, and that is right for
// functions that log guest names, amounts or message bodies. This one logs a
// verdict and a count and nothing else, so pulling in the shared module would
// mean vendoring two more files into this repo purely to satisfy an import.
// If this function ever starts logging anything about a person, wrap it.

const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const BUCKET      = 'cleaning-photos';

const PROVIDER       = (Deno.env.get('VISION_PROVIDER') ?? 'gemini').toLowerCase();
// The keys were rotated on 2026-09-12 into the CASCADE_-prefixed names. The
// older GEMINI_BOT_KEY and GEMINI_API_KEY secrets no longer authenticate, and
// the bare GEMINI_BOT_KEY belongs to another project: CASCADE_GEMINI_BOT_KEY
// only, no fallback (D-204.3).
const GEMINI_KEY     = Deno.env.get('CASCADE_GEMINI_BOT_KEY') ?? '';
const OPENROUTER_KEY = Deno.env.get('CASCADE_OPENROUTER_BOT_KEY')
                    ?? Deno.env.get('OPENROUTER_API_KEY') ?? '';

// gemini-2.5-flash was copied from ocr-receipt and is now refused for new
// callers: "no longer available to new users, please update to
// models/gemini-3.6-flash". Copying a working sibling's model id is not the
// same as checking the model is still offered. ocr-receipt is very likely in
// the same position — worth testing a receipt.
const GEMINI_MODEL     = Deno.env.get('VISION_MODEL') ?? 'gemini-3.6-flash';
const OPENROUTER_MODEL = Deno.env.get('VISION_MODEL') ?? 'google/gemini-3.6-flash';

// How far a read may sit from the typed number before it counts as a mismatch.
// The failure worth catching is a wrong digit in a five-digit index, not a
// rounding difference — and a tolerance that is too tight would accuse an
// honest cleaner every week.
const ELECTRIC_TOLERANCE = 2;    // kWh
const WATER_TOLERANCE    = 0.5;  // m³
// Below this the model is guessing, and a guess must never accuse anyone.
const MIN_CONFIDENCE     = 0.55;

// Which verdicts Finance is shown. OPS sees every finding, as before. Finance
// sees only the two that can cost money before a cleaning fee is paid: a photo
// that disagrees with the typed number, and a photo that is not a meter at all.
// 'unreadable' deliberately stops at OPS — a dark or angled photo is not a
// fault and must never reach the people who approve payment as if it were
// (D-197: unreadable never becomes an accusation).
const MONEY_VERDICTS = new Set(['mismatch', 'not_a_meter']);

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const JSON_HEADERS = { 'Content-Type': 'application/json' };

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, ...JSON_HEADERS } });
}

function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(bin);
}

async function tgSend(token: string, chatId: string, text: string): Promise<boolean> {
  const resp = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: JSON_HEADERS,
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' }),
    signal: AbortSignal.timeout(15_000),
  }).catch(() => null);
  if (resp && !resp.ok) console.warn(`tgSend failed ${resp.status}`);
  return !!resp?.ok;
}

// Retry on 429/503 with linear backoff — same shape ocr-receipt has been
// running against these providers for months.
async function fetchRetry(url: string, init: RequestInit, tries = 3): Promise<Response> {
  for (let i = 0; i < tries; i++) {
    const res = await fetch(url, init);
    if (res.ok || (res.status !== 429 && res.status !== 503)) return res;
    if (i < tries - 1) await new Promise((r) => setTimeout(r, 800 * (i + 1)));
  }
  return fetch(url, init);
}

type Which = 'electric' | 'water';

const PROMPT = (which: Which) => `You are reading a utility meter in a photograph, for a boutique Airbnb in General Santos City, Philippines.

This should be the ${which === 'electric'
  ? 'ELECTRIC meter — a digital 7-segment LCD, usually behind glass, often shot at an angle with glare'
  : 'WATER meter — a round mechanical dial face with a row of number wheels, often dusty and in poor light'}.

Return ONLY a JSON object, no markdown and no prose:
{
  "is_meter": boolean,
  "meter_type": "electric" | "water" | "unknown",
  "reading": number | null,
  "confidence": number,
  "note": string
}

Rules that matter more than producing a number:
- If you cannot read the digits confidently, set reading to null and confidence below 0.3. A wrong number here accuses an honest person of faking a reading, so saying "I cannot read it" is far better than guessing.
- ${which === 'electric'
  ? 'Read only the main kWh index. Ignore any tariff, demand or clock display.'
  : 'Read the black and white number wheels, which are whole cubic metres. Ignore the small red dials, which are fractions.'}
- If it is a screenshot, a photo of a screen, a photo of another photograph, or not a meter at all, set is_meter false and say so in note.
- Never invent digits hidden by glare, dirt or a reflection.`;

type VisionResult = {
  is_meter: boolean;
  meter_type: string;
  reading: number | null;
  confidence: number;
  note: string;
};

const EMPTY: VisionResult = { is_meter: false, meter_type: 'unknown', reading: null, confidence: 0, note: 'no answer' };

function parseModelJson(text: string): VisionResult {
  try {
    const o = JSON.parse(String(text).replace(/^```json\s*|\s*```$/g, '').trim());
    const n = o.reading === null || o.reading === undefined ? null : Number(o.reading);
    return {
      is_meter: !!o.is_meter,
      meter_type: String(o.meter_type ?? 'unknown'),
      reading: n !== null && isFinite(n) ? n : null,
      confidence: Math.max(0, Math.min(1, Number(o.confidence) || 0)),
      note: String(o.note ?? '').slice(0, 300),
    };
  } catch {
    return { ...EMPTY, note: 'model did not return usable JSON' };
  }
}

async function readWithGemini(b64: string, mime: string, which: Which): Promise<VisionResult> {
  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}`;
  const res = await fetchRetry(endpoint, {
    method: 'POST', headers: JSON_HEADERS,
    body: JSON.stringify({
      contents: [{ parts: [{ text: PROMPT(which) }, { inline_data: { mime_type: mime, data: b64 } }] }],
      generationConfig: { temperature: 0, response_mime_type: 'application/json' },
    }),
    signal: AbortSignal.timeout(55_000),
  });
  const raw = await res.json();
  // Keep the body. v1 threw `gemini_400` and discarded the reason, which made
  // the first real failure in production undiagnosable from the stored row.
  if (!res.ok) throw new Error(`gemini_${res.status}: ${JSON.stringify(raw).slice(0, 400)}`);
  return parseModelJson(raw?.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join('') ?? '');
}

async function readWithOpenRouter(b64: string, mime: string, which: Which): Promise<VisionResult> {
  const res = await fetchRetry('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: { ...JSON_HEADERS, Authorization: `Bearer ${OPENROUTER_KEY}` },
    body: JSON.stringify({
      model: OPENROUTER_MODEL,
      temperature: 0,
      response_format: { type: 'json_object' },
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: PROMPT(which) },
          { type: 'image_url', image_url: { url: `data:${mime};base64,${b64}` } },
        ],
      }],
    }),
    signal: AbortSignal.timeout(55_000),
  });
  const raw = await res.json();
  if (!res.ok) throw new Error(`openrouter_${res.status}: ${JSON.stringify(raw).slice(0, 400)}`);
  return parseModelJson(raw?.choices?.[0]?.message?.content ?? '');
}

async function readMeter(b64: string, mime: string, which: Which): Promise<VisionResult> {
  if (PROVIDER === 'openrouter') {
    if (!OPENROUTER_KEY) throw new Error('OPENROUTER_API_KEY not set');
    return await readWithOpenRouter(b64, mime, which);
  }
  if (!GEMINI_KEY) throw new Error('CASCADE_GEMINI_BOT_KEY not set');
  return await readWithGemini(b64, mime, which);
}

/* A water meter face is number wheels plus fraction dials, and a reader can
   easily return the digits without the decimal point: the 2026-09-03 report
   recorded 70.873 m3 and the first sweep read the same face as "708", which
   was recorded as a mismatch. The digits agree; only the decimal placement
   differs, and that is a reading convention rather than a discrepancy.

   So before calling a mismatch, try shifting the read by powers of ten. This
   forgives 708 against 70.873 and still catches 3814 against 3832, because
   no power of ten makes different digits agree. Loosening the tolerance
   instead would have hidden real differences. */
function agreesAllowingForDecimalPoint(read: number, typed: number, tol: number): boolean {
  // The prompt asks for the WHOLE cubic metres and to ignore the fraction
  // dials, so a correct read of a 68.827 face is "68" — and comparing that to
  // the typed 68.827 flagged a mismatch on the first full sweep. The fault was
  // mine on both sides: the instruction and the comparison disagreed. The
  // whole-number part of the typed reading is therefore an accepted answer.
  const targets = [typed, Math.floor(typed)];
  for (let k = -2; k <= 3; k++) {
    const scaled = read / Math.pow(10, k);
    for (const t of targets) {
      if (Math.abs(scaled - t) <= tol) return true;
    }
  }
  return false;
}

// One verdict for the pair. The order is deliberate: "not a meter" outranks
// "mismatch", because a screenshot is a different conversation from a misread
// digit, and "unreadable" never becomes an accusation.
function verdictFor(
  typedE: number | null,
  typedW: number | null,
  e: VisionResult | null,
  w: VisionResult | null,
): { verdict: string; lines: string[] } {
  const lines: string[] = [];
  let notMeter = false, mismatch = false, unreadable = false;

  // v2: a null result means NO PHOTO WAS FOUND, and v1 returned early on it —
  // so a report with no meter photos in Storage at all came back "ok". Absent
  // evidence scored as verified evidence, which is the worst possible way for
  // a verification layer to be wrong. It is now stated plainly.
  const one = (label: string, typed: number | null, r: VisionResult | null, tol: number) => {
    if (!r) {
      unreadable = true;
      lines.push(`${label}: no meter photo found in storage for this report`);
      return;
    }
    if (!r.is_meter) {
      notMeter = true;
      lines.push(`${label}: the photo does not look like a meter${r.note ? ` — ${r.note}` : ''}`);
      return;
    }
    if (r.reading === null || r.confidence < MIN_CONFIDENCE) {
      unreadable = true;
      lines.push(`${label}: could not be read with confidence${r.note ? ` — ${r.note}` : ''}`);
      return;
    }
    if (typed !== null && !agreesAllowingForDecimalPoint(r.reading, typed, tol)) {
      mismatch = true;
      lines.push(`${label}: the photo reads ${r.reading}, the report says ${typed}`);
    }
  };

  one('Electric', typedE, e, ELECTRIC_TOLERANCE);
  one('Water', typedW, w, WATER_TOLERANCE);

  return {
    verdict: notMeter ? 'not_a_meter' : mismatch ? 'mismatch' : unreadable ? 'unreadable' : 'ok',
    lines,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  let body: any = {};
  try { body = await req.json(); } catch { /* sweep mode with an empty body is fine */ }

  const propertyId = String(body.property_id ?? PROPERTY_ID);
  const notify = body.notify !== false;

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );
  // Sprint 0 (2026-09-16): liveness for the job-heartbeat-monitor. A single-report
  // check (submission_id) is a manual call, not the daily sweep, so it does not beat.
  const hb = body.submission_id ? null : heartbeat(db, 'verify-meter-photo-daily');
  if (hb) await hb('started');

  const TG_TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
  const TG_CHAT  = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';   // OPS group
  const TG_FINANCE = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';

  // Which sessions are we checking?
  let targets: any[] = [];
  if (body.submission_id) {
    const { data, error } = await db
      .from('cleaning_sessions')
      .select('id, submission_id, cleaned_at, cleaner_name, meter_readings(electric_curr, water_curr)')
      .eq('submission_id', String(body.submission_id))
      .limit(1);
    if (error) return json({ ok: false, error: error.message }, 500);
    targets = (data ?? []).map((r: any) => ({
      session_id: r.id,
      submission_id: r.submission_id,
      cleaned_at: r.cleaned_at,
      cleaner_name: r.cleaner_name,
      electric_curr: r.meter_readings?.[0]?.electric_curr ?? null,
      water_curr: r.meter_readings?.[0]?.water_curr ?? null,
    }));
  } else {
    const { data, error } = await db.rpc('get_meter_sessions_pending_vision', {
      p_property_id: propertyId,
      p_lookback: Number(body.lookback ?? 7),
      p_limit: Number(body.limit ?? 10),
    });
    if (error) { if (hb) await hb('failed', error.message.slice(0, 80)); return json({ ok: false, error: error.message }, 500); }
    targets = data ?? [];
  }

  if (!targets.length) { if (hb) await hb('succeeded'); return json({ ok: true, checked: 0, note: 'nothing pending' }); }
  let notifyFailures = 0;

  const results: any[] = [];

  for (const t of targets) {
    // Photos filed before the 2026-09-12 Storage fix carry no submission id in
    // their path, so they are matched by upload time instead — NOT by the date
    // folder, which is the app's upload date and collides when two reports
    // share a day. That collision produced a false mismatch against the
    // cleaner on the first sweep; see sql/2026-09-13c.
    const { data: objects, error: objErr } = await db.rpc('get_meter_photo_objects', {
      p_submission_id: t.submission_id,
      p_cleaned_at: t.cleaned_at ?? null,
    });
    if (objErr) { results.push({ submission_id: t.submission_id, error: objErr.message }); continue; }

    const pathFor = (which: Which) =>
      (objects ?? []).find((o: any) => o.meter === which)?.object_name ?? null;
    const paths = { electric: pathFor('electric'), water: pathFor('water') };

    const read = async (which: Which): Promise<VisionResult | null> => {
      const path = paths[which];
      if (!path) return null;
      const { data: blob, error } = await db.storage.from(BUCKET).download(path);
      if (error || !blob) return { ...EMPTY, note: 'photo could not be downloaded' };
      const b64 = bytesToBase64(new Uint8Array(await blob.arrayBuffer()));
      // A download can arrive as application/octet-stream. Every meter photo
      // this app writes is a JPEG, and the providers reject a non-image type
      // outright, so fall back rather than forward a type they will refuse.
      const mime = /^image\//.test(blob.type || '') ? blob.type : 'image/jpeg';
      return await readMeter(b64, mime, which);
    };

    let e: VisionResult | null = null;
    let w: VisionResult | null = null;
    let failed: string | null = null;
    try {
      e = await read('electric');
      w = await read('water');
    } catch (err) {
      failed = String(err).slice(0, 200);
    }

    if (failed) {
      // A provider outage is ours, not the cleaner's. Recorded as an error so
      // the next sweep retries; never as a finding against anyone.
      await db.from('meter_readings').update({
        vision_verdict: 'error',
        vision_checked_at: new Date().toISOString(),
        vision_raw: { error: failed, provider: PROVIDER },
      }).eq('session_id', t.session_id);
      results.push({ submission_id: t.submission_id, verdict: 'error' });
      continue;
    }

    const { verdict, lines } = verdictFor(
      t.electric_curr === null ? null : Number(t.electric_curr),
      t.water_curr === null ? null : Number(t.water_curr),
      e, w,
    );

    await db.from('meter_readings').update({
      vision_electric: e?.reading ?? null,
      vision_water: w?.reading ?? null,
      vision_confidence: Math.min(e?.confidence ?? 1, w?.confidence ?? 1),
      vision_verdict: verdict,
      vision_checked_at: new Date().toISOString(),
      vision_raw: {
        provider: PROVIDER,
        model: PROVIDER === 'openrouter' ? OPENROUTER_MODEL : GEMINI_MODEL,
        electric: e, water: w, paths,
      },
    }).eq('session_id', t.session_id);

    results.push({ submission_id: t.submission_id, verdict, lines });

    if (notify && verdict !== 'ok' && TG_TOKEN && TG_CHAT) {
      const when = new Date(t.cleaned_at).toLocaleDateString('en-PH', {
        timeZone: 'Asia/Manila', month: 'short', day: 'numeric',
      });
      const head = verdict === 'not_a_meter' ? '🚩 *Meter photo is not a meter*'
                 : verdict === 'mismatch'    ? '🚩 *Meter photo disagrees with the reading*'
                 : '👀 *Meter photo could not be read*';
      const text = [
        head,
        `🏠 Cascade Hideaway`,
        `${when} · ${t.cleaner_name ?? 'unknown cleaner'}`,
        ``,
        ...lines.map((l) => `• ${l}`),
        ``,
        verdict === 'unreadable'
          ? `_Not necessarily a fault — the photo may just be dark or angled. A re-upload will be asked for at the next sign-in._`
          : `_A re-upload will be asked for at the next sign-in. Worth checking before the cleaning fee is paid._`,
      ].join('\n');

      // SPEC-17 (D-212): a verdict nobody was told about is counted as a failed run, not a quiet one.
      if (!(await tgSend(TG_TOKEN, TG_CHAT, text))) notifyFailures += 1;

      // The same message, not a summary of it: Finance and OPS must never be
      // reading two different accounts of one photo. Sent only when the two
      // chats really are different, so a single-group estate is not told twice.
      if (MONEY_VERDICTS.has(verdict) && TG_FINANCE && TG_FINANCE !== TG_CHAT) {
        await tgSend(TG_TOKEN, TG_FINANCE, text);
      }
    }
  }

  console.log(`[verify-meter-photo] provider=${PROVIDER} checked=${results.length}`);
  if (hb) await (notifyFailures > 0 ? hb('failed', `TELEGRAM_SEND_FAILED:${notifyFailures}`) : hb('succeeded'));
  return json({ ok: true, provider: PROVIDER, checked: results.length, results });
});
