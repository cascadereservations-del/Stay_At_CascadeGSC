// s82 lane R 3.1.1: where the server time goes. Real draftOptions + real telegram-cassy draft code against a stubbed network with
// realistic latencies (scaled by 1/SCALE so the suite stays fast). It counts model calls per path and prints simulated seconds.
// Latencies (typical, from the llm_usage rows): model call 3 s, concierge probe 7 s (its own model calls inside), Jev router 1 s,
// database read 0.15 s. The screenshot read (about 4 s per pass) is outside draftOptions and is added by hand in the report.
import { assert, assertEquals } from 'jsr:@std/assert@1';
Deno.env.set('CASCADE_OPENROUTER_BOT_KEY', 'or-test');
Deno.env.set('CASCADE_PROBE_SECRET', 'dummy-probe-secret-0123456789abcdef');
Deno.env.set('SUPABASE_URL', 'https://wiring.test');
const { draftOptions } = await import('./R_draft.ts');

const SCALE = 10, LAT = { model: 3000, probe: 7000, jev: 1000, db: 150 };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms / SCALE));
const SIGN = '\n\nMarifel & The Cascade Team\nHotel Comfort. Home Warmth.';
const LONG = 'Hi Ana! Yes po, check-in starts at 2:00 PM and check-out is at 11:00 AM. Early arrivals are welcome to leave their bags with us while the unit is made ready, and we will message you as soon as it is. The unit has air conditioning, a kitchen, fast wifi and a quiet street, and the host is only a message away if anything is needed during your stay.';
const MODEL_JSON = JSON.stringify({ reply: LONG, short: 'Hi Ana! Check-in starts at 2:00 PM. See you then.', details: 'Hi Ana! Yes po, check-in starts at 2:00 PM and check-out is at 11:00 AM. Bags can be left with us before the unit is ready. The house is a few minutes from the airport.' });

type Stat = { model: number; probe: number; jev: number; simSeconds: number };
async function run(access: 'full' | 'limited', platform: 'airbnb' | 'messenger'): Promise<Stat & { options: string[] }> {
  const s = { model: 0, probe: 0, jev: 0 };
  const db = {
    rpc: async (name: string) => { await sleep(LAT.db); return name === 'get_rate_card_v1' ? { data: null, error: { message: 'seed' } } : { data: { found: false }, error: null }; },
    from: () => ({ select: () => ({ in: async () => { await sleep(LAT.db); return { data: [] }; } }) }),
  };
  const real = globalThis.fetch;
  globalThis.fetch = (async (input: string | URL | Request) => {
    const u = String(input instanceof Request ? input.url : input);
    if (u.includes('messenger-concierge')) { s.probe++; await sleep(LAT.probe); return new Response(JSON.stringify({ ok: true, turns: [{ reply: LONG, risk: 'routine', step: null, effects: [] }] }), { status: 200 }); }
    if (u.includes('alpha/decisions')) { s.jev++; await sleep(LAT.jev); return new Response('{}', { status: 500 }); }
    if (u.includes('openrouter.ai/api/v1/chat')) { s.model++; await sleep(LAT.model); return new Response(JSON.stringify({ choices: [{ message: { content: MODEL_JSON } }] }), { status: 200 }); }
    return new Response('{}', { status: 200 });
  }) as typeof fetch;
  const t0 = performance.now();
  try {
    const out = await draftOptions(db, { guestText: 'Hi po, what time is check-in tomorrow?', guestName: 'Ana', thread: { platform }, access });
    const simSeconds = Math.round(((performance.now() - t0) * SCALE) / 100) / 10;
    console.log(JSON.stringify({ latency: `${access}/${platform}`, ...s, simSeconds }));
    return { ...s, simSeconds, options: out.options.map((o) => o.label) };
  } finally { globalThis.fetch = real; }
}

Deno.test('latency: full / messenger (concierge probe)', async () => {
  const r = await run('full', 'messenger');
  assert(r.options.length >= 2);
  assertEquals([r.model, r.probe, r.simSeconds < EXPECT.fullMessenger.maxSeconds], [EXPECT.fullMessenger.model, EXPECT.fullMessenger.probe, true]);
});
Deno.test('latency: full / airbnb (model draft)', async () => {
  const r = await run('full', 'airbnb');
  assert(r.options.length >= 2);
  assertEquals([r.model, r.simSeconds < EXPECT.fullAirbnb.maxSeconds], [EXPECT.fullAirbnb.model, true]);
});
Deno.test('latency: limited (cleaner)', async () => {
  const r = await run('limited', 'messenger');
  assert(r.options.length >= 2);
  assertEquals([r.model, r.probe, r.simSeconds < EXPECT.limited.maxSeconds], [EXPECT.limited.model, 0, true]);
});

// Before 3.1.1b: full/messenger 2 model + 1 probe, 15.5 s; full/airbnb 3 model + 1 Jev, 12.4 s; limited 1 model, 3.5 s (3.1.1).
// After: the short rewrite is skipped (skipShort) and the variants call runs alongside the Warm draft, so a full path takes about
// max(Warm, variants) instead of Warm + rewrite + variants.
const EXPECT = { fullMessenger: { model: 1, probe: 1, maxSeconds: 9.5 }, fullAirbnb: { model: 2, maxSeconds: 8 }, limited: { model: 1, maxSeconds: 5.5 } };
