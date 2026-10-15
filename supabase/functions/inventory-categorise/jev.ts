// Small Jev (typesafe/jev-1.13) choice call, copied from messenger-concierge/jev.ts (D-271) rather than imported, so _shared stays untouched.
// ponytail: move to _shared if a third function needs it (editing _shared changes every importer's bundle and trips the drift check).
export type Pick = { category: string; confidence: number; ms: number };

/** One `choice` question. null on any failure (timeout, http error, no key, a choice that is not one of the criteria): fail-open. */
export async function jevCategorise(
  itemName: string, criteria: Record<string, string>, key: string | undefined, timeoutMs = 4000,
): Promise<{ pick: Pick | null; ok: boolean; ms: number; error?: string }> {
  const t0 = Date.now();
  if (!key) return { pick: null, ok: false, ms: 0, error: 'no_key' };
  try {
    const r = await fetch('https://openrouter.ai/api/alpha/decisions', {
      method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'X-Title': 'Cascade inventory categoriser' },
      body: JSON.stringify({
        model: 'typesafe/jev-1.13',
        state: { business: 'Cascade Hideaway, a one-unit holiday home', item_name: itemName },
        questions: { category: { type: 'choice', instructions: 'Which storage category fits this household item best?', criteria } },
      }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const a = r.ok ? (await r.json())?.answers?.category : null;
    const ms = Date.now() - t0;
    if (!a?.choice) return { pick: null, ok: false, ms, error: `http_${r.status}` };
    if (!Object.hasOwn(criteria, a.choice)) return { pick: null, ok: true, ms, error: 'unknown_choice' };
    return { pick: { category: a.choice, confidence: Number(a.confidence ?? 0), ms }, ok: true, ms };
  } catch (e) {
    return { pick: null, ok: false, ms: Date.now() - t0, error: String((e as Error)?.name ?? e).slice(0, 40) };
  }
}
