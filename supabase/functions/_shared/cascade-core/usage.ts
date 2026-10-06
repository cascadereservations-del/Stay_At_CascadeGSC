// D-294 (Lloyd, session 69): every model call, paid or free, ok or failed, is one public.llm_usage row so the governor in
// system-verifier reads real demand instead of a guess. The console line stays exactly what the call sites printed before
// (provider, model, title, tier, round?, input, output, cost_usd), so existing log queries keep working; a failed call prints
// llm_call_failed instead. S74: `cached` (prompt tokens read from the provider's cache) rides on the console line only; there is no column. The insert is fire-and-forget: it never throws and never delays the model reply.
export type Usage = {
  title?: string; provider: 'openrouter' | 'gemini' | 'omniroute'; model?: string | null; tier?: string; round?: number;
  input?: number | null; output?: number | null; cached?: number | null; cost_usd?: number | null; ok?: boolean; error?: string | null; probe?: boolean;
};
// Unknown is null, never 0: a missing token count must not read as a free call.
const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

export function recordUsage(u: Usage): void {
  try {
    const ok = u.ok !== false;
    const line = { provider: u.provider, model: u.model, title: u.title, tier: u.tier, round: u.round, input: u.input, output: u.output, cached: u.cached, cost_usd: u.cost_usd };
    if (ok) console.log('llm_usage', JSON.stringify(u.error ? { ...line, error: String(u.error).slice(0, 200) } : line));
    else console.warn('llm_call_failed', JSON.stringify({ ...line, error: String(u.error ?? '').slice(0, 200) }));
    const url = Deno.env.get('SUPABASE_URL'), key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) return;
    const row = { title: u.title ?? 'Cascade', provider: u.provider, model: u.model ?? null, tier: u.tier ?? null,
      input: num(u.input), output: num(u.output), cost_usd: num(u.cost_usd), ok,
      // An ok row may still name what happened (a truncated reply: the provider answered, we cut it at max_tokens).
      error: u.error ? String(u.error).slice(0, 200) : ok ? null : 'error', probe: u.probe === true };
    const p = fetch(`${url.replace(/\/+$/, '')}/rest/v1/llm_usage`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify(row), signal: AbortSignal.timeout(3000),
    }).then(() => undefined, () => undefined);
    // deno-lint-ignore no-explicit-any
    const rt = (globalThis as any).EdgeRuntime;
    if (rt?.waitUntil) rt.waitUntil(p);
  } catch { /* usage logging must never break a model call */ }
}
