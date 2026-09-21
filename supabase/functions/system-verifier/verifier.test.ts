// deno test --no-check --allow-env supabase/functions/system-verifier/verifier.test.ts
//
// The cards, read the way a person reads them. A verifier that finds the right
// things and then says them badly at 07:45 has not helped anybody, so these
// assert the text: what happened first, the facts a person needs next, one Do,
// ids last, and never five separate interruptions where one list would do.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { ackHash, ago, buildCards, dm, redCard, yellowCard, type Finding, type Resolved } from './cards.ts';
import { templateOf } from '../_shared/cascade-core/format.ts';

const NOW = new Date('2026-10-10T02:00:00Z');
const TODAY = '10 Oct';

const f = (over: Partial<Finding> & Pick<Finding, 'key' | 'check_id' | 'severity' | 'title'>): Finding =>
  ({ detail: {}, ...over });

const OVERLAP = f({
  key: 'V1:aaaaaaaa-0000-4000-8000-000000000001:bbbbbbbb-0000-4000-8000-000000000002',
  check_id: 'V1', severity: 'red', title: 'Two stays overlap',
  detail: {
    a: { id: 'aaaaaaaa-0000-4000-8000-000000000001', source: 'airbnb', guest: 'Ana Reyes', from: '2026-10-20', to: '2026-10-22', status: 'confirmed' },
    b: { id: 'bbbbbbbb-0000-4000-8000-000000000002', source: 'direct', guest: 'Ben Cruz', from: '2026-10-21', to: '2026-10-24', status: 'confirmed' },
  },
});

Deno.test('dates read the way a person says them', () => {
  assertEquals(dm('2026-10-21'), '21 Oct');
  assertEquals(dm('2026-01-01T00:00:00Z'), '1 Jan');
  assertEquals(dm(null), '');
});

Deno.test('ago rounds to the unit a person would use', () => {
  assertEquals(ago('2026-10-10T01:30:00Z', NOW), 'less than an hour ago');
  assertEquals(ago('2026-10-09T20:00:00Z', NOW), '6 hours ago');
  assertEquals(ago('2026-10-03T02:00:00Z', NOW), '7 days ago');
  assertEquals(ago(null, NOW), 'some time ago');
});

Deno.test('the overlap card names both guests, both sources and both sets of dates', () => {
  const c = redCard(OVERLAP, NOW);
  assertEquals(c.to, 'finance');
  assertEquals(c.ackKey, OVERLAP.key);
  assertStringIncludes(c.text, 'Two stays are booked over the same nights');
  assertStringIncludes(c.text, 'Ana Reyes · airbnb · 20 Oct to 22 Oct');
  assertStringIncludes(c.text, 'Ben Cruz · direct · 21 Oct to 24 Oct');
  // Not 'Do: open the calendar'. This card carries a sendable line, and that
  // line owns the card's single Do - see 'every card asks for exactly one thing'.
  assertStringIncludes(c.text, 'Open the calendar, decide which stay is real, and cancel the other.');
});

Deno.test('the overlap card carries a sendable line, and it promises nothing it cannot keep', () => {
  const text = redCard(OVERLAP, NOW).text;
  assertStringIncludes(text, '📨 ');
  const sample = templateOf(text);
  assertStringIncludes(sample, 'Ana');
  // The line must never tell a guest their booking is cancelled: which of the
  // two stays is the real one is precisely what nobody knows yet.
  assert(!/cancel|cancelled|unavailable|double.?book/i.test(sample), `the sample line pre-judges the outcome: ${sample}`);
  assert(!sample.includes('!'), 'Cassy never exclaims');
});

Deno.test('ids come last, never first', () => {
  const lines = redCard(OVERLAP, NOW).text.split('\n').filter((l) => l.trim());
  const firstId = lines.findIndex((l) => l.startsWith('ids '));
  const firstGuest = lines.findIndex((l) => l.includes('Ana Reyes'));
  assert(firstGuest >= 0 && firstId > firstGuest, 'the guests must be named before the ids');
});

Deno.test('one red finding is one card, and four yellows are one list', () => {
  const yellows: Finding[] = ['V3', 'V4', 'V5', 'V11'].map((id, i) =>
    f({ key: `${id}:${i}`, check_id: id, severity: 'yellow', title: `${id} thing`, detail: { guest: `Guest ${i}`, since: '2026-10-09T02:00:00Z' } }));
  const cards = buildCards({ new: [OVERLAP, ...yellows], remind: [], resolved: [] }, NOW, TODAY);
  assertEquals(cards.length, 2, 'one alert for the red, one attention card for the four yellows');
  assertStringIncludes(cards[1].text, '4 things are worth a look.');
  assertEquals(cards[1].ackKey, undefined, 'a card holding four findings has nothing single to acknowledge');
});

Deno.test('more than five yellows say how many are not shown', () => {
  const many: Finding[] = Array.from({ length: 7 }, (_, i) =>
    f({ key: `V5:${i}`, check_id: 'V5', severity: 'yellow', title: 'Guest handoff open over 12 hours', detail: { guest: `Guest ${i}`, since: '2026-10-09T02:00:00Z' } }));
  const card = yellowCard(many, [], 'finance', NOW, TODAY)!;
  const bullets = card.text.split('\n').filter((l) => l.startsWith('• '));
  assertEquals(bullets.length, 5, 'five bullets, never seven');
  assertStringIncludes(bullets[4], 'and 3 more in the dashboard');
});

Deno.test('a lone yellow gets its own sentence and its own Do, not a list of one', () => {
  const one = f({ key: 'V11', check_id: 'V11', severity: 'yellow', title: 'Concierge is not on auto', detail: { mode: 'suggest', since: '2026-10-09T20:00:00Z' } });
  const card = yellowCard([one], [], 'finance', NOW, TODAY)!;
  assertStringIncludes(card.text, 'The Concierge has been on suggest since 6 hours ago');
  assertEquals(card.text.split('\n').filter((l) => l.startsWith('• ')).length, 0);
  assertStringIncludes(card.text, 'Do: put the Concierge back on auto');
  assertEquals(card.ackKey, 'V11', 'one finding, one thing to acknowledge');
});

Deno.test('resolved findings are a footer, never a card of their own', () => {
  const resolved: Resolved[] = [
    { key: 'V3:x', title: 'Calendar hold with no live booking behind it', auto: true },
    { key: 'V5:y', title: 'Guest handoff open over 12 hours' },
  ];
  const cards = buildCards({ new: [], remind: [], resolved }, NOW, TODAY);
  assertEquals(cards.length, 1);
  assertStringIncludes(cards[0].text, 'Nothing needs you. These closed themselves.');
  assertStringIncludes(cards[0].text, 'Resolved: Calendar hold with no live booking behind it (closed itself); Guest handoff open over 12 hours');
});

Deno.test('a quiet run says nothing at all', () => {
  assertEquals(buildCards({ new: [], remind: [], resolved: [] }, NOW, TODAY).length, 0);
  assertEquals(buildCards({}, NOW, TODAY).length, 0);
});

Deno.test('a reminder is said as fully as the first time', () => {
  const cards = buildCards({ new: [], remind: [OVERLAP], resolved: [] }, NOW, TODAY);
  assertEquals(cards.length, 1);
  assertStringIncludes(cards[0].text, 'Ana Reyes');
});

Deno.test('V6 goes to OPS and the money findings do not follow it there', () => {
  const v6 = f({ key: 'V6:1', check_id: 'V6', severity: 'yellow', title: 'Arriving soon with no ID on file', detail: { booking: 'cccccccc-0000-4000-8000-000000000003', guest: 'Cara Lim', arrives: '2026-10-12' } });
  const v11 = f({ key: 'V11', check_id: 'V11', severity: 'yellow', title: 'Concierge is not on auto', detail: { mode: 'suggest', since: '2026-10-09T20:00:00Z' } });
  const cards = buildCards({ new: [v6, v11], remind: [], resolved: [{ key: 'V3:x', title: 'A hold' }] }, NOW, TODAY);
  const ops = cards.filter((c) => c.to === 'ops');
  const fin = cards.filter((c) => c.to === 'finance');
  assertEquals(ops.length, 1);
  assertEquals(fin.length, 1);
  assertStringIncludes(ops[0].text, 'Cara Lim arrives 12 Oct');
  assert(!ops[0].text.includes('Concierge'), 'OPS does not get the Concierge finding');
  assert(!ops[0].text.includes('Resolved:'), 'resolutions ride with Finance only');
  assertStringIncludes(fin[0].text, 'Resolved: A hold');
});

// The first live run, 2026-09-21 23:45Z, said this at Lloyd:
//   "ALERT · inventory quantities agree with movements"
// A health check's label is its PASSING assertion, so reusing it as an alert
// subject announces the opposite of what is wrong. These pin the fix.
Deno.test('a V10 card states the PROBLEM, never the check\'s pass-phrased label', () => {
  const failed = f({
    key: 'V10:inventory_ledger_consistent', check_id: 'V10', severity: 'red',
    title: 'Inventory quantities agree with movements',
    detail: { check: 'inventory_ledger_consistent', status: 'fail', n: 1, ran_at: '2026-10-10T01:00:00Z',
              d: [{ item: 'Liquid Hand Soap (Safeguard)', onHand: 1, lastMovement: 0 }] },
  });
  const card = redCard(failed, NOW);
  assert(!card.text.includes('quantities agree with movements'),
    `the pass-phrased label reached the card and reads as good news:\n${card.text}`);
  assertStringIncludes(card.text, '1 inventory item disagrees with its own last stock movement.');
  // and it names the row, so somebody can act without opening the dashboard
  assertStringIncludes(card.text, 'Liquid Hand Soap (Safeguard): counted 1, last movement said 0');
});

Deno.test('a V10 card names the rows behind the number', () => {
  const checkouts = f({
    key: 'V10:checkouts_cleaned', check_id: 'V10', severity: 'red', title: 'Checkouts (90 days) followed by a cleaning',
    detail: { check: 'checkouts_cleaned', status: 'fail', n: 2, d: [
      { code: 'HMYKNFRCFJ', guest: 'Nyke Perez', checkout: '2026-09-20' },
      { code: 'HM538AA4C4', guest: 'Bianca Dizon', checkout: '2026-08-24' }] },
  });
  const text = redCard(checkouts, NOW).text;
  assertStringIncludes(text, '2 checkouts in the last 90 days have no cleaning logged.');
  assertStringIncludes(text, 'Nyke Perez checked out 20 Sep');
  assert(!text.includes('HMYKNFRCFJ'), 'a confirmation code is an id, not something a person needs on a card');
});

// The first attempt at the fix read the amount off the WRONG level of the
// detail and printed a confident "disagree by PHP 0.00" - worse than saying
// nothing, because it claims the books balance when they do not.
Deno.test('the scalar checks print their real amount, never zero', () => {
  const totals = f({
    key: 'V10:payout_totals_agree', check_id: 'V10', severity: 'yellow', title: 'Reservation payouts equal payout e-mails plus adjustments',
    detail: { check: 'payout_totals_agree', status: 'warn', n: 0,
              d: { difference: 2590.78, adjustments: 3568.24, payoutEmails: 351199.65, reservationPayouts: 357358.67 } },
  });
  const cash = f({
    key: 'V10:ledger_position', check_id: 'V10', severity: 'yellow', title: 'Cash position',
    detail: { check: 'ledger_position', status: 'warn', n: 0,
              d: { net: 7704.52, income: 352979.65, drawings: 93159.60, expenses: 252115.53 } },
  });
  const text = yellowCard([totals, cash], [], 'finance', NOW, TODAY)!.text;
  assertStringIncludes(text, 'disagree by ₱2,590.78');
  assertStringIncludes(text, '₱7,704.52 unaccounted');
  assert(!text.includes('₱0.00'), `a zero amount on a card that exists BECAUSE the number is not zero:\n${text}`);
  assert(!text.includes('0 to look at'), 'these checks count nothing; their signal is the amount');
});

Deno.test('the accepted K16 finding still explains itself', () => {
  const accepted = f({
    key: 'V10:ledger_duplicates', check_id: 'V10', severity: 'yellow', title: 'Duplicate ledger rows',
    detail: { check: 'ledger_duplicates', status: 'warn', n: 2, accepted: true, ran_at: '2026-10-10T01:00:00Z',
              d: [{ n: 3, date: '2026-06-25', payee: 'Honey', amount: 650 }] },
  });
  const text = yellowCard([accepted], [], 'finance', NOW, TODAY)!.text;
  assertStringIncludes(text, '2 sets of duplicate ledger rows.');
  assertStringIncludes(text, 'gone through on 14 Sep');
});

Deno.test('V10:stale says the numbers are old rather than repeating them as news', () => {
  const stale = f({ key: 'V10:stale', check_id: 'V10', severity: 'yellow', title: 'System health has not been run', detail: { last_run: '2026-10-03T02:00:00Z' } });
  const card = yellowCard([stale], [], 'finance', NOW, TODAY)!;
  assertStringIncludes(card.text, 'System health last ran 7 days ago');
  assertStringIncludes(card.text, 'Do: open Settings, System health, and run it.');
});

Deno.test('the ack hash fits a Telegram callback and survives the longest key there is', async () => {
  const h = await ackHash(OVERLAP.key);
  assertEquals(h.length, 16);
  assert(/^[0-9a-f]{16}$/.test(h));
  assert(new TextEncoder().encode(`vf:ack:${h}`).length <= 64, 'callback data must fit 64 bytes');
  assertEquals(h, await ackHash(OVERLAP.key), 'the same key always hashes the same way');
  assert(h !== await ackHash('V11'), 'different keys do not collide into one button');
});

Deno.test('every card asks for exactly one thing', () => {
  const v10 = f({ key: 'V10:payout_rows_linked', check_id: 'V10', severity: 'red', title: 'Payout e-mails linked to a stay', detail: { check: 'payout_rows_linked', status: 'fail', n: 1 } });
  const v6 = f({ key: 'V6:1', check_id: 'V6', severity: 'yellow', title: 'Arriving soon with no ID on file', detail: { guest: 'Cara Lim', arrives: '2026-10-12' } });
  for (const c of buildCards({ new: [OVERLAP, v10, v6], remind: [], resolved: [] }, NOW, TODAY)) {
    const dos = c.text.split('\n').filter((l) => l.startsWith('Do:'));
    assertEquals(dos.length, 1, `a card with ${dos.length} Do lines is a card with ${dos.length} instructions:
${c.text}`);
  }
});

Deno.test('a V10 card never prints its raw check key at a person', () => {
  const v10 = f({ key: 'V10:payout_rows_linked', check_id: 'V10', severity: 'red', title: 'Payout e-mails linked to a stay', detail: { check: 'payout_rows_linked', status: 'fail', n: 1 } });
  const text = redCard(v10, NOW).text;
  assert(!/^check /m.test(text), `a key=value line reached the card:
${text}`);
  assert(!text.includes('payout_rows_linked'), `the raw check key reached the card:
${text}`);
  assertStringIncludes(text, '1 payout e-mail is not linked to a stay.');
});

Deno.test('a list of V10 bullets does not repeat System health on every line', () => {
  const many: Finding[] = ['a', 'b', 'c'].map((k, i) =>
    f({ key: `V10:${k}`, check_id: 'V10', severity: 'yellow', title: `Check ${k}`, detail: { check: k, status: 'warn', n: i } }));
  const bullets = yellowCard(many, [], 'finance', NOW, TODAY)!.text.split('\n').filter((l) => l.startsWith('• '));
  assertEquals(bullets.length, 3);
  for (const b of bullets) assert(!b.includes('System health:'), `the shared prefix survived into a bullet: ${b}`);
});

Deno.test('no card shouts', () => {
  const cards = buildCards({ new: [OVERLAP], remind: [], resolved: [] }, NOW, TODAY);
  for (const c of cards) {
    assert(!/[a-z]!/i.test(c.text), `an exclamation crept into a card: ${c.text}`);
    assert(!/\b(URGENT|ASAP|IMMEDIATELY)\b/.test(c.text), 'cards state what happened; they do not shout');
  }
});
