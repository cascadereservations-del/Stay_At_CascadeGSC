// deno test --no-check -A _shared/ops-money.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { hasMoney, maskMoney } from './ops-money.ts';

const LEAK = /₱|\bPHP\b|\bP\d|pesos?\b|0956|9560115744|\b09\d{9}\b/i;

Deno.test('amounts and the payment number are hidden in every form a guest or a draft writes them', () => {
  for (const t of [
    'Hi, I sent PHP 1,780 to 0956 011 5744 already', 'the ₱3,560 balance', 'P1000 deposit', 'php 2000.50 total', '2,000 pesos', '3560 PHP',
    'GCash to +63 956 011 5744', 'send to gcash 09560115744', 'Maya number 0917 123 4567 please', 'account no. 1234-5678-90',
  ]) { const m = maskMoney(t); assert(hasMoney(t), t); assert(!LEAK.test(m), `${t} -> ${m}`); assert(!/\d{4}[\s-]?\d{3,}/.test(m), `${t} -> ${m}`); }
});

Deno.test('text with no money passes through untouched, dates and counts included', () => {
  for (const t of ['Tue, Oct 20 → Thu, Oct 22 · 2 guests', 'Check-in from 2:00 PM, check-out 12:00 noon', 'Work order #1a2b3c4d raised', 'https://www.facebook.com/messages/t/1234567890123456']) {
    assertEquals(maskMoney(t), t); assert(!hasMoney(t));
  }
});
