import { assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { hasMoney } from '../_shared/ops-money.ts';
import { buildReport, type Item, type Shop } from './report.ts';

import { it, ITEMS, NOW, SHOP } from './fixtures.ts';

const strip = (items: Item[]): Item[] => items.map(({ cost: _c, ...r }) => r);
const stripShop = (shop: Shop[]): Shop[] => shop.map(({ estCost: _e, ...r }) => r);

const flat = (r: ReturnType<typeof buildReport>) => r.groups.flatMap((g) => g.rows);
const names = (r: ReturnType<typeof buildReport>) => flat(r).map((c) => c[0]);

Deno.test('order (ops): buy up to par, else 2 x reorder, whole packs; groups by category, Out first', () => {
  const r = buildReport('order', 'ops', strip(ITEMS), stripShop(SHOP), NOW, 'Marifel Santos');
  assertEquals(r.columns, ['Item', 'On hand', 'Target', 'Buy', 'Note']);
  assertEquals(r.groups.map((g) => g.heading), ['Cleaning', 'Kitchen & Dining', 'Shopping list', 'Toiletries']);
  const rows = Object.fromEntries(flat(r).map((c) => [c[0], c]));
  assertEquals(rows['Hand soap'].slice(1, 4), ['0', '12', '2 box']); // par 12, 6 per box
  assertEquals(rows['Toilet paper'].slice(1, 4), ['3', '12', '3 pack']); // 2 x 6 = 12, need 9, 4 per pack -> 3
  assertEquals(rows['Dish soap'].slice(1, 4), ['2', '10', '8 bottle']);
  assertFalse('Sponge' in rows, 'an item above its reorder level is not ordered');
  assertFalse('Mug' in rows);
  assertEquals(rows['Birthday candles'].slice(1, 4), ['0', '-', '2 pc']); // shopping-list row keeps its own quantity
  assertEquals(r.rowCount, 4);
});

Deno.test('order: a shopping row for an item already on the list is merged (note kept), not repeated', () => {
  const r = buildReport('order', 'ops', strip(ITEMS), stripShop(SHOP), NOW, 'M');
  assertEquals(names(r).filter((x) => x === 'Hand soap').length, 1);
  assertStringIncludes(flat(r).find((c) => c[0] === 'Hand soap')![4], 'cheapest at Gaisano');
});

Deno.test('order: Out sorts before Low inside a category', () => {
  const items = [
    it({ id: 'a', name: 'Aaa', consumable: true, qty: 2, reorder: 5 }),
    it({ id: 'z', name: 'Zzz', consumable: true, qty: 0, reorder: 5 }),
  ];
  assertEquals(names(buildReport('order', 'ops', items, [], NOW, 'M')), ['Zzz', 'Aaa']);
});

Deno.test('order: an item under par but above its reorder level is ordered; at least one pack', () => {
  const items = [it({ id: 'p', name: 'Pen', consumable: true, qty: 8, reorder: 5, par: 10 }), it({ id: 'q', name: 'Zero', consumable: true, qty: 0, reorder: 0 })];
  const rows = flat(buildReport('order', 'ops', items, [], NOW, 'M'));
  assertEquals(rows.find((c) => c[0] === 'Pen')!.slice(3, 4), ['2 pc']);
  assertEquals(rows.find((c) => c[0] === 'Zero')!.slice(3, 4), ['1 pc']);
});

Deno.test('low / all / consumables / misc rows and statuses', () => {
  const low = buildReport('low', 'ops', strip(ITEMS), [], NOW, 'Honey');
  assertEquals(low.columns, ['Item', 'On hand', 'Reorder at', 'Status']);
  assertEquals(low.groups.map((g) => g.heading), ['Cleaning', 'Kitchen & Dining', 'Toiletries']);
  assertEquals(flat(low).map((c) => [c[0], c[3]]), [['Toilet paper', 'LOW'], ['Dish soap', 'LOW'], ['Hand soap', 'OUT']]);
  assertEquals(low.caption, 'Low stock list, 3 items. Sent from the staff app by Honey.');
  assertEquals(buildReport('all', 'ops', strip(ITEMS), [], NOW, 'H').rowCount, 7);
  assertEquals(buildReport('consumables', 'ops', strip(ITEMS), [], NOW, 'H').rowCount, 4);
  const misc = buildReport('misc', 'ops', strip(ITEMS), [], NOW, 'H');
  assertEquals(names(misc), ['Hammer', 'Spare bulb']);
  assertEquals(misc.columns, ['Item', 'On hand', 'Unit', 'Note']);
});

Deno.test('low report lists Out items before Low inside a category', () => {
  const items = [it({ id: 'a', name: 'Aaa', consumable: true, qty: 1, reorder: 5 }), it({ id: 'z', name: 'Zzz', consumable: true, qty: 0, reorder: 5 })];
  assertEquals(names(buildReport('low', 'ops', items, [], NOW, 'M')), ['Zzz', 'Aaa']);
});

Deno.test('empty report says so plainly; subtitle is Manila time with a first name', () => {
  const r = buildReport('low', 'ops', [], [], NOW, 'Marifel Santos');
  assertEquals(r.rowCount, 0);
  assertStringIncludes(r.empty!, 'Nothing to list today');
  assertEquals(r.subtitle, 'Made 15 Oct 2026, 12:30 pm Manila time by Marifel');
  assertEquals(r.filename, 'cascade-low-2026-10-15.pdf');
  assertEquals(r.financeLine, null);
});

Deno.test('OPS reports hold no money anywhere, in any kind', () => {
  for (const kind of ['order', 'all', 'consumables', 'low', 'misc'] as const) {
    // Even if a caller leaked cost fields in, the ops builder never prints them.
    const r = buildReport(kind, 'ops', ITEMS, SHOP, NOW, 'Honey');
    const text = JSON.stringify([r.title, r.subtitle, r.columns, r.groups, r.totals, r.caption, r.empty]);
    assertFalse(/PHP|₱|cost|price|value|total|supplier/i.test(text), `${kind}: ${text}`);
    assertEquals(r.totals, []);
    assertFalse(hasMoney(r.caption));
    assertFalse(hasMoney(r.title));
    assertFalse(hasMoney(r.subtitle));
  }
});

Deno.test('OPS shopping note: phone, e-mail and an amount are redacted or masked', () => {
  const r = buildReport('order', 'ops', strip(ITEMS), stripShop(SHOP), NOW, 'M');
  const text = JSON.stringify(r.groups);
  assertFalse(text.includes('0917'), 'phone');
  assertFalse(text.includes('example.com'), 'email');
  assertFalse(/P500|500/.test(text), 'amount');
  assertStringIncludes(text, 'cheapest at Gaisano');
});

Deno.test('Finance order: unit cost, estimated cost, total, and items without a price are counted', () => {
  const r = buildReport('order', 'finance', ITEMS, SHOP, NOW, 'Lloyd');
  assertEquals(r.columns, ['Item', 'On hand', 'Target', 'Buy', 'Unit cost', 'Est. cost', 'Note']);
  assertEquals(r.financeLine, 'Finance copy - prices included');
  const rows = Object.fromEntries(flat(r).map((c) => [c[0], c]));
  assertEquals(rows['Hand soap'].slice(4, 6), ['PHP 95.00', 'PHP 1,140.00']); // 12 units x 95
  assertEquals(rows['Toilet paper'].slice(4, 6), ['PHP 20.00', 'PHP 240.00']); // 12 units x 20
  assertEquals(rows['Dish soap'].slice(4, 6), ['-', '-']);
  assertEquals(rows['Birthday candles'].slice(4, 6), ['-', 'PHP 50.00']); // the row's own estimate
  assertEquals(r.totals, ['Estimated total PHP 1,430.00', '1 item has no price.']);
});

Deno.test('Finance all / misc: value = on hand x unit cost; total and missing prices', () => {
  const all = buildReport('all', 'finance', ITEMS, [], NOW, 'L');
  assertEquals(flat(all).find((c) => c[0] === 'Mug')!.slice(4), ['PHP 80.00', 'PHP 480.00']);
  assertEquals(all.totals, ['Total value PHP 1,220.00', '2 items have no price.']); // 0 + 60 + 80 + 480 + 600
  const misc = buildReport('misc', 'finance', ITEMS, [], NOW, 'L');
  assertEquals(misc.columns, ['Item', 'On hand', 'Unit', 'Unit cost', 'Value', 'Note']);
  assertEquals(misc.totals, ['Total value PHP 600.00', '1 item has no price.']);
  assertEquals(buildReport('low', 'finance', ITEMS, [], NOW, 'L').columns, ['Item', 'On hand', 'Reorder at', 'Status', 'Unit cost']);
});
