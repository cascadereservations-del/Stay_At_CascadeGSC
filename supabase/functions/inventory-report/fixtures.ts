import type { Item, Shop } from './report.ts';

export const NOW = new Date('2026-10-15T04:30:00Z'); // frozen clock: 12:30 pm in Manila

export const it = (o: Partial<Item> & { id: string; name: string }): Item => ({
  category: 'Cleaning', unit: 'pc', qty: 0, reorder: null, par: null, consumable: false, purchaseUnit: null, unitsPer: null, ...o,
});
export const ITEMS: Item[] = [
  it({ id: 's', name: 'Hand soap', category: 'Toiletries', consumable: true, qty: 0, reorder: 4, par: 12, purchaseUnit: 'box', unitsPer: 6, cost: 95 }),
  it({ id: 't', name: 'Toilet paper', consumable: true, qty: 3, reorder: 6, unitsPer: 4, cost: 20 }),
  it({ id: 'k', name: 'Sponge', consumable: true, qty: 8, reorder: 5, cost: 10 }),
  it({ id: 'd', name: 'Dish soap', category: 'Kitchen & Dining', unit: 'bottle', consumable: true, qty: 2, reorder: 3, par: 10, cost: null }),
  it({ id: 'm', name: 'Mug', category: 'Kitchen & Dining', qty: 6, cost: 80 }),
  it({ id: 'b', name: 'Spare bulb', category: 'Miscellaneous', qty: 4, cost: 150 }),
  it({ id: 'h', name: 'Hammer', category: 'miscellaneous', qty: 1, cost: null }),
];
export const SHOP: Shop[] = [
  { itemId: 's', name: 'Hand soap', quantity: 3, purchaseUnit: 'box', note: 'cheapest at Gaisano, call 0917 123 4567 P500', estCost: 999 },
  { itemId: null, name: 'Birthday candles', quantity: 2, purchaseUnit: null, note: 'email me@example.com', estCost: 50 },
];

// Byte-exact PDF text (s86): inflate each content stream and decode its Tj operands. Shared by the new tests.
import { inflateSync } from 'node:zlib';
const latin1 = (b: Uint8Array) => Array.from(b, (c) => String.fromCharCode(c)).join('');
export function drawnText(bytes: Uint8Array): string {
  let out = '';
  for (const m of latin1(bytes).matchAll(/stream\r?\n([\s\S]*?)\r?\nendstream/g)) {
    let s: string;
    try { s = latin1(inflateSync(Uint8Array.from(m[1], (c) => c.charCodeAt(0)))); } catch { continue; }
    for (const t of s.matchAll(/<([0-9A-Fa-f]+)>\s*Tj|\(((?:\.|[^\)])*)\)\s*Tj/g)) {
      out += (t[1] ? String.fromCharCode(...(t[1].match(/../g) ?? []).map((h) => parseInt(h, 16))) : t[2]) + '\n';
    }
  }
  return out;
}
