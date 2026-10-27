// deno test -A --node-modules-dir=auto telegram-expense/countsheet.test.ts - s99f (D-351): count by typed message or photo.
import { assert, assertEquals, assertFalse } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  appliedLines, countCard, countRpc, isCountText, matchItems, parseAsOf, parseCountText, parseNumber, photoRoute, readCountPhoto, readSheet, type StockItem, toChanges,
} from './countsheet.ts';

const NOW = Date.parse('2026-10-27T04:00:00Z'); // 12:00 Manila, 27 Oct 2026
const it = (id: string, name: string, qty: number, o: Partial<StockItem> = {}): StockItem => ({ id, name, unit: 'pc', qty, reorder: null, controlled: false, ...o });
const ITEMS = [
  it('i1', 'Lysol Disinfectant Spray', 3), it('i2', 'Bottled Water', 24), it('i3', 'Dishwashing Liquid (Joy)', 2, { reorder: 1 }),
  it('i4', 'Liquid Hand Soap (Safeguard)', 5), it('i5', 'Liquid Body Soap (Dove)', 4), it('i6', 'Coffee (3-in-1)', 28),
  it('i7', 'Garbage Bags (Small)', 2), it('i8', 'Garbage Bags (Large)', 2), it('i9', 'Sugar & Creamer Sticks', 10), it('i10', 'Towels', 6, { controlled: true }),
];
const esc = (s: unknown) => String(s ?? '').replace(/([_*`\[])/g, '\\$1');

Deno.test('numbers: fractions, mixed numbers, sums, decimals; anything else is unreadable', () => {
  assertEquals(parseNumber('2'), 2);
  assertEquals(parseNumber('1/2'), 0.5);
  assertEquals(parseNumber('3/4'), 0.75);
  assertEquals(parseNumber('1 1/4'), 1.25);
  assertEquals(parseNumber('16+46'), 62);
  assertEquals(parseNumber('1/2 + 2'), 2.5);
  assertEquals(parseNumber('1.5'), 1.5);
  assertEquals(parseNumber('1/3'), null);
  assertEquals(parseNumber('1.555'), null);
  assertEquals(parseNumber('abc'), null);
  assertEquals(parseNumber(''), null);
});

Deno.test('text: comma pairs, lines, fractions, sums; junk is listed, good rows survive', () => {
  const p = parseCountText('Count: Lysol 2, bottled water 20, joy 1/2\nsugar & creamer sticks 16+46\nmystery\nCoffee (3-in-1) 17', NOW);
  assertEquals(p.rows, [
    { name: 'Lysol', counted: 2 }, { name: 'bottled water', counted: 20 }, { name: 'joy', counted: 0.5 },
    { name: 'sugar & creamer sticks', counted: 62 }, { name: 'Coffee (3-in-1)', counted: 17 },
  ]);
  assertEquals(p.unreadable, ['mystery']);
  assertEquals(p.asOf, null);
  assertFalse(p.asOfBad);
});

Deno.test('text: separators, zero is a real count, a later line for the same name wins, three decimals is junk', () => {
  const p = parseCountText('inventory\nlysol: 0; water = 5\njoy - 3\nlysol 4\nsoap 1.555', NOW);
  assertEquals(p.rows, [{ name: 'lysol', counted: 4 }, { name: 'water', counted: 5 }, { name: 'joy', counted: 3 }]);
  assertEquals(p.unreadable, ['soap 1.555']);
});

Deno.test('isCountText: starts with count or inventory plus something; a command or an expense is not', () => {
  assert(isCountText('count lysol 2'));
  assert(isCountText('Inventory: joy 1'));
  assertFalse(isCountText('count'));
  assertFalse(isCountText('counter top 250'));
  assertFalse(isCountText('/count'));
  assertFalse(isCountText('250 supplies Puregold'));
});

Deno.test('as of: day-month, month-day, year, am/pm, and the 60 day / future window', () => {
  assertEquals(parseAsOf('as of 16 Oct 8:21', NOW).iso, '2026-10-16T08:21:00+08:00');
  assertEquals(parseAsOf('x as of 16 Oct 2026, 08:21 y', NOW).iso, '2026-10-16T08:21:00+08:00');
  assertEquals(parseAsOf('as of Oct 16 8:21pm', NOW).iso, '2026-10-16T20:21:00+08:00');
  assertEquals(parseAsOf('as of 12 Oct 12:05 am', NOW).iso, '2026-10-12T00:05:00+08:00');
  assertEquals(parseAsOf('as of 30 Oct 8:00', NOW).iso, null); // would be in the future, so last year, which is over 60 days
  assertEquals(parseAsOf('as of 16 Oct', NOW).iso, null); // no time: refuse, never assume midnight
  assertEquals(parseAsOf('as of 31 Feb 8:00', NOW).iso, null);
  assertEquals(parseAsOf('as of 1 Jan 2026 8:00', NOW).iso, null); // older than 60 days
  const p = parseCountText('count lysol 2 as of 16 Oct 8:21, joy 1', NOW);
  assertEquals(p.asOf, '2026-10-16T08:21:00+08:00');
  assertEquals(p.rows, [{ name: 'lysol', counted: 2 }, { name: 'joy', counted: 1 }]);
  assertEquals(parseCountText('count lysol 2 as of 16 Oct', NOW).asOfBad, true);
});

Deno.test('match: exact, contains, misspelling; ambiguous and unmatched are listed back, never guessed', () => {
  const r = matchItems([
    { name: 'Lysol', counted: 2 }, { name: 'bottled water', counted: 20 }, { name: 'joy', counted: 0.5 }, { name: 'Bottled Watr', counted: 7 },
    { name: 'garbage bags', counted: 1 }, { name: 'soap', counted: 1 }, { name: 'zzzz', counted: 3 }, { name: 'towels', counted: 2 },
  ], ITEMS);
  assertEquals(r.matched.map((m) => [m.item.id, m.counted]), [['i1', 2], ['i2', 7], ['i3', 0.5]]); // 'bottled water' then the misspelling: the later line wins
  assertEquals(r.ambiguous.map((a) => [a.name, a.options]), [
    ['garbage bags', ['Garbage Bags (Small)', 'Garbage Bags (Large)']],
    ['soap', ['Liquid Hand Soap (Safeguard)', 'Liquid Body Soap (Dove)']],
  ]);
  assertEquals(r.unmatched, ['zzzz']);
  assertEquals(r.blocked, ['Towels']);
});

Deno.test('changes: with no as-of an unchanged row is dropped; with an as-of every row stays', () => {
  const m = matchItems([{ name: 'lysol', counted: 3 }, { name: 'water', counted: 20 }], ITEMS).matched;
  assertEquals(toChanges(m, null).map((c) => c.item_id), ['i2']);
  assertEquals(toChanges(m, '2026-10-16T08:21:00+08:00').map((c) => c.item_id), ['i1', 'i2']);
});

Deno.test('card: no as-of uses the /count review lines; as-of explains the rule; notes list what was not applied', () => {
  const res = matchItems([{ name: 'lysol', counted: 1 }, { name: 'zzzz', counted: 3 }, { name: 'soap', counted: 1 }], ITEMS);
  const plain = countCard({ source: 'typed', asOf: null, changes: toChanges(res.matched, null), res, unreadable: ['mystery'], notRead: [] }, esc);
  assert(plain.canConfirm);
  const t = plain.chunks.join('\n');
  assert(t.includes('• Lysol Disinfectant Spray: 3 → 1 pc  (−2)'), t);
  assert(t.includes('No item by that name:\n• zzzz'));
  assert(t.includes('Which one? Type the full name:'));
  assert(t.includes('Could not read:\n• mystery'));
  assert(t.includes('Nothing is saved until you tap Confirm.'));
  assertFalse(t.includes('!'));
  assertFalse(/₱|PHP/.test(t));
  const asof = countCard({ source: 'photo', asOf: '2026-10-16T08:21:00+08:00', changes: toChanges(res.matched, '2026-10-16T08:21:00+08:00'), res, unreadable: [], notRead: ['Natural Air'] }, esc);
  const a = asof.chunks.join('\n');
  assert(a.includes('Count from photo* · as of 16 Oct 08:21'), a);
  assert(a.includes('• Lysol Disinfectant Spray: counted 1 pc  (now 3)'), a);
  assert(a.includes('Not read - type them:\n• Natural Air'));
  const none = countCard({ source: 'typed', asOf: null, changes: [], res, unreadable: [], notRead: [] }, esc);
  assertFalse(none.canConfirm);
});

Deno.test('card: a long count splits into chunks under the Telegram limit', () => {
  const many = Array.from({ length: 90 }, (_, i) => it(`x${i}`, `Item number ${i} with a longer name to fill space`, 1));
  const res = matchItems(many.map((m, i) => ({ name: m.name, counted: i + 5 })), many);
  const c = countCard({ source: 'typed', asOf: null, changes: toChanges(res.matched, null), res, unreadable: [], notRead: [] }, esc);
  assert(c.chunks.length > 1);
  assert(c.chunks.every((x) => x.length < 4000));
});

Deno.test('confirm payload: v2 carries p_as_of and counted/expected_before; a /count card stays on v1', () => {
  const changes = toChanges(matchItems([{ name: 'lysol', counted: 1 }], ITEMS).matched, '2026-10-16T08:21:00+08:00');
  const v2 = countRpc({ v2: true, as_of: '2026-10-16T08:21:00+08:00', changes }, 777, 'Telegram count by Lloyd');
  assertEquals(v2.fn, 'telegram_apply_inventory_count_v2');
  assertEquals(v2.args, {
    p_telegram_user_id: 777, p_rows: [{ item_id: 'i1', counted: 1, expected_before: 3 }], p_note: 'Telegram count by Lloyd', p_as_of: '2026-10-16T08:21:00+08:00',
  });
  assertEquals(countRpc({ v2: true, as_of: null, changes }, 1, 'n').args.p_as_of, null);
  const v1 = countRpc({ changes }, 777, 'n');
  assertEquals(v1.fn, 'telegram_apply_inventory_count_v1');
  assertFalse('p_as_of' in v1.args);
});

Deno.test('applied lines: counted, movement since, clamp', () => {
  const l = appliedLines([{ name: 'Lysol', after: 3, counted: 1, since_delta: 2, clamped: false }, { name: 'Joy', after: 0, counted: 0, since_delta: -3, clamped: true }], esc);
  assertEquals(l, ['• Lysol: 3  (counted 1, +2 logged since)', '• Joy: 0  (counted 0, −3 logged since, set to 0)']);
});

// ---- photo ----
const sheetJson = (extra: Record<string, unknown> = {}) => JSON.stringify({
  is_count_sheet: true, confidence: 0.95, printed_at: '2026-10-16T08:21',
  rows: [{ name: 'Lysol', counted: 1, confidence: 0.95 }, { name: 'Joy', counted: '1/2', confidence: 0.9 }, { name: 'Natural Air', counted: null, confidence: 0.9 },
    { name: 'Ambi Pur', counted: 1, confidence: 0.5 }, { name: 'Sugar', counted: '16+46', confidence: 0.85 }], ...extra,
});

Deno.test('photo reading: low confidence and blank numbers go to notRead, never applied; printed time becomes as-of', () => {
  const s = readSheet(JSON.parse(sheetJson()), NOW);
  assertEquals(s.rows, [{ name: 'Lysol', counted: 1 }, { name: 'Joy', counted: 0.5 }, { name: 'Sugar', counted: 62 }]);
  assertEquals(s.notRead, ['Natural Air', 'Ambi Pur']);
  assertEquals(s.asOf, '2026-10-16T08:21:00+08:00');
  assertFalse(s.asOfBad);
  assert(readSheet({ printed_at: '2025-01-01T08:00', rows: [] }, NOW).asOfBad);
});

Deno.test('routing: caption count/inventory -> count; no caption -> receipt unless autodetect; any other caption -> receipt', () => {
  assertEquals(photoRoute('count', false), 'count');
  assertEquals(photoRoute('Inventory 16 Oct', false), 'count');
  assertEquals(photoRoute(undefined, false), 'receipt');
  assertEquals(photoRoute('', false), 'receipt');
  assertEquals(photoRoute('puregold 250', true), 'receipt');
  assertEquals(photoRoute(undefined, true), 'detect');
  assertEquals(photoRoute('counter top', true), 'receipt'); // \bcount\b: "counter" is not "count"
});

Deno.test('routing with fake vision: a receipt photo is untouched; a sheet is taken; no vision call when the route is receipt', async () => {
  let calls = 0;
  const receipt = () => { calls++; return Promise.resolve(JSON.stringify({ is_count_sheet: false, confidence: 0.1, rows: [] })); };
  assertEquals(await readCountPhoto(receipt, 'detect', NOW), { kind: 'receipt' });
  assertEquals(calls, 1);
  // The route function decides before any vision call: a plain receipt with autodetect off never reaches the reader.
  assertEquals(photoRoute(undefined, false), 'receipt');
  assertEquals(calls, 1);
  // A sheet under the 0.8 bar is still a receipt in detect mode.
  assertEquals(await readCountPhoto(() => Promise.resolve(sheetJson({ confidence: 0.79 })), 'detect', NOW), { kind: 'receipt' });
  assertEquals((await readCountPhoto(() => Promise.resolve(sheetJson()), 'detect', NOW)).kind, 'sheet');
  // Garbage from the model: detect falls back to the receipt path; a caption count reports failure.
  assertEquals(await readCountPhoto(() => Promise.resolve('not json'), 'detect', NOW), { kind: 'receipt' });
  assertEquals(await readCountPhoto(() => Promise.resolve('not json'), 'count', NOW), { kind: 'failed', why: 'unreadable' });
  assertEquals(await readCountPhoto(() => Promise.resolve('```json\n{"rows":[]}\n```'), 'count', NOW), { kind: 'failed', why: 'no_rows' });
  assertEquals(await readCountPhoto(() => Promise.reject(new Error('boom')), 'count', NOW), { kind: 'failed', why: 'unreadable' });
  // A caption count trusts the person even when the model hedges on is_count_sheet.
  assertEquals((await readCountPhoto(() => Promise.resolve(sheetJson({ is_count_sheet: false, confidence: 0.2 })), 'count', NOW)).kind, 'sheet');
});

Deno.test('end to end: a photo sheet becomes a card with as-of and a Not read list, and confirm args match', async () => {
  const out = await readCountPhoto(() => Promise.resolve(sheetJson()), 'count', NOW);
  assertEquals(out.kind, 'sheet');
  if (out.kind !== 'sheet') return;
  const res = matchItems(out.sheet.rows, ITEMS);
  const changes = toChanges(res.matched, out.sheet.asOf);
  const card = countCard({ source: 'photo', asOf: out.sheet.asOf, changes, res, unreadable: [], notRead: out.sheet.notRead }, esc).chunks.join('\n');
  assert(card.includes('as of 16 Oct 08:21'));
  assert(card.includes('Not read - type them:\n• Natural Air\n• Ambi Pur'));
  assert(card.includes('• Dishwashing Liquid (Joy): counted 0.5 pc  (now 2)'));
  assertEquals(countRpc({ v2: true, as_of: out.sheet.asOf, changes }, 1, 'n').args.p_as_of, '2026-10-16T08:21:00+08:00');
});

// ---- fix round 1 ----
Deno.test('as-of time never swallows the next line (am/pm boundary)', () => {
  const a = parseCountText('count as of 16 Oct 8:21\nPalmolive shampoo 2', NOW);
  assertEquals(a.asOf, '2026-10-16T08:21:00+08:00');
  assertEquals(a.rows, [{ name: 'Palmolive shampoo', counted: 2 }]);
  const b = parseCountText('count as of 16 Oct 8:21 Ambi Pur 1', NOW);
  assertEquals(b.rows, [{ name: 'Ambi Pur', counted: 1 }]);
  assertEquals(parseCountText('count as of 16 Oct 8:21pm\nwater 3', NOW).asOf, '2026-10-16T20:21:00+08:00');
});
Deno.test('thousands comma stays inside the number; a bare-number fragment blocks Confirm', () => {
  assertEquals(parseCountText('count water 1,000, lysol 2', NOW).rows, [{ name: 'water', counted: 1000 }, { name: 'lysol', counted: 2 }]);
  const res = matchItems([{ name: 'Lysol', counted: 2 }], ITEMS);
  const base = { source: 'typed' as const, asOf: null, changes: toChanges(res.matched, null), res, notRead: [] };
  assertFalse(countCard({ ...base, unreadable: ['5'] }, (x) => String(x)).canConfirm);
  assert(countCard({ ...base, unreadable: ['junk'] }, (x) => String(x)).canConfirm);
});
Deno.test('photo: prose around the JSON is tolerated; a sure non-sheet in count mode goes to the receipt path', async () => {
  const sheet = '{"is_count_sheet":true,"confidence":0.9,"printed_at":null,"rows":[{"name":"Lysol","counted":2,"confidence":0.9}]}';
  const o = await readCountPhoto(async () => `Here is the JSON:\n${sheet}\nHope that helps`, 'count', NOW);
  assertEquals(o.kind, 'sheet');
  const rc = await readCountPhoto(async () => '{"is_count_sheet":false,"confidence":0.95,"rows":[]}', 'count', NOW);
  assertEquals(rc.kind, 'receipt');
  const unsure = await readCountPhoto(async () => '{"is_count_sheet":false,"confidence":0.3,"rows":[]}', 'count', NOW);
  assertEquals(unsure.kind, 'failed');
});
Deno.test('index.ts wiring: a typed count that parses no row falls through unless the bot is addressed; v2 copy says send again', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(src.includes('if(!p.rows.length&&!addressed)return false;'));
  assert(src.includes('handleTypedCount(db,chatId,text,isBotAddressed(msg))'));
  assert(src.includes("payload?.v2?'Send the count again'"));
  assert(src.includes('count Lysol 2, water 20'));
});
