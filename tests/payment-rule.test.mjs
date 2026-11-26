import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

/* s138 payment rule (D-428, D-429, D-430): every direct stay is paid in full to confirm; a separate refundable deposit;
   28 nights or more is arranged with the host. These tests pin the wording and the figures across the surfaces of this repo. */
const read = (f) => readFile(new URL(`../${f}`, import.meta.url), 'utf8');
const [index, terms, stay] = await Promise.all([read('index.html'), read('booking-terms.html'), read('stay.html')]);

const ENT = { mdash: '—', ndash: '–', rsquo: '’', lsquo: '‘', ldquo: '“', rdquo: '”', hellip: '…', amp: '&', middot: '·', nbsp: ' ', rarr: '→', larr: '←' };
const decode = (x) => x.replace(/&#x([0-9a-f]+);/gi, (m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (m, d) => String.fromCodePoint(+d)).replace(/&([a-z]+);/gi, (m, n) => ENT[n] ?? m);
const plain = (h) => decode(h.replace(/<script[\s\S]*?<\/script>/g, ' ').replace(/<style[\s\S]*?<\/style>/g, ' ').replace(/<!--[\s\S]*?-->/g, ' ').replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();

const ruleBlock = index.match(/<script id="pay-rule">([\s\S]*?)<\/script>/)[1];
const num = (k) => Number(ruleBlock.match(new RegExp(String.raw`${k}:\s*(\d+)`))[1]);
const DEPOSIT = num('SECURITY_DEPOSIT_PHP'), RETURN_DAYS = num('DEPOSIT_RETURN_BUSINESS_DAYS'), LONG = num('LONG_STAY_NIGHTS');
const RETURN_LINE = `returned as soon as possible, within ${RETURN_DAYS} business days of check-out, to the same account or payment mode it came from`;

test('the figures live in one constant each, and the guest wording states the same figures', () => {
  assert.equal(DEPOSIT, 800); assert.equal(RETURN_DAYS, 3); assert.equal(LONG, 28);
  assert.equal((index.match(/SECURITY_DEPOSIT_PHP\s*:/g) || []).length, 1);
  assert.equal((index.match(/DEPOSIT_RETURN_BUSINESS_DAYS\s*:/g) || []).length, 1);
  const peso = `₱${DEPOSIT}`;
  assert.ok(plain(terms).includes(`security deposit of ${peso}`), 'booking-terms.html names the deposit amount');
  assert.ok(plain(stay.slice(stay.indexOf('id="stPolicy"'))).includes(`security deposit of ${peso}`), 'stay.html names the deposit amount');
  const sheet = plain(index.slice(index.indexOf('id="bsDepLine"'), index.indexOf('id="bsDepLine"') + 700));
  assert.ok(sheet.includes(peso) && sheet.includes(RETURN_LINE), 'the sheet default deposit line');
  for (const [name, text] of [['index.html', plain(index)], ['booking-terms.html', plain(terms)], ['stay.html', plain(stay)]]) {
    assert.ok(text.includes(RETURN_LINE), `${name} states the return wording`);
  }
  const ld = index.match(/<script type="application\/ld\+json">[\s\S]*?<\/script>/g).join('');
  assert.ok(ld.includes(RETURN_LINE), 'the JSON-LD twin states the return wording');
  assert.ok(plain(terms).includes(`${LONG} nights or more are arranged with the host`));
});

test('the FAQ answers on payment and cancellation equal their JSON-LD twins word for word', () => {
  const blocks = [...index.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => JSON.parse(m[1]));
  const faq = blocks.find((b) => b['@type'] === 'FAQPage');
  assert.ok(faq, 'FAQPage JSON-LD');
  const section = plain(index.slice(index.indexOf('class="faq-section"'), index.indexOf('</section>', index.indexOf('class="faq-section"'))));
  for (const q of ['How do I confirm my booking?', 'What is the cancellation policy?']) {
    const item = faq.mainEntity.find((x) => x.name === q);
    assert.ok(item, `JSON-LD has "${q}"`);
    const answer = item.acceptedAnswer.text.replace(/\s+/g, ' ').trim();
    assert.ok(section.includes(q), `the FAQ shows "${q}"`);
    assert.ok(section.includes(answer), `the on-page answer to "${q}" differs from its JSON-LD twin`);
  }
  const cancel = faq.mainEntity.find((x) => x.name === 'What is the cancellation policy?').acceptedAnswer.text;
  assert.match(cancel, /Free cancellation until 5 days before check-in/);
  assert.match(cancel, /we keep 50% of the stay/);
  assert.match(cancel, /within 3 business days/);
  const confirm = faq.mainEntity.find((x) => x.name === 'How do I confirm my booking?').acceptedAnswer.text;
  assert.match(confirm, /paid in full to confirm/);
  assert.match(confirm, /Stays of 28 nights or more are arranged with the host/);
});

test('the old rule is gone from guest-facing text and from the page logic', () => {
  const OLD = /reservation fee|1,000|remaining balance|balance due|pay in full|last-minute|handed over on arrival|50% reservation/i;
  assert.doesNotMatch(plain(index), OLD);
  assert.doesNotMatch(plain(terms), OLD);
  assert.doesNotMatch(index.match(/<script type="application\/ld\+json">[\s\S]*?<\/script>/g).join(''), OLD);
  assert.doesNotMatch(index, /isLastMinute|last_minute|daysOut\s*<=\s*4|_payMode|payModeFull|applyPayFirst|lmBanner/);
  assert.doesNotMatch(index, /deposit_pct:\s*50\b/);
});

test('the booking sheet sends the stay total as the amount due and says pay_full on both the booking and the receipt', () => {
  assert.match(index, /total_amount: m\.total, deposit_amount: m\.total, pay_full: true/);
  assert.match(index, /'X-Receipt-Filename': f\.name, 'X-Pay-Full': 'true'/);
  assert.match(index, /deposit_amount: total,\s+\/\* the amount due to confirm = the stay total \*\/\s+pay_full:\s+true/);
});
