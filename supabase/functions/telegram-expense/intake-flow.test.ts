// deno test --no-check --allow-env telegram-expense/intake-flow.test.ts
// /intake against recording fakes. Synthetic names only (public repo).
import { assert, assertEquals, assertFalse, assertMatch } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type Deps, guestLine, onIntakeTap, parseIntakeTap, startIntake, STAY_PAGE } from './intake-flow.ts';
import { hashGuestAccessToken } from '../_shared/guest-access-token.ts';

const FIN = -100500, OPS = -100600, B1 = 'e2000000-0000-4000-8000-0000000000b1';
const STAY = { id: B1, guest_id: 'g1', checkin_date: '2026-10-09', checkout_date: '2026-10-12' };

function fake(opts: { linked?: boolean; stays?: any[]; insertError?: boolean; staysError?: boolean } = {}) {
  const inserted: any[] = [], rpcs: any[] = [];
  const stays = opts.stays ?? [STAY];
  const q: any = {
    select: () => q, eq: () => q, not: () => q, gte: () => q, order: () => q, in: () => q,
    limit: () => Promise.resolve(opts.staysError ? { data: null, error: { message: 'x' } } : { data: stays, error: null }),
    then: (res: any) => Promise.resolve({ data: [{ id: 'g1', name: 'Nora Sample' }], error: null }).then(res),
  };
  const db = {
    from: (t: string) => t === 'guest_access_tokens' ? { insert: async (r: any) => { inserted.push(r); return { error: opts.insertError ? { message: 'x' } : null }; } } : q,
    rpc: async (fn: string, args: any) => { rpcs.push({ fn, args }); return { data: { ok: opts.linked !== false, guests: [] }, error: null }; },
  };
  const sent: any[] = [], edits: any[] = [], answers: any[] = [];
  const d: Deps = {
    db, propertyId: 'p1', isFinance: (c) => c === FIN,
    send: async (c, t, x) => { sent.push({ c, t, x }); return {}; },
    edit: async (c, m, t, rm) => { edits.push({ c, m, t, rm }); return {}; },
    answer: async (id, t) => { answers.push({ id, t }); return {}; },
    esc: (s) => s, today: () => '2026-10-08',
  };
  return { d, sent, edits, answers, inserted, rpcs };
}
const msg = (chat: number) => ({ chat: { id: chat }, from: { id: 906700001 } });
const tap = (chat: number, data = `int:${B1}`) => ({ id: 'cb', data, from: { id: 906700001 }, message: { chat: { id: chat }, message_id: 9 } });

Deno.test('/intake in OPS: refused, nothing read or made', async () => {
  const f = fake(); await startIntake(f.d, msg(OPS));
  assertEquals(f.rpcs.length, 0); assertEquals(f.sent.length, 1); assert(f.sent[0].t.includes('Finance group'));
});

Deno.test('/intake from an unlinked Telegram: refused', async () => {
  const f = fake({ linked: false }); await startIntake(f.d, msg(FIN));
  assert(f.sent[0].t.includes('not linked')); assertFalse('reply_markup' in (f.sent[0].x ?? {}));
});

Deno.test('/intake in Finance: one button per stay, no token yet', async () => {
  const f = fake(); await startIntake(f.d, msg(FIN));
  const kb = f.sent[0].x.reply_markup.inline_keyboard;
  assertEquals(kb.length, 1); assertEquals(kb[0][0].callback_data, `int:${B1}`); assert(kb[0][0].text.includes('Nora Sample'));
  assertEquals(f.inserted.length, 0);
});

Deno.test('/intake with no open stay says so', async () => {
  const f = fake({ stays: [] }); await startIntake(f.d, msg(FIN));
  assert(f.sent[0].t.includes('nothing to send')); assertFalse('x' in f.sent[0] && f.sent[0].x?.reply_markup);
});

Deno.test('tap: mints a hashed direct token, card holds no token, link goes in one separate message', async () => {
  const f = fake(); await onIntakeTap(f.d, tap(FIN));
  assertEquals(f.inserted.length, 1);
  const row = f.inserted[0];
  assertEquals([row.booking_type, row.booking_id, row.property_id], ['direct', B1, 'p1']);
  assertEquals(row.expires_at, '2026-10-18T16:00:00.000Z'); // Manila midnight of 10-12 plus 7 days
  const link = f.sent[0].t.match(/stay\.html#t=([A-Za-z0-9_-]{43})/);
  assert(link, 'link with a 43-char token');
  assertEquals(row.token_hash, await hashGuestAccessToken(link![1]));
  assert(f.sent[0].t.startsWith(`\`Hello Nora`));
  assertFalse(f.edits[0].t.includes(link![1]));
  assertEquals(f.sent[0].c, FIN); // the same Finance chat, never OPS
  assertFalse(f.sent[0].t.includes('!'));
});

Deno.test('tap in OPS, by an unlinked user, with a bad id or a closed stay: nothing minted', async () => {
  for (const [f, c, data] of [
    [fake(), OPS, `int:${B1}`], [fake({ linked: false }), FIN, `int:${B1}`], [fake(), FIN, 'int:nope'],
    [fake({ stays: [] }), FIN, `int:${B1}`], [fake({ staysError: true }), FIN, `int:${B1}`],
  ] as const) {
    await onIntakeTap(f.d, tap(c, data));
    assertEquals(f.inserted.length, 0); assertEquals(f.sent.length, 0); assert(f.answers[0].t);
  }
});

Deno.test('token insert failure: no link sent', async () => {
  const f = fake({ insertError: true }); await onIntakeTap(f.d, tap(FIN));
  assertEquals(f.sent.length, 0); assert(f.answers[0].t.includes('Nothing was made'));
});

Deno.test('parseIntakeTap and guestLine', () => {
  assertEquals(parseIntakeTap(`int:${B1}`), B1); assertEquals(parseIntakeTap('int:x'), null); assertEquals(parseIntakeTap('gst:pick'), null);
  assertMatch(guestLine('Nora', '2026-10-09', STAY_PAGE + 'T'), /^Hello Nora, before you arrive on 2026-10-09/);
});
