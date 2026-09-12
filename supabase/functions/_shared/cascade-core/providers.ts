// cascade-core providers (D-070 phase 2, lifted unchanged from messenger-concierge on 2026-09-12).
// One call: Gemini first, OpenRouter only when Gemini fails and a key is set. Both return the raw
// model text; callers parse. Env: CASCADE_GEMINI_BOT_KEY (falls back to GEMINI_BOT_KEY),
// CASCADE_GEMINI_MODEL (default gemini-3.6-flash), CASCADE_OPENROUTER_BOT_KEY.
const env = (k: string) => Deno.env.get(k) ?? '';
const GEMINI_MODEL = env('CASCADE_GEMINI_MODEL') || 'gemini-3.6-flash';
const OPENROUTER_MODEL = 'google/gemini-2.5-flash';
const geminiKey = () => env('CASCADE_GEMINI_BOT_KEY') || env('GEMINI_BOT_KEY');

export type ChatTurn = { role: 'user' | 'assistant'; text: string };
export type ChatJsonRequest = {
  system: string;
  history: ChatTurn[];
  question: string;
  title?: string;          // X-Title for OpenRouter
  temperature?: number;    // default 0.4
  maxTokens?: number;      // default 700
  timeoutMs?: number;      // default 25_000
};

async function gemini(q: ChatJsonRequest): Promise<string> {
  const contents = [
    ...q.history.map((h) => ({ role: h.role === 'assistant' ? 'model' : 'user', parts: [{ text: h.text }] })),
    { role: 'user', parts: [{ text: q.question }] },
  ];
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${geminiKey()}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ system_instruction: { parts: [{ text: q.system }] }, contents, generationConfig: { temperature: q.temperature ?? 0.4, maxOutputTokens: q.maxTokens ?? 700, responseMimeType: 'application/json' } }),
    signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
  });
  if (!r.ok) throw new Error(`gemini_${r.status}: ${(await r.text()).slice(0, 300)}`);
  return (await r.json())?.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
}

async function openrouter(q: ChatJsonRequest): Promise<string> {
  const messages = [
    { role: 'system', content: q.system },
    ...q.history.map((h) => ({ role: h.role, content: h.text })),
    { role: 'user', content: q.question },
  ];
  const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env('CASCADE_OPENROUTER_BOT_KEY')}`, 'X-Title': q.title ?? 'Cascade' },
    body: JSON.stringify({ model: OPENROUTER_MODEL, messages, temperature: q.temperature ?? 0.4, max_tokens: q.maxTokens ?? 700, response_format: { type: 'json_object' } }),
    signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
  });
  if (!r.ok) throw new Error(`openrouter_${r.status}: ${(await r.text()).slice(0, 300)}`);
  return (await r.json())?.choices?.[0]?.message?.content ?? '';
}

/** JSON-mode chat with provider fallback. Returns the raw text; throws when both providers fail. */
export async function chatJson(q: ChatJsonRequest): Promise<string> {
  try {
    return await gemini(q);
  } catch (e) {
    if (!env('CASCADE_OPENROUTER_BOT_KEY')) throw e;
    console.error('gemini_failed_trying_openrouter', String(e).slice(0, 300));
    return await openrouter(q);
  }
}
