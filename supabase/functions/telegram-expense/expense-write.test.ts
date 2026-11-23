// deno test --allow-read telegram-expense/expense-write.test.ts - s134 L3 (D-405): the Telegram expense writes go through two RPCs; the RPCs are faked here (L1 writes the SQL).
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  againForVoidedPhoto, categoryKeyboardFrom, categoryUnion, confirmExpense, FALLBACK_CATEGORIES, keyForMessage, keyForPending, keyForPhoto, lookalikeLine, onReplayedReceipt, pickableCategories,
  reviewExpense, reviewRefusal, saveExpense, setExpenseAmount, shortDate, SYSTEM_SLUGS, voidExpense, voidMany, writeLineItems,
} from './expense-write.ts';

const PROP = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';

// A fake database whose RPCs behave like the contract: save replays by key, review answers from a table of rows.
function rig(opts: { cats?: string[]; rows?: Record<string, { status: string; locked?: 'bills' | 'pay' }>; throwOn?: string } = {}) {
  const calls: Array<{ fn: string; args: any }> = [];
  const byKey = new Map<string, string>();
  const rows = opts.rows ?? {};
  let n = 0;
  const db = {
    rpc(fn: string, args: any) {
      calls.push({ fn, args });
      if (opts.throwOn === fn) return Promise.reject(new Error('boom'));
      if (fn === 'telegram_expense_save_v1') {
        const cats = opts.cats ?? ['supplies', 'other'];
        if (!cats.includes(args.p_txn.category)) return Promise.resolve({ data: { ok: false, error: 'bad_category' }, error: null });
        const old = byKey.get(args.p_key);
        if (old) return Promise.resolve({ data: { ok: true, id: old, replayed: true, lookalike: null }, error: null });
        const id = `id-${++n}`;
        byKey.set(args.p_key, id);
        return Promise.resolve({ data: { ok: true, id, replayed: false, lookalike: args.p_txn.amount === 1250 ? { id: 'x', date: '2026-11-21', amount: 1250, chip: 'stock' } : null }, error: null });
      }
      const r = rows[args.p_id];
      if (!r) return Promise.resolve({ data: { ok: false, error: 'not_found' }, error: null });
      if (r.locked) return Promise.resolve({ data: { ok: false, error: 'locked', where: r.locked }, error: null });
      if (args.p_action !== 'void' && r.status !== 'pending_review') return Promise.resolve({ data: { ok: false, error: 'not_pending' }, error: null });
      return Promise.resolve({ data: { ok: true }, error: null });
    },
  };
  return { db, calls };
}

const txn = (extra: Record<string, unknown> = {}) => ({ category: 'supplies', amount: 540, payee: 'Shop', notes: null, logged_by: 'Lloyd 1', ...extra });

Deno.test('keys: one per message, one per stored question, one per photo; a missing part gives no key', () => {
  assertEquals(keyForMessage(-100123, 77), 'tg:-100123:77');
  assertEquals(keyForPending('abc'), 'tgp:abc');
  assertEquals(keyForPhoto('receipts/5/uniq.jpg'), 'tgocr:receipts/5/uniq.jpg');
  assert(keyForMessage(-100123, 77) !== keyForMessage(-100123, 78), 'a different message is a different key');
  assert(keyForMessage(-100123, 77) !== keyForMessage(-100124, 77), 'a different chat is a different key');
  assert(keyForPhoto('p.jpg') !== keyForPhoto('p.jpg', 'pid1'), 'the "different receipt" tap is its own entry');
  assertEquals([keyForMessage(null, 7), keyForMessage(1, undefined), keyForPending(''), keyForPhoto('')], [null, null, null, null]);
});

Deno.test('save: the key and property go to the RPC; a retry with the same key returns the first id and says replayed', async () => {
  const r = rig();
  const a = await saveExpense(r.db, PROP, txn(), keyForMessage(1, 10));
  const b = await saveExpense(r.db, PROP, txn(), keyForMessage(1, 10));
  const c = await saveExpense(r.db, PROP, txn(), keyForMessage(1, 11));
  assert(a.ok && b.ok && c.ok);
  if (a.ok && b.ok && c.ok) {
    assertEquals([a.id, a.replayed, b.id, b.replayed, c.id], ['id-1', false, 'id-1', true, 'id-2']);
  }
  assertEquals(r.calls[0], { fn: 'telegram_expense_save_v1', args: { p_property_id: PROP, p_txn: txn(), p_key: 'tg:1:10' } });
});

Deno.test('save: an unknown category is refused with a plain message and no id; no key means no call', async () => {
  const r = rig();
  const bad = await saveExpense(r.db, PROP, txn({ category: 'guest_refund' }), keyForMessage(1, 1));
  assertFalse(bad.ok);
  if (!bad.ok) { assertEquals(bad.error, 'bad_category'); assertStringIncludes(bad.message, 'nothing was saved'); assertFalse(/bad_category|error|rpc/i.test(bad.message)); }
  const none = await saveExpense(r.db, PROP, txn(), null);
  assertFalse(none.ok);
  assertEquals(r.calls.length, 1, 'no key, no call');
});

Deno.test('save: an RPC that throws or returns an error saves nothing and says so', async () => {
  const t = await saveExpense(rig({ throwOn: 'telegram_expense_save_v1' }).db, PROP, txn(), 'k');
  assertFalse(t.ok);
  const e = await saveExpense({ rpc: () => Promise.resolve({ data: null, error: { message: 'permission denied' } }) }, PROP, txn(), 'k');
  assertFalse(e.ok);
  const empty = await saveExpense({ rpc: () => Promise.resolve({ data: { ok: true }, error: null }) }, PROP, txn(), 'k');
  assertFalse(empty.ok, 'ok without an id is not a save');
});

Deno.test('save: the OCR row carries the receipt path, the read and the pending status through p_txn', async () => {
  const r = rig();
  const o = txn({ status: 'pending_review', source: 'ocr', receipt_image_path: 'receipts/5/u.jpg', ocr_confidence: 0.9, ocr_raw: { amount: 540 } });
  const out = await saveExpense(r.db, PROP, o, keyForPhoto('receipts/5/u.jpg'));
  assert(out.ok);
  assertEquals(r.calls[0].args.p_key, 'tgocr:receipts/5/u.jpg');
  assertEquals(r.calls[0].args.p_txn.status, 'pending_review');
  assertEquals(r.calls[0].args.p_txn.receipt_image_path, 'receipts/5/u.jpg');
});

Deno.test('look-alike: one extra line with the date and the short reference of the new row', async () => {
  const r = rig();
  const out = await saveExpense(r.db, PROP, txn({ amount: 1250 }), 'k1');
  assert(out.ok);
  if (out.ok) assertEquals(lookalikeLine(out.lookalike, '5EB836FA'), 'Looks like Stock bought 21 Nov. If it is the same purchase: /void 5EB836FA');
  assertEquals(lookalikeLine({ id: 'x', date: '2026-11-03', chip: 'manual' }, 'AB12CD34'), 'Looks like An expense logged 3 Nov. If it is the same purchase: /void AB12CD34');
  assertEquals(lookalikeLine(null, 'AB12CD34'), null);
  assertEquals(lookalikeLine({ chip: 'stock' }, 'AB12CD34'), 'Looks like Stock bought. If it is the same purchase: /void AB12CD34');
  const plain = await saveExpense(r.db, PROP, txn(), 'k2');
  assert(plain.ok && plain.lookalike === null, 'no look-alike, no line');
  assertEquals([shortDate('2026-12-09'), shortDate('nope'), shortDate('2026-13-01')], ['9 Dec', null, null]);
});

Deno.test('void: reason and actor go to the RPC, no note is sent (the RPC keeps the row note), the action is void', async () => {
  const r = rig({ rows: { a: { status: 'confirmed' } } });
  const out = await voidExpense(r.db, 'a', 'Voided via /void', 'Lloyd 1');
  assert(out.ok);
  assertEquals(r.calls[0], { fn: 'telegram_expense_review_v1', args: { p_id: 'a', p_action: 'void', p_payload: { reason: 'Voided via /void' }, p_actor: 'Lloyd 1' } });
  assertFalse('notes' in r.calls[0].args.p_payload);
});

Deno.test('void: a bill or staff-pay row answers where it is undone, and nothing else', async () => {
  const r = rig({ rows: { b: { status: 'confirmed', locked: 'bills' }, p: { status: 'confirmed', locked: 'pay' } } });
  const b = await voidExpense(r.db, 'b', 'x y z', 'A');
  const p = await voidExpense(r.db, 'p', 'x y z', 'A');
  assert(!b.ok && !p.ok);
  if (!b.ok && !p.ok) {
    assertEquals(b.message, 'That one is undone in the app: Bills');
    assertEquals(p.message, 'That one is undone in the app: Pay staff');
    assertEquals([b.error, b.where, p.where], ['locked', 'bills', 'pay']);
  }
  assertEquals(reviewRefusal('locked'), 'That one is undone in the app: Bills / Pay staff');
});

Deno.test('confirm: sends confirm with an empty payload; a row that is no longer pending is refused in plain words', async () => {
  const r = rig({ rows: { a: { status: 'pending_review' }, c: { status: 'confirmed' } } });
  assert((await confirmExpense(r.db, 'a', 'Lloyd 1')).ok);
  assertEquals(r.calls[0].args, { p_id: 'a', p_action: 'confirm', p_payload: {}, p_actor: 'Lloyd 1' });
  const late = await confirmExpense(r.db, 'c', 'Lloyd 1');
  assert(!late.ok);
  if (!late.ok) assertEquals(late.message, 'That receipt is no longer waiting for review.');
});

Deno.test('receipt total edit goes through the review RPC with the amount, not a table update', async () => {
  const r = rig({ rows: { a: { status: 'pending_review' } } });
  assert((await setExpenseAmount(r.db, 'a', 1706.5, 'Lloyd 1')).ok);
  assertEquals(r.calls[0], { fn: 'telegram_expense_review_v1', args: { p_id: 'a', p_action: 'amount', p_payload: { amount: 1706.5 }, p_actor: 'Lloyd 1' } });
  assertEquals(r.calls.length, 1);
});

Deno.test('review: a thrown RPC and an RPC error come back as not-done, never as success', async () => {
  assertFalse((await reviewExpense(rig({ throwOn: 'telegram_expense_review_v1' }).db, 'a', 'void', { reason: 'abc' }, 'x')).ok);
  assertFalse((await reviewExpense({ rpc: () => Promise.resolve({ data: null, error: { message: 'down' } }) }, 'a', 'confirm', {}, 'x')).ok);
  assertFalse((await reviewExpense({ rpc: () => Promise.resolve({ data: null, error: null }) }, 'a', 'confirm', {}, 'x')).ok);
});

Deno.test('voidMany: counts the rows that went through and keeps the first refusal', async () => {
  const r = rig({ rows: { a: { status: 'confirmed' }, b: { status: 'confirmed', locked: 'bills' }, c: { status: 'confirmed' } } });
  const out = await voidMany(r.db, ['a', 'b', 'c'], 'Voided via Telegram NL', 'Lloyd 1');
  assertEquals([out.done, out.total, out.firstFailure], [2, 3, 'That one is undone in the app: Bills']);
  assertEquals((await voidMany(r.db, [], 'abc', 'x')).total, 0);
});

Deno.test('keyboard: built from the list given, two a row, no system slug, callback data cat:<slug>:<pre>', () => {
  const live = [{ slug: 'supplies', label: 'Supplies' }, { slug: 'guest_refund', label: 'Guest refund' }, { slug: 'loan', label: 'Loan' }, { slug: 'airbnb_adjustment', label: 'Airbnb adjustment' }, { slug: 'other', label: 'Other' }];
  assertEquals(pickableCategories(live).map((c) => c.slug), ['supplies', 'loan', 'other']);
  const kb = categoryKeyboardFrom(live, 540);
  const flat = kb.inline_keyboard.flat();
  assertEquals(flat.map((b) => b.callback_data), ['cat:supplies:540', 'cat:loan:540', 'cat:other:540']);
  assertEquals(kb.inline_keyboard.map((r) => r.length), [2, 1]);
  assertEquals(flat[1].text, 'Loan', 'a slug with no icon shows its label alone');
  assertEquals(flat[0].text, '\u{1F6D2} Supplies');
  for (const s of SYSTEM_SLUGS) assertFalse(flat.some((b) => b.callback_data.includes(s)));
  assertEquals(categoryKeyboardFrom([], 0).inline_keyboard.flat().length, FALLBACK_CATEGORIES.length, 'an unreadable list falls back to the seven');
});

Deno.test('OCR prompt list: the live slugs minus the system ones, odd slugs dropped, fallback when empty', () => {
  assertEquals(categoryUnion(['supplies', 'guest_refund', 'Bad Slug', 'loan']), '"supplies"|"loan"');
  assertEquals(categoryUnion([]), '"supplies"|"utilities"|"cleaning"|"maintenance"|"repairs"|"platform_fees"|"other"');
});

Deno.test('index.ts: no direct transactions write is left except the cleaner fee, the refund and the OCR line items', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  const writes: string[] = [];
  for (const m of src.matchAll(/from\('transactions'\)\s*\.(\w+)/g)) {
    if (m[1] === 'select') continue;
    const tail = src.slice(m.index!, m.index! + 700);
    writes.push(tail.includes("source:'cleaner_fee'") ? 'cleaner_fee' : tail.includes("category:         'guest_refund'") ? 'refund' : 'OTHER:' + tail.slice(0, 80));
  }
  assertEquals(writes.filter((f) => f.startsWith('OTHER')), [], 'every other write goes through the RPCs');
  assertEquals([...writes].sort(), ['cleaner_fee', 'refund']); // s134 fix r1: the line-items update moved to writeLineItems (expense-write.ts), which guards on status
  assertFalse(/status:'void'|status:'confirmed',updated_at|gross_amount:amount,updated_at/.test(src), 'no table update of status or amount remains');
  assertStringIncludes(src, "from './expense-write.ts'");
  assertFalse(/\bcategoryKeyboard\(\s*[0-9a-z]+\s*\)/.test(src.replace(/categoryKeyboard\(db,/g, '')), 'every keyboard call passes the db');
});

Deno.test('expense-write.ts: its only direct transactions write is the status-guarded line-items update', async () => {
  const src = await Deno.readTextFile(new URL('./expense-write.ts', import.meta.url));
  const writes = [...src.matchAll(/from\('transactions'\)\s*\.(\w+)/g)].filter((m) => m[1] !== 'select');
  assertEquals(writes.length, 1, 'exactly one direct write');
  assertEquals(writes[0][1], 'update');
  assertStringIncludes(src.slice(writes[0].index!, writes[0].index! + 200), ".eq('status', 'pending_review')");
});

Deno.test('index.ts wiring: keys per flow, the look-alike line, review calls, and the replay does not notify twice', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'key:keyForMessage(chatId,msg.message_id)');
  assertEquals(src.split('key:keyForMessage(chatId,msg.message_id)').length - 1, 2, 'the fast-entry text and the answered prompt');
  assertStringIncludes(src, "key:keyForPending(data.slice('dup_ok:'.length))");
  assertStringIncludes(src, "key:keyForPending(data.slice('llm_expense_confirm:'.length))");
  assertStringIncludes(src, 'keyForPhoto(objectPath,again)');
  assertStringIncludes(src, "'Voided via /void'");
  assertStringIncludes(src, "'Discarded via Telegram'");
  assertStringIncludes(src, 'confirmExpense(db,txnId,whoFrom(cq.from))');
  assertStringIncludes(src, 'setExpenseAmount(db,String(p.txnId),amount,loggedBy)');
  assertStringIncludes(src, 'if(!r.replayed)notifyOps(');
  assertEquals(src.split('row.id,row.look)').length - 1, 3, 'all three confirmations carry the look-alike line');
  assert(src.includes('Looks like') === false, 'the sentence itself lives in expense-write.ts');
});

// ---- s134 fix round 1 ----

// A table of rows that honours eq / limit / update / maybeSingle, so the status guards are exercised for real.
function table(rows: Array<Record<string, any>>) {
  return {
    from: (_t: string) => {
      const filters: Array<[string, unknown]> = [];
      let patch: Record<string, unknown> | null = null;
      const match = () => rows.filter((r) => filters.every(([c, v]) => r[c] === v));
      // deno-lint-ignore no-explicit-any
      const b: any = {
        select: () => b, limit: () => b,
        eq: (c: string, v: unknown) => { filters.push([c, v]); return b; },
        update: (p: Record<string, unknown>) => { patch = p; return b; },
        maybeSingle: () => Promise.resolve({ data: match()[0] ?? null, error: null }),
        then: (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) => {
          if (patch) { for (const r of match()) Object.assign(r, patch); return Promise.resolve({ error: null }).then(res, rej); }
          return Promise.resolve({ data: match(), error: null }).then(res, rej);
        },
      };
      return b;
    },
  };
}

Deno.test('fix r1 (1): a photo sent again after its receipt was discarded gets a new key, so a new pending row and card appear', async () => {
  const path = 'receipts/-100/AgADu1.jpg';
  const voided = table([{ id: 'old', receipt_image_path: path, status: 'void' }]);
  const again = await againForVoidedPhoto(voided, path, 4412);
  assertEquals(again, 'm4412');
  assert(keyForPhoto(path, again) !== keyForPhoto(path, null), 'a different key from the voided first pass');
  assertEquals(keyForPhoto(path, again), keyForPhoto(path, await againForVoidedPhoto(voided, path, 4412)), 'a webhook retry of the same message keeps the same key');
  // the real save: the first key replays, the new key makes a new row
  const r = rig();
  const first = await saveExpense(r.db, PROP, txn({ amount: 100 }), keyForPhoto(path, null));
  const resendOld = await saveExpense(r.db, PROP, txn({ amount: 100 }), keyForPhoto(path, null));
  const resend = await saveExpense(r.db, PROP, txn({ amount: 100 }), keyForPhoto(path, again));
  assert(first.ok && resendOld.ok && resend.ok);
  if (first.ok && resendOld.ok && resend.ok) {
    assertEquals([resendOld.replayed, resendOld.id === first.id], [true, true]);
    assertEquals([resend.replayed, resend.id === first.id], [false, false]);
  }
  // no void row holds the path (a first send, or a live row): the plain key is kept
  assertEquals(await againForVoidedPhoto(table([{ id: 'x', receipt_image_path: path, status: 'pending_review' }]), path, 4412), null);
  assertEquals(await againForVoidedPhoto(table([]), path, 4412), null);
  assertEquals(await againForVoidedPhoto(voided, path, null), null);
});

Deno.test('fix r1 (1): a replay of a row that is no longer waiting sends one plain line, never silence; a waiting row still gets its card', async () => {
  const db = table([{ id: 'c1', status: 'confirmed' }, { id: 'p1', status: 'pending_review' }, { id: 'v1', status: 'void' }]);
  const out: string[] = [], cards: string[] = [];
  const deps = {
    loadPending: async (id: string) => (await db.from('transactions').select('id').eq('id', id).eq('status', 'pending_review').maybeSingle()).data,
    sendCard: async (id: string) => { cards.push(id); }, send: async (t: string) => { out.push(t); },
  };
  await onReplayedReceipt(db, 'c1', 'C1REF', deps);
  await onReplayedReceipt(db, 'v1', 'V1REF', deps);
  await onReplayedReceipt(db, 'p1', 'P1REF', deps);
  assertEquals(out, ['That receipt was already logged as Ref C1REF and is now confirmed.', 'That receipt was already logged as Ref V1REF and is now void.']);
  assertEquals(cards, ['p1']);
});

Deno.test('fix r1 (1): index.ts wires the resend key and the replay line into the photo path and runOcr', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'againForVoidedPhoto(db,objectPath,msg.message_id)');
  assertStringIncludes(src, 'msg.caption?String(msg.caption).trim():null,cat,again)');
  assertStringIncludes(src, 'onReplayedReceipt(db,txnId,shortRef(txnId)');
});

Deno.test('fix r1 (2): line items change only on a row still pending review; a confirmed row is left alone', async () => {
  const rows = [
    { id: 'p', status: 'pending_review', ocr_raw: { line_items: [{ name: 'a' }], vendor: 'V' } },
    { id: 'c', status: 'confirmed', ocr_raw: { line_items: [{ name: 'a' }], vendor: 'V' } },
  ];
  const db = table(rows);
  await writeLineItems(db, 'p', rows[0].ocr_raw, [{ name: 'a' }, { name: 'b' }]);
  await writeLineItems(db, 'c', rows[1].ocr_raw, [{ name: 'a' }, { name: 'b' }]);
  assertEquals(rows[0].ocr_raw, { line_items: [{ name: 'a' }, { name: 'b' }], vendor: 'V' });
  assertEquals(rows[1].ocr_raw, { line_items: [{ name: 'a' }], vendor: 'V' });
  assertEquals((rows[1] as any).updated_at, undefined, 'the confirmed row was not touched at all');
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'await writeLineItems(db,txnId,ocrRaw,items)');
});
