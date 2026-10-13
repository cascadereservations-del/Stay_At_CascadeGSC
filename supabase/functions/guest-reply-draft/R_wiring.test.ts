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
    assertEquals(urls.filter((u) => u.includes('openrouter')).length, 2); // draft + options, nothing else
  } finally { globalThis.fetch = real; }
});
