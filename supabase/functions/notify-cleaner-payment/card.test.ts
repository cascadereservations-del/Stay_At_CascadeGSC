// deno test --node-modules-dir=none --allow-env notify-cleaner-payment/card.test.ts
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type CardReq, redrawFinanceCard, webCardText } from './card.ts';

const base: CardReq = { id: 'r', ref: 'ABCD1234', status: 'paying', payee_name: 'Honey', total_amount: 500, finance_chat_id: -200, finance_message_id: 9, paying_by_name: 'Lloyd', paying_by_user_id: 'u1', paying_by_tg: null,
  lines: [{ kind: 'clean', session_id: 's', date: '2026-10-10', base: 500, transport: 0, amount: 500 }] };
const fake = (answers: Array<{ ok?: boolean; description?: string } | null>) => { const calls: Array<[string, Record<string, unknown>]> = []; return { calls, tg: async (m: string, b: Record<string, unknown>) => { calls.push([m, b]); return answers.length ? answers.shift()! : { ok: true }; } }; };

Deno.test('a payment the Staff app is handling: the card says who, shows the block, and has no buttons', async () => {
  const f = fake([]);
  assertEquals(await redrawFinanceCard(base, f), 'edited');
  const [method, b] = f.calls[0];
  assertEquals(method, 'editMessageCaption'); assertEquals(b.reply_markup, { inline_keyboard: [] });
  assertStringIncludes(String(b.caption), 'Lloyd is paying Honey ₱500 in the Staff app now. Nothing to tap here until it is paid.');
  assertStringIncludes(String(b.caption), 'Ref CASCADE-ABCD1234'); assert(!String(b.caption).includes('!'));
  assertEquals([b.chat_id, b.message_id], [-200, 9]); assert(!('parse_mode' in b));
  assert(webCardText(base).length < 1024);
});

Deno.test('stepping back or a Telegram payer: the normal card with its buttons comes back; paid, cancelled and unposted cards are left alone', async () => {
  const req = fake([]);
  assertEquals(await redrawFinanceCard({ ...base, status: 'requested', paying_by_user_id: null }, req), 'edited');
  assertStringIncludes(JSON.stringify(req.calls[0][1].reply_markup), 'spr:pay:');
  const tg = fake([]);
  await redrawFinanceCard({ ...base, paying_by_user_id: null, paying_by_tg: 920000001 }, tg);
  assertStringIncludes(JSON.stringify(tg.calls[0][1].reply_markup), 'spr:sent:');
  for (const r of [{ ...base, status: 'paid' as const }, { ...base, status: 'cancelled' as const }, { ...base, finance_message_id: null }]) { const f = fake([]); assertEquals(await redrawFinanceCard(r, f), 'skipped'); assertEquals(f.calls.length, 0); }
});

Deno.test('a text card (no photo) falls back to editMessageText; not-modified is fine; other errors say failed', async () => {
  const f = fake([{ ok: false, description: 'Bad Request: there is no caption in the message to edit' }, { ok: true }]);
  assertEquals(await redrawFinanceCard(base, f), 'edited'); assertEquals(f.calls.map((c) => c[0]), ['editMessageCaption', 'editMessageText']);
  assertEquals(await redrawFinanceCard(base, fake([{ ok: false, description: 'Bad Request: message is not modified' }])), 'edited');
  assertEquals(await redrawFinanceCard(base, fake([{ ok: false, description: 'Forbidden' }])), 'failed');
  assertEquals(await redrawFinanceCard(base, fake([null])), 'failed');
});
