// s82 lane R fix: the REAL limited wiring (modelDraft -> loadCard/loadContact -> chatJson) against a db that throws on anything but
// the house-fact reads, and a fetch stub. Env is set before the dynamic import because providers.ts reads its keys at load.
import { assert, assertEquals } from 'jsr:@std/assert@1';
Deno.env.set('CASCADE_OPENROUTER_BOT_KEY', 'or-test');
Deno.env.set('CASCADE_PROBE_SECRET', 'dummy-probe-secret-0123456789abcdef'); // so a concierge probe call WOULD be made and show up in urls
Deno.env.set('SUPABASE_URL', 'https://wiring.test');
const { draftOptions } = await import('./R_draft.ts');

Deno.test('limited path, real wiring: only get_rate_card_v1 and the app_settings contact are read; no guest context, no concierge probe', async () => {
  const reads: string[] = [], urls: string[] = [];
  const db = {
    rpc: (name: string) => { if (name !== 'get_rate_card_v1') { reads.push(`forbidden:rpc:${name}`); throw new Error(`forbidden rpc ${name}`); }; reads.push(`rpc:${name}`); return Promise.resolve({ data: null, error: { message: 'seed' } }); },
    from: (table: string) => {
      if (table !== 'app_settings') { reads.push(`forbidden:from:${table}`); throw new Error(`forbidden table ${table}`); }
      reads.push(`from:${table}`);
      return { select: () => ({ in: () => Promise.resolve({ data: [] }) }) };
    },
  };
  const real = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request) => {
    urls.push(String(input instanceof Request ? input.url : input));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: '{"reply":"Hi Ana! Yes po, check-in starts at 2:00 PM."}' } }] }), { status: 200 }));
  }) as typeof fetch;
  try {
    const out = await draftOptions(db, { guestText: 'Hi po, what time is check-in tomorrow?', guestName: 'Ana', thread: {}, access: 'limited' });
    assert(out.options.length >= 1);
    assert(!reads.some((r) => r.startsWith('forbidden:')), reads.join());
    assert(reads.every((r) => r === 'rpc:get_rate_card_v1' || r === 'from:app_settings'), reads.join());
    assert(!urls.some((u) => u.includes('messenger-concierge') || u.includes('/rest/v1/')), urls.join());
    assertEquals(urls.filter((u) => u.includes('openrouter')).length, 1); // the limited path is ONE structured call (Warm, Short, With details)
  } finally { globalThis.fetch = real; }
});

Deno.test('limited path: when Warm leaks and is regenerated, the Short / With details of the leaking batch are discarded', async () => {
  const LEAK = 'Hi Ana! Yes po, please send PHP 1,500 to our GCash.';
  const FIRST = JSON.stringify({ reply: LEAK, short: 'Hi Ana! FIRST-BATCH-SHORT check-in is at 2:00 PM. See you then.', details: null });
  const SECOND = JSON.stringify({ reply: 'Hi Ana! Yes po, check-in starts at 2:00 PM and we will confirm everything here on the listing.' });
  const bodies = [FIRST, SECOND];
  const db = { rpc: () => Promise.resolve({ data: null, error: { message: 'seed' } }), from: () => ({ select: () => ({ in: () => Promise.resolve({ data: [] }) }) }) };
  const real = globalThis.fetch;
  let n = 0;
  globalThis.fetch = (() => Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: bodies[Math.min(n++, 1)] } }] }), { status: 200 }))) as typeof fetch;
  try {
    const out = await draftOptions(db, { guestText: 'Hi po, what time is check-in?', guestName: 'Ana', thread: {}, access: 'limited' });
    assertEquals(n, 2);
    assertEquals(out.options.map((o) => o.label), ['Warm']);
    assert(!out.options.some((o) => o.text.includes('FIRST-BATCH')));
  } finally { globalThis.fetch = real; }
});
