import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');

test('public HTML does not expose the exact lot address', () => {
  assert.doesNotMatch(html, /Block\s*47\s*,?\s*Lot\s*39/i);
});

test('public HTML does not claim instant confirmation', () => {
  assert.doesNotMatch(html, /instant confirmation|confirmed immediately|confirms? (?:your stay )?instantly|confirmed the moment we receive|secured when the 50% deposit clears|holds? your dates immediately|held the moment we receive|deposit to confirm|reservation fee holds your dates/i);
});

test('search metadata and the pre-booking FAQ do not publish payment account identifiers', () => {
  const jsonLd = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)]
    .map((match) => match[1])
    .join('\n');
  const faq = html.match(/<section[^>]+class="faq-section"[\s\S]*?<\/section>/i)?.[0] ?? '';
  const accountIdentifier = /0956\s*011\s*5744|1094\s*2361\s*1134|Marifel Suzanne B\./i;
  assert.ok(faq, 'FAQ section must be present');
  assert.doesNotMatch(jsonLd, accountIdentifier);
  assert.doesNotMatch(faq, accountIdentifier);
});

test('public HTML does not use unsupported luxury superlatives', () => {
  assert.doesNotMatch(html, /world-class|pinnacle of luxury|bespoke|iconic destinations|elevated stays/i);
});

test('guest contact is Messenger plus a call button; no WhatsApp links and the retired number is gone', () => {
  // Lloyd's brief: Messenger first, then call (tel from the one CONTACT object, fallback Honey +63 991 853 8269). Ms Jary's 09618056979 is retired.
  assert.doesNotMatch(html, /wa\.me|web\.whatsapp\.com|api\.whatsapp\.com|639618056979|0961 ?805 ?6979/);
  assert.match(html, /data-contact="tel" href="tel:\+639918538269"/);
  assert.match(html, /<!-- SITE-CHAT: in-app messaging entry point \(spec pending\) -->\s*<div id="siteChatEntry" hidden>/);
});

test('every direct communication route has a non-empty, full-domain destination', () => {
  assert.match(html, /https:\/\/www\.messenger\.com\/t\/699640026568720/);
  assert.doesNotMatch(html, /https:\/\/m\.me\//);
  assert.doesNotMatch(html, /href="#contact"\s+data-email=/);
  assert.match(html, /mailto:cascadereservations@gmail\.com\?subject=/);
});

test('privacy and terms are linked next to booking', () => {
  assert.match(html, /href="privacy\.html"/);
  assert.match(html, /href="booking-terms\.html"/);
});

test('same-origin Open Graph image is used', () => {
  assert.match(html, /property="og:image"[^>]+Stay_At_CascadeGSC\/og-image\.jpg/);
  assert.match(html, /name="twitter:image"[^>]+Stay_At_CascadeGSC\/og-image\.jpg/);
});

test('JSON-LD does not disclose a precise street address or coordinates', () => {
  assert.doesNotMatch(html, /"streetAddress"/);
  assert.doesNotMatch(html, /"geo"\s*:\s*{/);
});

test('Airbnb rating and review count come from the single RATING constant', () => {
  // Visible markup renders from RATING at runtime; JSON-LD (structured data) is updated in a later task, so it is excluded here.
  const visible = html.replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>/g, '');
  assert.match(visible, /const RATING = \{ score: 4\.97, count: 64, verifiedOn: '2026-11-23' \};/);
  assert.equal((visible.match(/const RATING\b/g) || []).length, 1);
  assert.doesNotMatch(visible, /\b4\.98\b/);
  assert.doesNotMatch(visible, /\b45\s+(Airbnb\s+)?[Rr]eviews\b/);
  assert.doesNotMatch(html, /\b34\s+(Airbnb\s+)?[Rr]eviews\b/);
  assert.doesNotMatch(html, /\b31\s+Guests\b/);
});

test('parking copy matches the reconciled Airbnb fact (shared roadside, not "secured")', () => {
  assert.doesNotMatch(html, /secured parking/i);
});

test('reserves a dated, non-live Airbnb proof fallback', () => {
  assert.match(html, /id="airbnbProofVerifiedNote">Verified on <span data-rating="verified">/);
  assert.match(html, /id="airbnbProofEmbed"/);
});

test('does not fetch or scrape airbnb.com from client code', () => {
  assert.doesNotMatch(html, /fetch\(['"`][^'"`]*airbnb\.com/i);
});

test('T8 SEO: JSON-LD rating matches RATING, FAQPage matches the visible FAQ exactly, meta description is short and price-free', () => {
  const named = { mdash: '\u2014', ndash: '\u2013', rsquo: '\u2019', lsquo: '\u2018', amp: '&', rarr: '\u2192', middot: '\u00B7', nbsp: ' ', hellip: '\u2026', ldquo: '\u201C', rdquo: '\u201D' };
  const clean = (x) => x.replace(/<[^>]+>/g, '').replace(/&#x([0-9a-f]+);/gi, (m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (m, d) => String.fromCodePoint(+d)).replace(/&([a-z]+);/gi, (m, n) => named[n] ?? m).replace(/\s+/g, ' ').trim();
  const rating = html.match(/const RATING = \{ score: ([\d.]+), count: (\d+)/);
  const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map(m => JSON.parse(m[1]));
  const lodging = blocks.find(b => b.aggregateRating);
  assert.equal(lodging.aggregateRating.ratingValue, rating[1]);
  assert.equal(lodging.aggregateRating.reviewCount, rating[2]);
  const faq = blocks.find(b => b['@type'] === 'FAQPage');
  const visible = [...html.matchAll(/<details class="faq-item[\s\S]*?<\/details>/g)].map(m => {
    const q = clean(m[0].match(/<summary>([\s\S]*?)<span class="faq-chevron"/)[1]);
    const a = [...m[0].matchAll(/<p class="faq-answer"[^>]*>([\s\S]*?)<\/p>/g)].map(x => clean(x[1])).join(' ');
    return { q, a };
  });
  const ratingSpans = (t) => t.replace(/\b4\.97\b/, 'SCORE');
  assert.equal(faq.mainEntity.length, visible.length);
  faq.mainEntity.forEach((e, i) => { assert.equal(e.name, visible[i].q); assert.equal(e.acceptedAnswer.text, visible[i].a, e.name); });
  assert.ok(ratingSpans(faq.mainEntity.map(e => e.acceptedAnswer.text).join(' ')).includes('SCORE'));
  const desc = html.match(/<meta name="description" content="([^"]*)"/)[1];
  assert.ok(desc.length <= 160, `description is ${desc.length} chars`);
  assert.doesNotMatch(desc, /[₱\d]/);
});

test('B111: the payment QR is never lazy-loaded', () => {
  const tag = html.match(/<img[^>]*id="bsQr"[^>]*>/)[0];
  assert.doesNotMatch(tag, /loading\s*=\s*["']?lazy/i);
});

function stripBalanced(src, openRe) {
  let out = src, m;
  while ((m = openRe.exec(out))) {
    const tag = m[1], re = new RegExp(`<(/?)${tag}\b[^>]*>`, 'g'); re.lastIndex = m.index; let depth = 0, end = out.length, t;
    while ((t = re.exec(out))) { depth += t[1] ? -1 : 1; if (depth === 0) { end = re.lastIndex; break; } }
    out = out.slice(0, m.index) + out.slice(end); openRe.lastIndex = 0;
  }
  return out;
}

test('marketing copy shows no peso price or percentage while SHOW_PRICE is false', () => {
  // [data-price-only] nodes are removed at runtime, the booking sheet is the payment flow, and #deskSidebar is a legacy node that stays `hidden`.
  assert.match(html, /const SHOW_PRICE = false;/);
  let marketing = html.replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '').replace(/<!--[\s\S]*?-->/g, '');
  marketing = stripBalanced(marketing, /<(dialog)\b[^>]*id="bookSheet"[^>]*>/);
  marketing = stripBalanced(marketing, /<(aside)\b[^>]*id="deskSidebar"[^>]*>/);
  marketing = stripBalanced(marketing, /<([a-z0-9]+)\b[^>]*data-price-only[^>]*>/);
  const text = marketing.replace(/<[^>]+>/g, ' ').replace(/&#x20B1;|&#8369;|&peso;/gi, '₱');
  assert.doesNotMatch(text, /₱\s?\d|\b\d{1,3}\s?%|\b1,?780\b/);
});
