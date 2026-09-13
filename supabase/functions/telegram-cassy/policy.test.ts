// deno test telegram-cassy/policy.test.ts  (run from supabase/functions)
import { assertEquals, assert } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { gate, addressed, unmention, stripMoney, wantsExpense, honestAboutCard, deepRequest, deepAllowed } from './policy.ts';

Deno.test('deep tier: /deep before or after the address escalates and is removed; the cap is exclusive', () => {
  assertEquals(deepRequest('/deep compare August and September occupancy'), { deep: true, text: 'compare August and September occupancy' });
  assertEquals(deepRequest('Cassy /deep@CascadeHideawayBot why is revenue down?'), { deep: true, text: 'Cassy why is revenue down?' });
  assertEquals(deepRequest('who arrives this week?'), { deep: false, text: 'who arrives this week?' });
  assertEquals(deepAllowed(9, 10), true);
  assertEquals(deepAllowed(10, 10), false);
  assertEquals(deepAllowed(0, 0), false);
});
import { parseReport, renderReport } from '../_shared/cascade-core/format.ts';
import { nightsIn, writeTool } from '../_shared/cascade-core/tools.ts';

// Minimal db stub: expense_categories select chain and telegram_pending insert chain.
const stubDb = (inserted: any[]) => ({
  from: (table: string) => ({
    select: () => ({ eq: () => ({ eq: async () => ({ data: [{ slug: 'supplies', label: 'Supplies' }, { slug: 'other', label: 'Other' }] }) }) }),
    insert: (row: any) => { inserted.push({ table, row }); return { select: () => ({ single: async () => ({ data: { id: 'pid-1' } }) }) }; },
  }),
});

Deno.test('wantsExpense: money spent with an amount in the finance chat forces log_expense; questions and ops do not', () => {
  assertEquals(wantsExpense('bought 2 packs of coffee at Puregold for 180 pesos', 'finance'), true);
  assertEquals(wantsExpense('Nagbayad ako ng ₱1,500 sa SOCOTECO', 'finance'), true);
  assertEquals(wantsExpense('how much did we spend on supplies this month?', 'finance'), false);
  assertEquals(wantsExpense('bought water 500', 'ops'), false);
});

Deno.test('honestAboutCard: without a card the "tap the card" claim is replaced', () => {
  const r = { decision: 'Log ₱180 supplies from Puregold.', lines: [], action: 'Tap ✅ on the card' };
  assertEquals(honestAboutCard(r, true), r);
  const h = honestAboutCard(r, false);
  assert(h.action.startsWith('No card was sent'));
  assertEquals(honestAboutCard({ decision: 'Two guests arrive.', lines: [], action: '' }, false).action, '');
});

Deno.test('unmention: forwarded text loses the cassy prefix or the @bot mention and nothing else', () => {
  assertEquals(unmention('@CascadeHideawayBot bought water 500'), 'bought water 500');
  assertEquals(unmention('Cassy: occupancy?'), 'occupancy?');
  assertEquals(unmention('@cascadehideawaybot'), null);
});

Deno.test('writeTool: log_expense builds the llm_expense pending row and card; ops surface is refused', async () => {
  const ins: any[] = [];
  const ctx = { chatId: -100111, from: { id: 7, first_name: 'Lloyd' }, surface: 'finance' as const };
  const w = await writeTool(stubDb(ins), ctx, 'log_expense', { amount: 500, category: 'supplies', payee: 'Puregold' });
  assertEquals(ins[0].table, 'telegram_pending');
  assertEquals(ins[0].row.kind, 'llm_expense');
  assertEquals(ins[0].row.payload, { amount: 500, category: 'supplies', label: 'Supplies', payee: 'Puregold', notes: 'Puregold', loggedBy: 'Lloyd 7' });
  assertEquals(w.card?.keyboard[0][0].callback_data, 'llm_expense_confirm:pid-1');
  assertEquals(w.card?.keyboard[0][1].callback_data, 'llm_cancel:pid-1');
  const ops = await writeTool(stubDb([]), { ...ctx, surface: 'ops' }, 'log_expense', { amount: 500, category: 'supplies' });
  assertEquals(ops.card, null);
  const bad = await writeTool(stubDb([]), ctx, 'log_expense', { amount: -1, category: 'supplies' });
  assertEquals(bad.card, null);
});

Deno.test('writeTool: create_notice builds the llm_notice pending row; brownout needs a time', async () => {
  const ins: any[] = [];
  const ctx = { chatId: -100222, from: { id: 7, first_name: 'Lloyd' }, surface: 'ops' as const };
  const w = await writeTool(stubDb(ins), ctx, 'create_notice', { notice_type: 'brownout', title: 'SOCOTECO maintenance', effective_date: '2026-09-20', effective_time: '08:00:00', duration_hours: 4 });
  assertEquals(ins[0].row.kind, 'llm_notice');
  assertEquals(ins[0].row.payload.params, { notice_type: 'brownout', title: 'SOCOTECO maintenance', effective_date: '2026-09-20', effective_time: '08:00:00', duration_hours: 4 });
  assertEquals(w.card?.keyboard[0][0].callback_data, 'llm_confirm:pid-1');
  const noTime = await writeTool(stubDb([]), ctx, 'create_notice', { notice_type: 'brownout', title: 'x', effective_date: '2026-09-20' });
  assertEquals(noTime.card, null);
});

const env = { financeChat: '-100111', opsChat: '-100222', dmUserIds: ['777'] };

Deno.test('gate: finance and ops chats pass with their surface; strangers and unlisted DMs are refused', () => {
  assertEquals(gate('-100111', 'supergroup', '1', env), { allowed: true, surface: 'finance' });
  assertEquals(gate('-100222', 'supergroup', '1', env), { allowed: true, surface: 'ops' });
  assertEquals(gate('777', 'private', '777', env), { allowed: true, surface: 'finance' });
  assertEquals(gate('888', 'private', '888', env).allowed, false);
  assertEquals(gate('-100333', 'supergroup', '777', env).allowed, false);
  assertEquals(gate('', 'supergroup', '', { financeChat: '', opsChat: '', dmUserIds: [] }).allowed, false);
});

Deno.test('addressed: only messages that start with cassy reach her, and the name is removed', () => {
  assertEquals(addressed('Cassy, who arrives this week?'), 'who arrives this week?');
  assertEquals(addressed('@cassy occupancy for August'), 'occupancy for August');
  assertEquals(addressed('cassy'), 'status');
  assertEquals(addressed('who arrives this week cassy?'), null);
  assertEquals(addressed('cassandra is here'), null);
});

Deno.test('stripMoney removes money-named keys at any depth and keeps the rest', () => {
  const r = stripMoney({ stays: [{ guest: 'Ana', accommodation_total: 3200, nights: 2 }], revenue_php: 9000, low: [{ name: 'Gas', qty: 1, unit_cost: 950 }] });
  assertEquals(r, { stays: [{ guest: 'Ana', nights: 2 }], low: [{ name: 'Gas', qty: 1 }] });
});

Deno.test('parseReport: fenced JSON, bare JSON and plain text all yield a report; render caps at five lines', () => {
  const a = parseReport('```json\n{"decision":"One guest arrives today.","lines":["Ana 2 nights","Paid"],"action":"Send the door PIN"}\n```');
  assertEquals(a, { decision: 'One guest arrives today.', lines: ['Ana 2 nights', 'Paid'], action: 'Send the door PIN' });
  const n = parseReport('{"decision":"D","lines":["1. Water: 5 left","2) Coffee","• Gas"],"action":""}');
  assertEquals(n.lines, ['Water: 5 left', 'Coffee', 'Gas']);
  const j = parseReport('Occupancy fell.\n{"august": 61, "september": 40}\nFewer Airbnb stays.');
  assertEquals(j.decision, 'Occupancy fell.');
  const y = parseReport("decision: James checks out next\nlines:\n- '1. James checks out Sep 14.'\n- '2. Queenie checks out Sep 16.'\naction: Tap ✅ on the card");
  assertEquals(y, { decision: 'James checks out next', lines: ['James checks out Sep 14.', 'Queenie checks out Sep 16.'], action: 'Tap ✅ on the card' });
  const stale = honestAboutCard(y, false);
  assertEquals(stale.action, '');
  assertEquals(stale.decision, 'James checks out next');
  const b = parseReport('Nothing needs you today.\nQuiet week.');
  assertEquals(b, { decision: 'Nothing needs you today.', lines: ['Quiet week.'], action: '' });
  const many = renderReport({ decision: 'D', lines: ['1', '2', '3', '4', '5', '6', '7'], action: 'A' }, 'm');
  assertEquals(many.split('\n').filter((l) => l.startsWith('• ')).length, 5);
  assert(many.endsWith('— m'));
  assertEquals(renderReport({ decision: '', lines: [], action: '' }, 'm'), 'Nothing needs you right now.\n\n— m');
});

Deno.test('nightsIn clips a stay to the period and prorates revenue per night', () => {
  const s = { checkin: '2026-08-30', checkout: '2026-09-03', nights: 4, accommodation_total: 6400 };
  assertEquals(nightsIn(s, '2026-09-01', '2026-10-01'), { nights: 2, revenue: 3200 });
  assertEquals(nightsIn(s, '2026-08-01', '2026-09-01'), { nights: 2, revenue: 3200 });
  assertEquals(nightsIn({ ...s, accommodation_total: null }, '2026-08-01', '2026-10-01'), { nights: 4, revenue: null });
  assertEquals(nightsIn(s, '2026-10-01', '2026-11-01').nights, 0);
});
