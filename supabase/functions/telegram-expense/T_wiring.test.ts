// deno test --allow-read telegram-expense/T_wiring.test.ts - s84 lane T fix round: the webhook wiring of the notice block (awaited answers, claims, failed forwards).
import { assert, assertEquals, assertFalse } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { T_handle, T_handleExact, type T_Deps } from './T_nearmatch.ts';

const NOW = Date.parse('2026-10-14T01:00:00Z'); // 09:00 Manila
const OPS = -1003798341977;
const msg = (text: string, id = 77, extra: Record<string, unknown> = {}) => ({ message_id: id, date: NOW / 1000, chat: { id: OPS }, from: { id: 1, is_bot: false }, text, ...extra });
const upd = (text: string, id = 77) => ({ update_id: 5, message: msg(text, id) });
const edit = (text: string, id = 77) => ({ update_id: 6, edited_message: { ...msg(text, id), edit_date: NOW / 1000 + 60 } });

function rig(opts: { awaiting?: boolean; forwardOk?: boolean } = {}) {
  const keys = new Set<number>();
  const calls = { upserts: 0, deletes: [] as number[], forwards: [] as any[], replies: [] as string[], logs: [] as string[] };
  const db = {
    from: (t: string) => { assertEquals(t, 'telegram_processed_updates'); return {
      upsert: (row: any) => { calls.upserts++; const fresh = !keys.has(row.update_id); keys.add(row.update_id); return { select: () => Promise.resolve({ data: fresh ? [{ update_id: row.update_id }] : [], error: null }) }; },
      delete: () => ({ eq: (col: string, v: number) => { assertEquals(col, 'update_id'); calls.deletes.push(v); keys.delete(v); return Promise.resolve({ error: null }); } }),
    }; },
  };
  const d: T_Deps = {
    isAllowed: (c) => c === OPS, hasAwaiting: () => Promise.resolve(!!opts.awaiting),
    reply: (_c, _r, t) => { calls.replies.push(t); return Promise.resolve(); },
    forward: (u) => { calls.forwards.push(u); return Promise.resolve({ ok: opts.forwardOk !== false }); },
    log: (l) => calls.logs.push(l),
  };
  return { db, d, calls };
}

Deno.test('F3: a plain message that answers a pending prompt is not taken as a notice; an awaited edit is simply dropped', async () => {
  const r = rig({ awaiting: true });
  assertFalse(await T_handle(r.db, upd('water notice tomorrow 8am-5pm'), r.d), 'false = carry on to the expense flow');
  assertFalse(await T_handle(r.db, upd('water notice 8am-5pm'), r.d));
  assertEquals([r.calls.forwards.length, r.calls.replies.length, r.calls.upserts], [0, 0, 0]);
  assert(await T_handle(r.db, edit('water notice: Oct 16 8am-5pm'), r.d), 'an edit returns: it is never an expense');
  assertEquals(r.calls.forwards.length, 0);
});

Deno.test('F4: an exact-form message Cassy cannot build a card from does not use up the claim, so the fixing edit goes through', async () => {
  const r = rig();
  await T_handleExact(r.db, upd('water notice: soon'), r.d);
  assertEquals([r.calls.upserts, r.calls.forwards.length], [0, 1], 'forwarded, not claimed');
  assert(await T_handle(r.db, edit('water notice: Oct 16 8am-5pm'), r.d));
  assertEquals(r.calls.forwards.length, 2, 'the edit made the card');
  assert(await T_handle(r.db, edit('water notice: Oct 16 9am-5pm'), r.d));
  assertEquals(r.calls.forwards.length, 2, 'a second edit is already handled');
});

Deno.test('F4: an exact-form message with a date and times is claimed; its edit makes no second card', async () => {
  const r = rig();
  await T_handleExact(r.db, upd('brownout notice: Oct 16 8am-5pm'), r.d);
  assertEquals([r.calls.upserts, r.calls.forwards.length], [1, 1]);
  assert(await T_handle(r.db, edit('brownout notice: Oct 16 9am-5pm'), r.d));
  assertEquals(r.calls.forwards.length, 1);
});

Deno.test('F4: an edit Cassy cannot build a card from is forwarded unclaimed', async () => {
  const r = rig();
  await T_handle(r.db, edit('water notice: x'), r.d);
  assertEquals([r.calls.forwards.length, r.calls.upserts], [1, 0]);
});

Deno.test('F5: a forward that fails releases the claim so the fixing edit can still make the card', async () => {
  const bad = rig({ forwardOk: false });
  assert(await T_handle(bad.db, upd('water notice tomorrow 8am-5pm'), bad.d));
  assertEquals(bad.calls.forwards.length, 1);
  assertEquals(bad.calls.deletes.length, 1, 'claim row deleted');
  assert(bad.calls.deletes[0] < 0);
  bad.d.forward = (u) => { bad.calls.forwards.push(u); return Promise.resolve({ ok: true }); };
  assert(await T_handle(bad.db, edit('water notice tomorrow 9am-5pm'), bad.d));
  assertEquals(bad.calls.forwards.length, 2);
  const thrown = rig();
  thrown.d.forward = () => Promise.reject(new Error('timeout'));
  await T_handleExact(thrown.db, upd('water notice: Oct 16 8am-5pm'), thrown.d);
  assertEquals(thrown.calls.deletes.length, 1);
});

Deno.test('one hint per message: an unreadable edit gets no second reply', async () => {
  const r = rig();
  assert(await T_handle(r.db, upd('water notice 8am-5pm'), r.d));
  assertEquals(r.calls.replies.length, 1);
  assert(await T_handle(r.db, edit('water notice 8am-5pm please'), r.d));
  assertEquals(r.calls.replies.length, 1);
});
