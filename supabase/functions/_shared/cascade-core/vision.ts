// cascade-core vision (session 27, booking PRD task 2 — the OCR merge). One image-to-JSON call
// shared by ocr-receipt, telegram-expense and upload-booking-receipt. Same env contract as before
// (D-090, D-222): VISION_PROVIDER first (default openrouter), the other provider when it refuses; VISION_MODEL
// overrides the model for either; keys CASCADE_GEMINI_BOT_KEY / CASCADE_OPENROUTER_BOT_KEY only - the two model keys
// this project uses (01-FACTS). Returns the raw model text; callers parse — their JSON shapes differ.
const env = (k: string) => Deno.env.get(k) ?? '';
export const VISION_PROVIDER = (env('VISION_PROVIDER') || 'openrouter').toLowerCase(); // D-222: OpenRouter primary
// D-204.3: CASCADE_GEMINI_BOT_KEY only. The bare GEMINI_BOT_KEY / GEMINI_API_KEY no longer authenticate and the bare
// GEMINI_BOT_KEY belongs to another project (providers.ts), so a fallback could only drain it or fail late.
const GEMINI_KEY = env('CASCADE_GEMINI_BOT_KEY');
const OPENROUTER_KEY = env('CASCADE_OPENROUTER_BOT_KEY');
const GEMINI_MODEL = env('VISION_MODEL') || 'gemini-3.6-flash';
const OPENROUTER_MODEL = env('VISION_MODEL') || 'google/gemini-3.6-flash';
const JSON_H = { 'Content-Type': 'application/json' };

export const hasVisionKey = () => !!GEMINI_KEY || !!OPENROUTER_KEY;

export function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// Retry on 429 / 503 with linear backoff (the shape ocr-receipt v6 had).
export async function visionFetch(url: string, init: RequestInit, tries = 3): Promise<Response> {
  for (let i = 0; i < tries; i++) {
    const res = await fetch(url, init);
    if (res.ok || (res.status !== 429 && res.status !== 503)) return res;
    if (i < tries - 1) await new Promise((r) => setTimeout(r, 800 * (i + 1)));
  }
  return fetch(url, init);
}

/** Send one image + prompt; returns the model's text (expected JSON). VISION_PROVIDER (default openrouter, D-222) is
 *  tried first; the other provider is the fallback when the first has no key or refuses - the order providers.ts uses
 *  for text. */
// 2026-09-24 (BRIEF-ai-quality-framework): image reads sent no X-Title and logged no llm_usage, so their cost was invisible.
export async function visionExtractText(prompt: string, image: Uint8Array | string, mime: string, title = 'Cascade Reader'): Promise<string> {
  const b64 = typeof image === 'string' ? image : bytesToBase64(image);
  const orFirst = VISION_PROVIDER === 'openrouter';
  const [first, second] = orFirst ? [viaOpenRouter, viaGemini] : [viaGemini, viaOpenRouter];
  const [firstKey, secondKey] = orFirst ? [OPENROUTER_KEY, GEMINI_KEY] : [GEMINI_KEY, OPENROUTER_KEY];
  if (!firstKey) return await second(prompt, b64, mime, title);
  try {
    return await first(prompt, b64, mime, title);
  } catch (e) {
    if (!secondKey) throw e;
    console.warn('vision_fallback', JSON.stringify({ to: orFirst ? 'gemini' : 'openrouter', error: String(e).slice(0, 200) }));
    return await second(prompt, b64, mime, title);
  }
}

async function viaOpenRouter(prompt: string, b64: string, mime: string, title = 'Cascade Reader'): Promise<string> {
  if (!OPENROUTER_KEY) throw new Error('CASCADE_OPENROUTER_BOT_KEY not set');
  const res = await visionFetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST', headers: { ...JSON_H, Authorization: `Bearer ${OPENROUTER_KEY}`, 'X-Title': title },
    body: JSON.stringify({ model: OPENROUTER_MODEL, temperature: 0, response_format: { type: 'json_object' },
      messages: [{ role: 'user', content: [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: `data:${mime};base64,${b64}` } }] }] }),
    signal: AbortSignal.timeout(55_000),
  });
  const raw = await res.json();
  if (!res.ok) throw new Error(`openrouter_${res.status}: ${JSON.stringify(raw).slice(0, 300)}`);
  const u = raw?.usage; if (u) console.log('llm_usage', JSON.stringify({ provider: 'openrouter', model: raw?.model ?? OPENROUTER_MODEL, title, tier: 'vision', input: u.prompt_tokens, output: u.completion_tokens, cost_usd: u.cost }));
  return raw?.choices?.[0]?.message?.content ?? '';
}

async function viaGemini(prompt: string, b64: string, mime: string, title = 'Cascade Reader'): Promise<string> {
  if (!GEMINI_KEY) throw new Error('CASCADE_GEMINI_BOT_KEY not set');
  const res = await visionFetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}`, {
    method: 'POST', headers: JSON_H,
    body: JSON.stringify({ contents: [{ parts: [{ text: prompt }, { inline_data: { mime_type: mime, data: b64 } }] }], generationConfig: { temperature: 0, response_mime_type: 'application/json' } }),
    signal: AbortSignal.timeout(55_000),
  });
  const raw = await res.json();
  if (!res.ok) throw new Error(`gemini_${res.status}: ${JSON.stringify(raw).slice(0, 300)}`);
  const u = raw?.usageMetadata; if (u) console.log('llm_usage', JSON.stringify({ provider: 'gemini', model: GEMINI_MODEL, title, tier: 'vision', input: u.promptTokenCount, output: u.candidatesTokenCount }));
  // deno-lint-ignore no-explicit-any
  return raw?.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join('') ?? '';
}

/** Lenient JSON parse of a model reply (strips a ```json fence); returns fallback when unparsable. */
export function parseModelJson<T>(text: string, fallback: T): T {
  try { return JSON.parse(String(text).replace(/^```json\s*|\s*```$/g, '').trim()) as T; } catch { return fallback; }
}
