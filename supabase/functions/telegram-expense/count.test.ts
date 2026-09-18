// deno test --no-check --allow-env telegram-expense/count.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  changesFrom, chunkLines, type CountItem, inventoryGroup, numberedCountLines, parseCountReply, reviewLines, SCOPE_GROUPS,
} from './count.ts';

const item = (id: string, name: string, qty: number, reorder: number | null = null, unit = 'pc'): CountItem =>
  ({ id, name, unit, qty, reorder });

const ITEMS = [
  item('i1', 'Bottled Water', 24),
  item('i2', 'Coffee (3-in-1)', 28, 10),
  item('i3', 'Liquid Hand Soap', 3, 3),
  item('i4', 'Dish Sponge', 6),
];

Deno.test('a reply is read line by line, and a bad line never discards a good one', () => {
  const p = parseCountReply('2 20\n7 0\nbananas\n3=0\n4 - 6', ITEMS.length);
  assertEquals(p.changes, [{ index: 2, counted: 20 }, { index: 3, counted: 0 }, { index: 4, counted: 6 }]);
  assertEquals(p.outOfRange, [7]);
  assertEquals(p.unreadable, ['bananas']);
});

Deno.test('zero is a real count, and decimals are accepted to two places', () => {
  assertEquals(parseCountReply('1 0', ITEMS.length).changes, [{ index: 1, counted: 0 }]);
  assertEquals(parseCountReply('1 1.5', ITEMS.length).changes, [{ index: 1, counted: 1.5 }]);
  // Three decimals is not a stock count; it is a typo. The RPC refuses it too.
  assertEquals(parseCountReply('1 1.555', ITEMS.length).unreadable, ['1 1.555']);
});

Deno.test('a correction later in the same message wins', () => {
  assertEquals(parseCountReply('2 20\n2 22', ITEMS.length).changes, [{ index: 2, counted: 22 }]);
});

Deno.test('separators people actually type all work', () => {
  for (const text of ['2:20', '2 = 20', '2-20', '  2   20  ']) {
    assertEquals(parseCountReply(text, ITEMS.length).changes, [{ index: 2, counted: 20 }], text);
  }
  // One message, several counts on one line.
  assertEquals(parseCountReply('1 5, 2 6; 3 7', ITEMS.length).changes.length, 3);
});

Deno.test('re-typing the same number is not a change', () => {
  const c = changesFrom(ITEMS, parseCountReply('1 24\n2 20', ITEMS.length));
  assertEquals(c.length, 1);
  assertEquals(c[0].name, 'Coffee (3-in-1)');
  assertEquals(c[0].before, 28);
  assertEquals(c[0].counted, 20);
});

Deno.test('the review card shows the move and flags a figure at or under the reorder point', () => {
  const lines = reviewLines(changesFrom(ITEMS, parseCountReply('2 20\n3 0\n4 9', ITEMS.length)));
  assertEquals(lines[0], '• Coffee (3-in-1): 28 → 20 pc  (−8)');
  assertEquals(lines[1], '• Liquid Hand Soap: 3 → 0 pc  (−3)  🔴 below reorder');
  assertEquals(lines[2], '• Dish Sponge: 6 → 9 pc  (+3)'); // no reorder point set
});

Deno.test('the group rule splits a production-shaped catalogue 19 / 25 / 29', () => {
  const rows = [
    ...Array.from({ length: 19 }, (_, i) => ({ is_consumable: true, category: 'Consumables', name: `C${i}` })),
    ...Array.from({ length: 24 }, (_, i) => ({ is_consumable: false, category: 'Kitchen & Dining', name: `K${i}` })),
    { is_consumable: false, category: 'Appliances', name: 'Washing Machine (Panasonic)' },
    ...Array.from({ length: 29 }, (_, i) => ({ is_consumable: false, category: 'Linens', name: `S${i}` })),
  ];
  const count = (g: string) => rows.filter((r) => inventoryGroup(r) === g).length;
  assertEquals([count('consumables'), count('appliances'), count('stores')], [19, 25, 29]);
  assertEquals(rows.length, 73);
});

Deno.test('the washing machine is an appliance even though its category is not Kitchen & Dining', () => {
  assertEquals(inventoryGroup({ is_consumable: false, category: 'Appliances', name: 'Washing Machine (Panasonic)' }), 'appliances');
  assertEquals(inventoryGroup({ is_consumable: false, category: 'Appliances', name: 'Electric Fan' }), 'stores');
  // A consumable stays a consumable whatever its category says.
  assertEquals(inventoryGroup({ is_consumable: true, category: 'Kitchen & Dining', name: 'Dishwashing Liquid' }), 'consumables');
});

Deno.test('the three buttons cover what Lloyd asked for', () => {
  assertEquals(SCOPE_GROUPS['1'], ['consumables']);
  assertEquals(SCOPE_GROUPS['2'], ['stores']);
  assertEquals(SCOPE_GROUPS['3'], ['consumables', 'appliances', 'stores']);
});

Deno.test('numbering continues across groups, and a long list is split under the Telegram limit', () => {
  assertEquals(numberedCountLines(ITEMS.slice(0, 2)), [' 1. Bottled Water — 24 pc', ' 2. Coffee (3-in-1) — 28 pc']);
  assertEquals(numberedCountLines(ITEMS.slice(0, 1), 20), [' 20. Bottled Water — 24 pc']);

  const long = Array.from({ length: 200 }, (_, i) => ` ${i + 1}. Item with a fairly long name — 12 pc`);
  const chunks = chunkLines(long);
  assertEquals(chunks.every((c) => c.length <= 3500), true);
  assertEquals(chunks.join('\n').split('\n').length, 200); // nothing lost
});
