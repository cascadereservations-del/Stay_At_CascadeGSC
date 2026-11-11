// D-366 (2026-11-11): two primaries that disagree no longer go straight to the paid reader. In the 123-run loop of
// 2026-11-10/11 the same poster kept splitting the pair and every run paid again. Now the extra models in
// CASCADE_OMNIROUTE_VISION_TIEBREAK read it one at a time, only while the run's read budget allows, and stop as soon as
// ANY two usable reads share a decision key; otherwise the paid reader decides alone. An empty list is the old behaviour.
// Session 69 (Lloyd 2026-10-04 "use all available free option as long as it is precise and that there are no false results"):
// SOCOTECO posters are public utility notices, so they are read free first. Two different free vision models on Cascade
// OmniRoute (Cloudflare Workers AI, no training on inputs; side-by-side 2026-10-03: Llama 4 Scout 6/6, Mistral Small 3.1 6/6)
// each read the poster, and their answer is used only when both give the SAME decision (ours or not, date, start, hours,
// cancelled, moved-from date). One failed, dateless or disagreeing read sends the poster to the paid reader, which decides
// alone as before. Guest photos and receipts never come here.
import { bytesToBase64, parseModelJson } from '../_shared/cascade-core/vision.ts';
import { recordUsage } from '../_shared/cascade-core/usage.ts';
import type { Notice } from './poster.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** One image read by one model on Cascade OmniRoute; returns the model text. */
async function omniVision(model: string, prompt: string, b64: string, mime: string): Promise<string> {
  const url = env('CASCADE_OMNIROUTE_URL').replace(/\/+$/, ''), key = env('CASCADE_OMNIROUTE_KEY');
  if (!url || !key) throw new Error('omniroute_not_configured');
  const row = { provider: 'omniroute' as const, model, title: 'Cascade Power Watch', tier: 'vision-free' };
  const r = await fetch(`${url}/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}`, 'X-Title': 'Cascade Power Watch' },
    body: JSON.stringify({ model, temperature: 0, max_tokens: 1500,
      messages: [{ role: 'user', content: [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: `data:${mime};base64,${b64}` } }] }] }),
    signal: AbortSignal.timeout(30_000), // both run at once (full-size poster 2026-10-04: Scout 27 s, Mistral 14 s); index.ts caps the run's reads at 90 s
  }).catch((e) => { recordUsage({ ...row, ok: false, error: `omniroute_vision_${e?.name ?? 'fetch_error'}` }); throw e; });
  if (!r.ok) { recordUsage({ ...row, ok: false, error: `omniroute_vision_${r.status}` }); throw new Error(`omniroute_vision_${r.status}: ${(await r.text()).slice(0, 200)}`); }
  const j = await r.json();
  const u = j?.usage; recordUsage({ ...row, model: j?.model ?? model, input: u?.prompt_tokens, output: u?.completion_tokens });
  return j?.choices?.[0]?.message?.content ?? '';
}

/** Both free reads agree on `decide`, or the paid reader answers. `decide` returns null for a read that is not usable
 *  (no JSON, no date): two broken reads must never agree on "not ours". When the two primaries do not agree, the
 *  `tiebreaks` run one at a time (D-366) until any two usable reads share a decision key; `canTiebreak` lets the caller
 *  skip them when the run's read budget is nearly used. */
export async function agreedRead(
  reads: Array<() => Promise<string>>,
  decide: (text: string) => string | null,
  paid: () => Promise<string>,
  tiebreaks: Array<() => Promise<string>> = [],
  canTiebreak: () => boolean = () => true,
): Promise<{ text: string; via: 'free' | 'paid'; why?: string }> {
  const run = (r: () => Promise<string>) => r().then((t) => ({ t, k: decide(t) }), (e) => {
    console.warn('power_watch_free_read_failed', String(e).slice(0, 200));
    return { t: '', k: null as string | null };
  });
  const got = await Promise.all(reads.map(run));
  if (got.length >= 2 && got.every((g) => g.k !== null && g.k === got[0].k)) return { text: got[0].t, via: 'free' };
  if (got.length >= 2) {
    // Two usable reads in all, from the primaries or the tiebreaks so far, that share a key win; null never matches.
    const pair = () => got.find((g, i) => g.k !== null && got.some((h, j) => j !== i && h.k === g.k));
    for (const tb of tiebreaks) {
      if (!canTiebreak()) break;
      got.push(await run(tb));
      const hit = pair();
      if (hit) return { text: hit.t, via: 'free', why: 'tiebreak' };
    }
  }
  const why = got.length < 2 ? 'free_off' : got.some((g) => g.k === null) ? 'free_unusable' : 'free_disagree';
  return { text: await paid(), via: 'paid', why };
}

/** The free reads for one poster: one per model in CASCADE_OMNIROUTE_VISION_MODELS. Direct model ids, not combos: an OmniRoute
 *  combo sends an image through its vision bridge (503 "Codex app-server transport is not configured", 2026-10-04) while a
 *  direct model id reads it; a direct id also cannot fall back to the other model, so two reads are two models. */
export function freeReads(prompt: string, bytes: Uint8Array, mime: string): Array<() => Promise<string>> {
  if (!env('CASCADE_OMNIROUTE_URL') || !env('CASCADE_OMNIROUTE_KEY')) return [];
  const models = (env('CASCADE_OMNIROUTE_VISION_MODELS') || 'cloudflare-ai/@cf/meta/llama-4-scout-17b-16e-instruct,cloudflare-ai/@cf/mistralai/mistral-small-3.1-24b-instruct')
    .split(',').map((s) => s.trim()).filter(Boolean);
  const b64 = bytesToBase64(bytes);
  return models.map((m) => () => omniVision(m, prompt, b64, mime));
}

/** Extra OmniRoute direct models (CASCADE_OMNIROUTE_VISION_TIEBREAK, comma list; empty = none) tried one at a time by agreedRead
 *  when the two primary reads disagree (D-366). */
export function freeTiebreaks(prompt: string, bytes: Uint8Array, mime: string): Array<() => Promise<string>> {
  if (!env('CASCADE_OMNIROUTE_URL') || !env('CASCADE_OMNIROUTE_KEY')) return [];
  const models = env('CASCADE_OMNIROUTE_VISION_TIEBREAK').split(',').map((s) => s.trim()).filter(Boolean);
  if (!models.length) return [];
  const b64 = bytesToBase64(bytes);
  return models.map((m) => () => omniVision(m, prompt, b64, mime));
}

/** What two reads must agree on: ours with the same date, start, hours, status and moved-from date, or not ours with the
 *  same date and start the poster gives (review 2026-10-04: two reads that differ on the date are not a trustworthy
 *  "not ours"). Title and purpose wording may differ between models; they never change a block or a card's timing. */
export const decisionKey = (n: Notice | null, o: { date?: string | null; start?: string | null }) =>
  n ? JSON.stringify(['ours', n.date, n.time, n.hours, n.status, n.originalDate]) : JSON.stringify(['not ours', o.date ?? null, String(o.start ?? '').slice(0, 5)]);

/** A read is usable only when it is JSON with a real date, and, when the filename carries MMDDYYYY, that date (or the
 *  moved-from date) is the filename's: two small models can share the same wrong year (review 2026-10-04). A poster whose
 *  filename and printed date differ goes to the paid reader. */
export function usable<T extends { date?: string | null; original_date?: string | null }>(text: string, key: (o: T) => string, url = ''): string | null {
  const o = parseModelJson<T | null>(String(text).trim().replace(/^```(?:json)?\s*|\s*```$/g, ''), null);
  if (!o || typeof o !== 'object' || !DATE.test(String(o.date ?? ''))) return null;
  const fm = /(\d{2})(\d{2})(20\d{2})/.exec(decodeURIComponent(url.split('/').pop() ?? ''));
  if (fm && ![o.date, o.original_date].includes(`${fm[3]}-${fm[1]}-${fm[2]}`)) return null;
  return key(o);
}
