// cascade-core providers (D-070 phase 2, lifted unchanged from messenger-concierge on 2026-09-12).
// D-222 (Lloyd 2026-09-24): OpenRouter first, Gemini only when OpenRouter fails and Gemini's breaker is
// closed. Both return the raw model text; callers parse. Env: CASCADE_OPENROUTER_BOT_KEY,
// CASCADE_OPENROUTER_MODEL (default google/gemini-2.5-flash - it served every reply from ~09-13 to 09-24; 3.6-flash
// spends max_tokens on hidden reasoning and cut a live reply mid-word at 696/700 on 2026-09-24),
// CASCADE_GEMINI_BOT_KEY (the only Gemini key), CASCADE_GEMINI_MODEL (default gemini-3.6-flash).
const env = (k: string) => Deno.env.get(k) ?? '';
const GEMINI_MODEL = env('CASCADE_GEMINI_MODEL') || 'gemini-3.6-flash';
const OPENROUTER_MODEL = env('CASCADE_OPENROUTER_MODEL') || 'google/gemini-2.5-flash';
// Cost tier (2026-09-13): short follow-ups and option drafts do not need the full model. The lite
// tier goes straight to OpenRouter's flash-lite (a known, listed slug, ~1/3 the price), skipping
// the Gemini round trip entirely.
const OPENROUTER_LITE_MODEL = env('CASCADE_OPENROUTER_LITE_MODEL') || 'google/gemini-2.5-flash-lite';
// Deep tier (D-070 #5, Cassy deploy 4): explicit /deep goes straight to OpenRouter on a stronger model.
const OPENROUTER_DEEP_MODEL = env('CASCADE_OPENROUTER_DEEP_MODEL') || 'anthropic/claude-sonnet-5';
// 2026-09-13 (Lloyd): the bare GEMINI_BOT_KEY belongs to another project and was being drained
// through Cascade. CASCADE_GEMINI_BOT_KEY is the only Gemini key this project may use - no fallback.
const geminiKey = () => env('CASCADE_GEMINI_BOT_KEY');

export type ChatTurn = { role: 'user' | 'assistant'; text: string };
export type ChatJsonRequest = {
  system: string;
  history: ChatTurn[];
  question: string;
  title?: string;          // X-Title for OpenRouter
  temperature?: number;    // default 0.4
  maxTokens?: number;      // default 700
  timeoutMs?: number;      // default 25_000
  tier?: 'full' | 'lite';  // default full; lite = cheap model for follow-ups and option drafts
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
  const j = await r.json();
  const u = j?.usageMetadata; if (u) console.log('llm_usage', JSON.stringify({ provider: 'gemini', model: GEMINI_MODEL, title: q.title, tier: q.tier ?? 'full', input: u.promptTokenCount, output: u.candidatesTokenCount }));
  return j?.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
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
    body: JSON.stringify({ model: q.tier === 'lite' ? OPENROUTER_LITE_MODEL : OPENROUTER_MODEL, messages, temperature: q.temperature ?? 0.4, max_tokens: q.maxTokens ?? 700, response_format: { type: 'json_object' } }),
    signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
  });
  if (!r.ok) throw new Error(`openrouter_${r.status}: ${(await r.text()).slice(0, 300)}`);
  const j = await r.json();
  const u = j?.usage; if (u) console.log('llm_usage', JSON.stringify({ provider: 'openrouter', model: j?.model, title: q.title, tier: q.tier ?? 'full', input: u.prompt_tokens, output: u.completion_tokens, cost_usd: u.cost }));
  // A reply cut by max_tokens reads as a sentence that stops mid-word (live 2026-09-24): make it visible, and let the
  // caller fall back rather than send half a sentence.
  if (j?.choices?.[0]?.finish_reason === 'length') { console.warn('llm_truncated', JSON.stringify({ model: j?.model, title: q.title, output: u?.completion_tokens })); throw new Error('openrouter_truncated'); }
  return j?.choices?.[0]?.message?.content ?? '';
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
export async function chatJson(q: ChatJsonRequest): Promise<string> {
  const hasOr = Boolean(env('CASCADE_OPENROUTER_BOT_KEY'));
  if (hasOr) {
    try { return await openrouter(q); } catch (e) {
      if (!geminiOpen()) throw e;
      console.error('openrouter_failed_trying_gemini', String(e).slice(0, 300));
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
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${geminiKey()}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: q.system }] }, contents,
        tools: [{ functionDeclarations: q.tools }],
        tool_config: { function_calling_config: round === 0 && q.forceTool ? { mode: 'ANY', allowed_function_names: [q.forceTool] } : { mode: round < (q.maxRounds ?? 3) ? 'AUTO' : 'NONE' } },
        generationConfig: { temperature: q.temperature ?? 0.3, maxOutputTokens: q.maxTokens ?? 700 },
      }),
      signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
    });
    if (!r.ok) throw new Error(`gemini_${r.status}: ${(await r.text()).slice(0, 300)}`);
    const j = await r.json();
    const u = j?.usageMetadata; if (u) console.log('llm_usage', JSON.stringify({ provider: 'gemini', model: GEMINI_MODEL, title: q.title, tier: 'full', round, input: u.promptTokenCount, output: u.candidatesTokenCount }));
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
  let model = q.tier === 'deep' ? OPENROUTER_DEEP_MODEL : OPENROUTER_MODEL;
  for (let round = 0; ; round++) {
    const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env('CASCADE_OPENROUTER_BOT_KEY')}`, 'X-Title': q.title ?? 'Cascade' },
      body: JSON.stringify({ model: q.tier === 'deep' ? OPENROUTER_DEEP_MODEL : OPENROUTER_MODEL, messages, tools, tool_choice: round === 0 && q.forceTool ? { type: 'function', function: { name: q.forceTool } } : (round < (q.maxRounds ?? 3) ? 'auto' : 'none'), temperature: q.temperature ?? 0.3, max_tokens: q.maxTokens ?? 700 }),
      signal: AbortSignal.timeout(q.timeoutMs ?? 25_000),
    });
    if (!r.ok) throw new Error(`openrouter_${r.status}: ${(await r.text()).slice(0, 300)}`);
    const j = await r.json();
    model = j?.model ?? model;
    const u = j?.usage; if (u) console.log('llm_usage', JSON.stringify({ provider: 'openrouter', model, title: q.title, tier: q.tier ?? 'full', round, input: u.prompt_tokens, output: u.completion_tokens, cost_usd: u.cost }));
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
