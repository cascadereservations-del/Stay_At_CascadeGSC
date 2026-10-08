// deno test --no-check --allow-env telegram-expense/intake-flow.test.ts
// /intake against recording fakes. Synthetic names only (public repo).
import { assert, assertEquals, assertFalse, assertMatch } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type Deps, guestLine, onIntakeTap, parseIntakeTap, startIntake, STAY_PAGE } from './intake-flow.ts';
import { hashGuestAccessToken } from '../_shared/guest-access-token.ts';

const FIN = -100500, OPS = -100600, B1 = 'e2000000-0000-4000-8000-0000000000b1';
const STAY = { id: B1, guest_id: 'g1', checkin_date: '2026-10-09', checkout_date: '2026-10-12' };
const A1 = 'e2000000-0000-4000-8000-0000000000a1';
const ABNB = { id: A1, guest_id: 'g2', checkin_date: '2026-10-08', checkout_date: '2026-10-10' };

function fake(opts: { linked?: boolean; stays?: any[]; airbnb?: any[]; insertError?: boolean; staysError?: boolean } = {}) {
  const inserted: any[] = [], rpcs: any[] = [], filters: Record<string, string[]> = {};
  const rows: Record<string, any[]> = { booking_inquiries: opts.stays ?? [STAY], airbnb_reservations: opts.airbnb ?? [] };
  const query = (t: string) => {
    const f: string[] = (filters[t] ??= []);
    const q: any = {};
    for (const op of ['select', 'eq', 'not', 'gte', 'order', 'in', 'is']) q[op] = (...a: unknown[]) => { f.push(`${op}:${a.map(String).join(',')}`); return q; };
    q.limit = () => Promise.resolve(opts.staysError ? { data: null, error: { message: 'x' } } : { data: rows[t] ?? [], error: null });
    q.then = (res: any) => Promise.resolve({ data: [{ id: 'g1', name: 'Nora Sample' }, { id: 'g2', name: 'Ada Synth' }], error: null }).then(res);
    return q;
  };
  const db = {
    from: (t: string) => t === 'guest_access_tokens' ? { insert: async (r: any) => { inserted.push(r); return { error: opts.insertError ? { message: 'x' } : null }; } } : query(t),
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
  return { d, sent, edits, answers, inserted, rpcs, filters };
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
  assertEquals(kb.length, 1); assertEquals(kb[0][0].callback_data, `int:${B1}`); assert(kb[0][0].text.includes('Nora Sample') && kb[0][0].text.includes('Oct 9 to Oct 12'));
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
  assert(f.sent[0].t.startsWith('Hello Nora') && f.sent[0].t.includes('on Oct 9'));assertFalse(f.sent[0].t.includes('`'));
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
  assertEquals(parseIntakeTap(`int:${B1}`), { id: B1, kind: 'direct' }); assertEquals(parseIntakeTap(`int:a:${A1}`), { id: A1, kind: 'airbnb' });
  assertEquals(parseIntakeTap('int:x'), null); assertEquals(parseIntakeTap('int:a:x'), null); assertEquals(parseIntakeTap('gst:pick'), null);
  assertMatch(guestLine('Nora', '2026-10-09', STAY_PAGE + 'T'), /^Hello Nora, before you arrive on 2026-10-09/);
});

Deno.test('D-323 /intake lists confirmed Airbnb stays too, labelled Airbnb, nearest first, with the resolver filters', async () => {
  const f = fake({ airbnb: [ABNB] }); await startIntake(f.d, msg(FIN));
  const kb = f.sent[0].x.reply_markup.inline_keyboard;
  assertEquals(kb.map((r: any) => r[0].callback_data), [`int:a:${A1}`, `int:${B1}`]);
  assert(kb[0][0].text.includes('Ada Synth') && kb[0][0].text.includes('· Airbnb') && kb[0][0].text.includes('in house'));
  assertFalse(kb[1][0].text.includes('Airbnb'));
  const a = f.filters.airbnb_reservations.join(' ');
  for (const want of ['eq:property_id,p1', 'eq:source,airbnb', 'is:cancelled_at,null', 'eq:status,confirmed', 'not:guest_id,is,null', 'gte:checkout_date,2026-10-08']) assert(a.includes(want), want);
  assertEquals(f.inserted.length, 0);
});

Deno.test('D-323 Airbnb tap: mints an airbnb token, reads only the Airbnb table, the card reminds the host the link is theirs to share', async () => {
  const f = fake({ airbnb: [ABNB] }); await onIntakeTap(f.d, tap(FIN, `int:a:${A1}`));
  assertEquals(f.inserted.length, 1);
  assertEquals([f.inserted[0].booking_type, f.inserted[0].booking_id, f.inserted[0].property_id], ['airbnb', A1, 'p1']);
  assertEquals(f.filters.booking_inquiries, undefined);
  assert(f.filters.airbnb_reservations.includes(`eq:id,${A1}`));
  const link = f.sent[0].t.match(/stay\.html#t=([A-Za-z0-9_-]{43})/);
  assertEquals(f.inserted[0].token_hash, await hashGuestAccessToken(link![1]));
  assert(f.sent[0].t.startsWith('Hello Ada'));
  assert(f.edits[0].t.includes('yours to share with the guest when you choose'));
  assertFalse(f.edits[0].t.includes(link![1])); assertFalse(f.edits[0].t.includes('!'));
  assertFalse(f.sent[0].t.includes('Airbnb')); // the host note is in the card only, never in the line that goes to the guest
});

Deno.test('a direct tap never reads the Airbnb table and its card carries no host note', async () => {
  const f = fake({ airbnb: [ABNB] }); await onIntakeTap(f.d, tap(FIN));
  assertEquals(f.inserted[0].booking_type, 'direct');
  assertEquals(f.filters.airbnb_reservations, undefined);
  assertFalse(f.edits[0].t.includes('yours to share'));
});
