// Session 69 (Lloyd 2026-10-04 "use all available free option as long as it is precise and that there are no false results"):
// SOCOTECO posters are public utility notices, so they are read free first. Two different free vision models on Cascade
// OmniRoute (Cloudflare Workers AI, no training on inputs; side-by-side 2026-10-03: Llama 4 Scout 6/6, Mistral Small 3.1 6/6)
// each read the poster, and their answer is used only when both give the SAME decision (ours or not, date, start, hours,
// cancelled, moved-from date). One failed, dateless or disagreeing read sends the poster to the paid reader, which decides
// alone as before. Guest photos and receipts never come here.
import { bytesToBase64, parseModelJson } from '../_shared/cascade-core/vision.ts';
import type { Notice } from './poster.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** One image read through a Cascade OmniRoute combo; returns the model text. */
async function omniVision(combo: string, prompt: string, b64: string, mime: string): Promise<string> {
  const url = env('CASCADE_OMNIROUTE_URL').replace(/\/+$/, ''), key = env('CASCADE_OMNIROUTE_KEY');
  if (!url || !key) throw new Error('omniroute_not_configured');
  const r = await fetch(`${url}/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}`, 'X-Title': 'Cascade Power Watch' },
    body: JSON.stringify({ model: combo, temperature: 0, max_tokens: 1500,
      messages: [{ role: 'user', content: [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: `data:${mime};base64,${b64}` } }] }] }),
    signal: AbortSignal.timeout(20_000), // both run at once; the run's wall clock also pays for the paid reader after them
  });
  if (!r.ok) throw new Error(`omniroute_vision_${r.status}: ${(await r.text()).slice(0, 200)}`);
  const j = await r.json();
  const u = j?.usage; if (u) console.log('llm_usage', JSON.stringify({ provider: 'omniroute', model: j?.model ?? combo, title: 'Cascade Power Watch', tier: 'vision-free', input: u.prompt_tokens, output: u.completion_tokens }));
  return j?.choices?.[0]?.message?.content ?? '';
}

/** Both free reads agree on `decide`, or the paid reader answers. `decide` returns null for a read that is not usable
 *  (no JSON, no date): two broken reads must never agree on "not ours". */
export async function agreedRead(
  reads: Array<() => Promise<string>>,
  decide: (text: string) => string | null,
  paid: () => Promise<string>,
): Promise<{ text: string; via: 'free' | 'paid'; why?: string }> {
  const got = await Promise.all(reads.map((r) => r().then((t) => ({ t, k: decide(t) }), (e) => {
    console.warn('power_watch_free_read_failed', String(e).slice(0, 200));
    return { t: '', k: null as string | null };
  })));
  const ok = got.length >= 2 && got.every((g) => g.k !== null && g.k === got[0].k);
  if (ok) return { text: got[0].t, via: 'free' };
  const why = got.length < 2 ? 'free_off' : got.some((g) => g.k === null) ? 'free_unusable' : 'free_disagree';
  return { text: await paid(), via: 'paid', why };
}

/** The free reads for one poster: one per combo in CASCADE_OMNIROUTE_VISION_MODELS (default the two single-model combos).
 *  Each combo must hold ONE model and no fallback, or both reads could come from the same model and agreement proves nothing. */
export function freeReads(prompt: string, bytes: Uint8Array, mime: string): Array<() => Promise<string>> {
  if (!env('CASCADE_OMNIROUTE_URL') || !env('CASCADE_OMNIROUTE_KEY')) return [];
  const combos = (env('CASCADE_OMNIROUTE_VISION_MODELS') || 'cascade-vision-scout,cascade-vision-mistral').split(',').map((s) => s.trim()).filter(Boolean);
  const b64 = bytesToBase64(bytes);
  return combos.map((c) => () => omniVision(c, prompt, b64, mime));
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
