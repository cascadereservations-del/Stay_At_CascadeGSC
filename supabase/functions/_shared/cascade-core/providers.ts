// cascade-core providers (D-070 phase 2, lifted unchanged from messenger-concierge on 2026-09-12).
// D-222 (Lloyd 2026-09-24): OpenRouter first, Gemini only when OpenRouter fails and Gemini's breaker is
// closed. Both return the raw model text; callers parse. Env: CASCADE_OPENROUTER_BOT_KEY,
// CASCADE_OPENROUTER_MODEL (default google/gemini-3.6-flash; 2.5-flash served ~09-13..10-06 and OpenRouter retires it
// 2026-10-20, SPEC-43). Gemini 3 calls send reasoning effort minimal + max_tokens headroom because hidden reasoning
// cut a live reply at 696/700 on 2026-09-24,
// CASCADE_GEMINI_BOT_KEY (the only Gemini key), CASCADE_GEMINI_MODEL (default gemini-3.6-flash).
import { recordUsage } from './usage.ts';
const env = (k: string) => Deno.env.get(k) ?? '';
const GEMINI_MODEL = env('CASCADE_GEMINI_MODEL') || 'gemini-3.6-flash';
const OPENROUTER_MODEL = env('CASCADE_OPENROUTER_MODEL') || 'google/gemini-3.6-flash';
// Cost tier (2026-09-13): short follow-ups and option drafts do not need the full model. The lite
// tier goes straight to OpenRouter's flash-lite (a known, listed slug, ~1/3 the price), skipping
// the Gemini round trip entirely.
const OPENROUTER_LITE_MODEL = env('CASCADE_OPENROUTER_LITE_MODEL') || 'google/gemini-3.1-flash-lite';
// Deep tier (D-070 #5, Cassy deploy 4): explicit /deep goes straight to OpenRouter on a stronger model.
const OPENROUTER_DEEP_MODEL = env('CASCADE_OPENROUTER_DEEP_MODEL') || 'anthropic/claude-sonnet-5';
// Session 58: a second upstream (OpenAI, ~1/3 of Flash's price) that OpenRouter tries when the first model fails.
const OPENROUTER_FALLBACK_MODEL = env('CASCADE_OPENROUTER_FALLBACK_MODEL') || 'openai/gpt-6-luna';
// 2026-09-13 (Lloyd): the bare GEMINI_BOT_KEY belongs to another project and was being drained
// through Cascade. CASCADE_GEMINI_BOT_KEY is the only Gemini key this project may use - no fallback.
const geminiKey = () => env('CASCADE_GEMINI_BOT_KEY');
// SPEC-43: Gemini 3 reasons before it answers and OpenRouter counts that against max_tokens; "minimal" is its lowest setting.
const gemini3 = (m: string) => m.startsWith('google/gemini-3');
const REASONING_HEADROOM = 300;
const MINIMAL = { reasoning: { effort: 'minimal' } };

export type ChatTurn = { role: 'user' | 'assistant'; text: string };
export type ChatJsonRequest = {
  system: string;
  history: ChatTurn[];
  question: string;
  title?: string;          // X-Title for OpenRouter
  temperature?: number;    // default 0.4
  maxTokens?: number;      // default 700
  timeoutMs?: number;      // default 25_000
  tier?: 'full' | 'lite' | 'routine';  // default full; lite = cheap model for follow-ups and option drafts; routine = free first (below)
  plain?: boolean;         // SPEC-32 s5: no JSON mode - the last try after two unreadable JSON replies
};
// SPEC-32 s4 (D-254): probe and golden runs spend CASCADE_OPENROUTER_PROBE_KEY, never the guests' key. Set by runProbe for
// its own request and reset in finally.
// ponytail: module-level; a guest turn landing on the same warm worker mid-probe would bill the probe key - harmless.
let keyOverride: string | null = null;
export function setProviderKey(key: string | null): void { keyOverride = key || null; }
const orKey = () => keyOverride ?? env('CASCADE_OPENROUTER_BOT_KEY');
// D-294: a row written while keyOverride is set is a probe or golden run, so the governor can leave it out of guest demand.
// ponytail: the same module-level ceiling - that rare mid-probe guest turn is also tagged probe (audit 2026-10-04); scope the
// override per request (AsyncLocalStorage) if probes ever overlap real guest traffic often enough to skew the governor.
const probing = () => keyOverride !== null;
// A thrown fetch (timeout, network) is a failed attempt too: record it with the error's name, then rethrow unchanged.
const fetchFailed = (e: unknown, u: Parameters<typeof recordUsage>[0]): never => { recordUsage({ ...u, ok: false, error: `${u.provider}_${(e as Error)?.name ?? 'fetch_error'}`, probe: probing() }); throw e; };

async function gemini(q: ChatJsonRequest): Promise<string> {
  const row = { provider: 'gemini' as const, model: GEMINI_MODEL, title: q.title, tier: q.tier ?? 'full' };
  const contents = [
    ...q.history.map((h) => ({ role: h.role === 'assistant' ? 'model' : 'user', parts: [{ text: h.text }] })),
    { role: 'user', parts: [{ text: q.question }] },
  ];
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${geminiKey()}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ system_instruction: { parts: [{ text: q.system }] }, contents, generationConfig: { temperature: q.temperature ?? 0.4, maxOutputTokens: q.maxTokens ?? 700, ...(q.plain ? {} : { responseMimeType: 'application/json' }) } }),
    signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
  }).catch((e) => fetchFailed(e, row));
  if (!r.ok) { recordUsage({ ...row, ok: false, error: `gemini_${r.status}`, probe: probing() }); throw new Error(`gemini_${r.status}: ${(await r.text()).slice(0, 300)}`); }
  const j = await r.json();
  const u = j?.usageMetadata; recordUsage({ ...row, input: u?.promptTokenCount, output: u?.candidatesTokenCount, probe: probing() });
  return j?.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
}

/** An OpenAI-compatible chat call: OpenRouter (either Cascade key) or Cascade's own OmniRoute gateway. */
async function openaiChat(q: ChatJsonRequest, p: { name: 'openrouter' | 'omniroute'; url: string; key: string; model: Record<string, unknown> }): Promise<string> {
  const row = { provider: p.name, model: String(p.model.model ?? (p.model.models as string[] | undefined)?.[0] ?? ''), title: q.title, tier: q.tier ?? 'full' };
  const messages = [
    { role: 'system', content: q.system },
    ...q.history.map((h) => ({ role: h.role, content: h.text })),
    { role: 'user', content: q.question },
  ];
  const r = await fetch(`${p.url}/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${p.key}`, 'X-Title': q.title ?? 'Cascade' },
    body: JSON.stringify({ ...p.model, messages, temperature: q.temperature ?? 0.4, max_tokens: q.maxTokens ?? 700, ...(q.plain ? {} : { response_format: { type: 'json_object' } }) }),
    signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
  }).catch((e) => fetchFailed(e, row));
  if (!r.ok) { recordUsage({ ...row, ok: false, error: `${p.name}_${r.status}`, probe: probing() }); throw new Error(`${p.name}_${r.status}: ${(await r.text()).slice(0, 300)}`); }
  const j = await r.json();
  const u = j?.usage;
  // A reply cut by max_tokens reads as a sentence that stops mid-word (live 2026-09-24): make it visible, and let the
  // caller fall back rather than send half a sentence. The provider DID answer, so the row is ok:true and names the cut in
  // `error` (tokens and cost kept): a truncation is our max_tokens, not an outage, and must not count toward V15 (D-294).
  const cut = j?.choices?.[0]?.finish_reason === 'length';
  recordUsage({ ...row, model: j?.model ?? row.model, input: u?.prompt_tokens, output: u?.completion_tokens, cost_usd: u?.cost, ...(cut ? { error: `${p.name}_truncated` } : {}), probe: probing() });
  if (cut) { console.warn('llm_truncated', JSON.stringify({ model: j?.model, title: q.title, output: u?.completion_tokens, reasoning: u?.completion_tokens_details?.reasoning_tokens })); throw new Error(`${p.name}_truncated`); }
  return j?.choices?.[0]?.message?.content ?? '';
}
// Session 58: OpenRouter's own fallback list - a Google outage on the primary no longer leaves the guest without a
// reply while Gemini direct has no credit (402). Tested live: the list is accepted and the fallback returns JSON.
function openrouter(q: ChatJsonRequest, key: string): Promise<string> {
  const primary = q.tier === 'lite' || q.tier === 'routine' ? OPENROUTER_LITE_MODEL : OPENROUTER_MODEL, g3 = gemini3(primary);
  return openaiChat(g3 ? { ...q, maxTokens: (q.maxTokens ?? 700) + REASONING_HEADROOM } : q,
    { name: 'openrouter', url: 'https://openrouter.ai/api/v1', key, model: { models: [primary, OPENROUTER_FALLBACK_MODEL], ...(g3 ? MINIMAL : {}) } });
}
/** 2026-09-30 (Lloyd, the Gemini prepay empty): the rungs after the guests' OpenRouter key - a second Cascade OpenRouter key
 *  with its own cap (CASCADE_OPENROUTER_BACKUP_KEY), then Cascade's own OmniRoute gateway (CASCADE_OMNIROUTE_URL,
 *  CASCADE_OMNIROUTE_KEY, CASCADE_OMNIROUTE_MODEL = its combo; never Alfred's). A rung whose secret is unset is skipped, and
 *  a probe or golden run (keyOverride) spends neither. */
function backupRungs(q: ChatJsonRequest): Array<{ name: string; run: () => Promise<string> }> {
  if (keyOverride) return [];
  const out: Array<{ name: string; run: () => Promise<string> }> = [];
  const backup = env('CASCADE_OPENROUTER_BACKUP_KEY');
  if (backup) out.push({ name: 'openrouter_backup', run: () => openrouter(q, backup) });
  const url = env('CASCADE_OMNIROUTE_URL').replace(/\/+$/, ''), key = env('CASCADE_OMNIROUTE_KEY');
  if (url && key) out.push({ name: 'omniroute', run: () => openaiChat(q, { name: 'omniroute', url, key, model: { model: env('CASCADE_OMNIROUTE_MODEL') || 'cascade-guest' } }) });
  return out;
}

/** JSON-mode chat with provider fallback. Returns the raw text; throws when both providers fail. */
// Circuit breaker (2026-09-13, widened D-222): a Gemini call that fails for want of credit or quota is
// skipped until it can succeed - 402 (prepay empty) and 401/403 (key refused) for 6 h, 429 for 15 min.
// Before D-222 only 429 tripped it, so an empty prepay (402, from ~2026-09-21) cost every call a doomed
// round trip. In-memory alone did not hold (each request can land on a cold isolate - live v55), so the
// caller seeds `until` from app_settings and persists it through `trip`.
export const geminiBreaker: { until: number; trip?: (until: number) => Promise<void> } = { until: 0 };
const geminiOpen = () => Boolean(geminiKey()) && Date.now() >= geminiBreaker.until;
async function tripOn(e: unknown): Promise<void> {
  const m = /gemini_(\d{3})/.exec(String(e));
  const ms = !m ? 0 : ['402', '401', '403'].includes(m[1]) ? 6 * 3600_000 : m[1] === '429' ? 15 * 60_000 : 0;
  if (!ms) return;
  geminiBreaker.until = Date.now() + ms;
  console.error('gemini_breaker_open', JSON.stringify({ status: m![1], until: new Date(geminiBreaker.until).toISOString() }));
  await geminiBreaker.trip?.(geminiBreaker.until).catch((err) => console.error('gemini_breaker_persist_failed', String(err).slice(0, 200)));
}
/** Session 68 (Lloyd 2026-10-03 "build 1-3"; D-224): short work with no guest data tries Cascade OmniRoute's free combo first
 *  (cascade-routine: Groq gpt-oss-120b -> gpt-oss-20b -> Cloudflare Llama 3.3 70B, none of them train on inputs). Any failure
 *  falls through to the paid chain on the lite model, and never becomes the error a host card names. Never pass tier 'routine'
 *  with guest names, messages or photos. Probes and golden runs skip it. */
async function routineFirst(q: ChatJsonRequest): Promise<string | null> {
  if (q.tier !== 'routine' || keyOverride) return null;
  const url = env('CASCADE_OMNIROUTE_URL').replace(/\/+$/, ''), key = env('CASCADE_OMNIROUTE_KEY');
  if (!url || !key) return null;
  try {
    // gpt-oss reasons before it answers and its reasoning counts against max_tokens: give the free try room (a ping asks for 20).
    // Groq refuses json_object unless the word "json" is in the messages (live 2026-10-03 02:21Z: /ping fell to Cloudflare).
    const system = q.plain || /json/i.test(`${q.system} ${q.question}`) ? q.system : `${q.system}\nReply in JSON.`;
    const out = await openaiChat({ ...q, system, maxTokens: Math.max(q.maxTokens ?? 700, 1200) }, { name: 'omniroute', url, key, model: { model: env('CASCADE_OMNIROUTE_ROUTINE_MODEL') || 'cascade-routine' } });
    const unusable = !out.trim() ? 'omniroute_routine_empty'
      : !q.plain && (() => { try { JSON.parse(out.replace(/^```(?:json)?\s*|\s*```$/g, '').trim()); return false; } catch { return true; } })() ? 'omniroute_routine_unreadable' : '';
    // D-294: openaiChat logged the call ok; a reply we throw away is the free provider failing, so the governor sees it as one.
    if (unusable) { recordUsage({ provider: 'omniroute', title: q.title, tier: 'routine', ok: false, error: unusable }); throw new Error(unusable); }
    return out;
  }
  catch (e) { console.error('omniroute_routine_failed_trying_paid', String(e).slice(0, 300)); return null; }
}
export async function chatJson(q: ChatJsonRequest): Promise<string> {
  const free = await routineFirst(q);
  if (free) return free;
  const rungs = [...(orKey() ? [{ name: 'openrouter', run: () => openrouter(q, orKey()) }] : []), ...backupRungs(q)];
  let first: unknown = null;
  for (const [i, r] of rungs.entries()) {
    try { return await r.run(); } catch (e) {
      first ??= e;
      if (i === rungs.length - 1 && !geminiOpen()) throw first; // the guests' key error is the one the host card names (D-227)
      console.error(`${r.name}_failed_trying_next`, String(e).slice(0, 300));
    }
  }
  try { return await gemini(q); } catch (e) { await tripOn(e); throw e; }
}

// ── Tool-calling chat (Cassy, 2026-09-13, D-104) ────────────────────────────────────────────────
// Same providers, same breaker, same llm_usage line, but the model may call tools from `q.tools`
// (executed through `q.run`) for up to `maxRounds` rounds before its final text. No JSON mode:
// Gemini refuses responseMimeType together with function declarations, so callers parse leniently.
export type ToolDecl = { name: string; description: string; parameters: Record<string, unknown> };
export type ChatToolsRequest = {
  system: string;
  history: ChatTurn[];
  question: string;
  tools: ToolDecl[];
  run: (name: string, args: Record<string, unknown>) => Promise<unknown>;
  title?: string;
  temperature?: number;    // default 0.3
  maxTokens?: number;      // default 700
  timeoutMs?: number;      // default 25_000
  maxRounds?: number;      // default 3 tool rounds
  forceTool?: string;      // code-decided: this tool MUST be called on round 0 (D-097: prompts alone fail)
  tier?: 'full' | 'deep';  // deep = OpenRouter deep model only, no Gemini attempt
};
export type ChatToolsResult = { text: string; provider: 'gemini' | 'openrouter'; model: string; toolCalls: string[] };

const toolResultText = (v: unknown) => { const s = typeof v === 'string' ? v : JSON.stringify(v ?? null); return s.length > 6000 ? s.slice(0, 6000) + '…' : s; };

async function geminiTools(q: ChatToolsRequest): Promise<ChatToolsResult> {
  const contents: any[] = [
    ...q.history.map((h) => ({ role: h.role === 'assistant' ? 'model' : 'user', parts: [{ text: h.text }] })),
    { role: 'user', parts: [{ text: q.question }] },
  ];
  const toolCalls: string[] = [];
  for (let round = 0; ; round++) {
    const row = { provider: 'gemini' as const, model: GEMINI_MODEL, title: q.title, tier: 'full', round };
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${geminiKey()}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: q.system }] }, contents,
        tools: [{ functionDeclarations: q.tools }],
        tool_config: { function_calling_config: round === 0 && q.forceTool ? { mode: 'ANY', allowed_function_names: [q.forceTool] } : { mode: round < (q.maxRounds ?? 3) ? 'AUTO' : 'NONE' } },
        generationConfig: { temperature: q.temperature ?? 0.3, maxOutputTokens: q.maxTokens ?? 700 },
      }),
      signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
    }).catch((e) => fetchFailed(e, row));
    if (!r.ok) { recordUsage({ ...row, ok: false, error: `gemini_${r.status}`, probe: probing() }); throw new Error(`gemini_${r.status}: ${(await r.text()).slice(0, 300)}`); }
    const j = await r.json();
    const u = j?.usageMetadata; recordUsage({ ...row, input: u?.promptTokenCount, output: u?.candidatesTokenCount, probe: probing() });
    const parts: any[] = j?.candidates?.[0]?.content?.parts ?? [];
    const calls = parts.filter((p) => p.functionCall);
    if (!calls.length) return { text: parts.map((p) => p.text ?? '').join('').trim(), provider: 'gemini', model: GEMINI_MODEL, toolCalls };
    contents.push({ role: 'model', parts: calls });
    const responses = [];
    for (const c of calls) {
      toolCalls.push(c.functionCall.name);
      const result = await q.run(c.functionCall.name, c.functionCall.args ?? {}).catch((e) => ({ error: String(e).slice(0, 300) }));
      responses.push({ functionResponse: { name: c.functionCall.name, response: { result: toolResultText(result) } } });
    }
    contents.push({ role: 'user', parts: responses });
  }
}

async function openrouterTools(q: ChatToolsRequest): Promise<ChatToolsResult> {
  const messages: any[] = [
    { role: 'system', content: q.system },
    ...q.history.map((h) => ({ role: h.role, content: h.text })),
    { role: 'user', content: q.question },
  ];
  const tools = q.tools.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.parameters } }));
  const toolCalls: string[] = [];
  const chosen = q.tier === 'deep' ? OPENROUTER_DEEP_MODEL : OPENROUTER_MODEL, g3 = gemini3(chosen);
  let model = chosen;
  for (let round = 0; ; round++) {
    const row = { provider: 'openrouter' as const, model, title: q.title, tier: q.tier ?? 'full', round };
    const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env('CASCADE_OPENROUTER_BOT_KEY')}`, 'X-Title': q.title ?? 'Cascade' },
      body: JSON.stringify({ model: chosen, ...(g3 ? MINIMAL : {}), messages, tools, tool_choice: round === 0 && q.forceTool ? { type: 'function', function: { name: q.forceTool } } : (round < (q.maxRounds ?? 3) ? 'auto' : 'none'), temperature: q.temperature ?? 0.3, max_tokens: (q.maxTokens ?? 700) + (g3 ? REASONING_HEADROOM : 0) }),
      signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
    }).catch((e) => fetchFailed(e, row));
    if (!r.ok) { recordUsage({ ...row, ok: false, error: `openrouter_${r.status}`, probe: probing() }); throw new Error(`openrouter_${r.status}: ${(await r.text()).slice(0, 300)}`); }
    const j = await r.json();
    model = j?.model ?? model;
    const u = j?.usage; recordUsage({ ...row, model, input: u?.prompt_tokens, output: u?.completion_tokens, cost_usd: u?.cost, probe: probing() });
    const msg = j?.choices?.[0]?.message ?? {};
    const calls: any[] = msg.tool_calls ?? [];
    if (!calls.length) return { text: String(msg.content ?? '').trim(), provider: 'openrouter', model, toolCalls };
    messages.push({ role: 'assistant', content: msg.content ?? null, tool_calls: calls });
    for (const c of calls) {
      let args: Record<string, unknown> = {};
      try { args = JSON.parse(c.function?.arguments || '{}'); } catch { /* model sent malformed args; run with none */ }
      toolCalls.push(c.function?.name);
      const result = await q.run(c.function?.name, args).catch((e) => ({ error: String(e).slice(0, 300) }));
      messages.push({ role: 'tool', tool_call_id: c.id, content: toolResultText(result) });
    }
  }
}

/** Tool-calling chat with the same OpenRouter-then-Gemini order and breaker as chatJson (D-222). */
export async function chatTools(q: ChatToolsRequest): Promise<ChatToolsResult> {
  const hasOr = Boolean(env('CASCADE_OPENROUTER_BOT_KEY'));
  if (q.tier === 'deep' && hasOr) return await openrouterTools(q);
  if (hasOr) {
    try { return await openrouterTools(q); } catch (e) {
      if (!geminiOpen()) throw e;
      console.error('openrouter_tools_failed_trying_gemini', String(e).slice(0, 300));
    }
  }
  try { return await geminiTools(q); } catch (e) { await tripOn(e); throw e; }
}
