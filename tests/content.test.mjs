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
  assert.match(visible, /const RATING = \{ score: 4\.97, count: 64, fiveStar: 97, verifiedOn: '2026-11-24' \};/);
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

test('T8 SEO: no self-serving aggregateRating in JSON-LD, FAQPage matches the visible FAQ exactly, meta description is short and price-free', () => {
  const named = { mdash: '\u2014', ndash: '\u2013', rsquo: '\u2019', lsquo: '\u2018', amp: '&', rarr: '\u2192', middot: '\u00B7', nbsp: ' ', hellip: '\u2026', ldquo: '\u201C', rdquo: '\u201D' };
  const clean = (x) => x.replace(/<[^>]+>/g, '').replace(/&#x([0-9a-f]+);/gi, (m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (m, d) => String.fromCodePoint(+d)).replace(/&([a-z]+);/gi, (m, n) => named[n] ?? m).replace(/\s+/g, ' ').trim();
  const rating = html.match(/const RATING = \{ score: ([\d.]+), count: (\d+)/);
  const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map(m => JSON.parse(m[1]));
  assert.ok(rating, 'the visible RATING constant stays');
  assert.equal(blocks.filter(b => b.aggregateRating).length, 0, 'JSON-LD carries no aggregateRating (the rating is on Airbnb, not reviewed on this site)');
  assert.ok(!html.includes('"aggregateRating"'));
  const faq = blocks.find(b => b['@type'] === 'FAQPage');
  const visible = [...html.matchAll(/<details class="faq-item[\s\S]*?<\/details>/g)].map(m => {
    const q = clean(m[0].match(/<summary>([\s\S]*?)<span class="faq-chevron"/)[1]);
    const a = [...m[0].matchAll(/<p class="faq-answer"[^>]*>([\s\S]*?)<\/p>/g)].map(x => clean(x[1])).join(' ');
    return { q, a };
  });
  const ratingSpans = (t) => t.replace(/\b4\.97\b/, 'SCORE');
  assert.equal(faq.mainEntity.length, visible.length);
  faq.mainEntity.forEach((e, i) => { assert.equal(e.name, visible[i].q); assert.equal(e.acceptedAnswer.text, visible[i].a, e.name); });
  const questions = faq.mainEntity.map(e => e.name);
  assert.equal(new Set(questions).size, questions.length);
  assert.ok(!/no codes, no negotiation needed\.[^]*no codes, no negotiation needed\./.test(faq.mainEntity.map(e => e.acceptedAnswer.text).join(' ')), 'no duplicated sentence in the last FAQ');
  assert.ok(ratingSpans(faq.mainEntity.map(e => e.acceptedAnswer.text).join(' ')).includes('SCORE'));
  const desc = html.match(/<meta name="description" content="([^"]*)"/)[1];
  assert.ok(desc.length <= 160, `description is ${desc.length} chars`);
  assert.doesNotMatch(desc, /[₱\d]/);
});

test('B111: the payment QR is never lazy-loaded', () => {
  const tag = html.match(/<img[^>]*id="bsQr"[^>]*>/)[0];
  assert.doesNotMatch(tag, /loading\s*=\s*["']?lazy/i);
});

const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
function stripBalanced(src, openRe) {
  let out = src, m;
  while ((m = openRe.exec(out))) {
    const tag = m[1].toLowerCase(); let end = m.index + m[0].length;
    if (!VOID.has(tag) && !/\/>$/.test(m[0])) {
      const re = new RegExp(String.raw`<(/?)${tag}\b[^>]*>`, 'gi'); re.lastIndex = m.index; let depth = 0, t; end = out.length;
      while ((t = re.exec(out))) { depth += t[1] ? -1 : 1; if (depth === 0) { end = re.lastIndex; break; } }
    }
    out = out.slice(0, m.index) + out.slice(end); openRe.lastIndex = 0;
  }
  return out;
}

test('marketing copy shows no peso price or percentage while SHOW_PRICE is false', () => {
  // [data-price-only] nodes are removed at runtime, the booking sheet is the payment flow, and every element carrying the `hidden` attribute (legacy #booking, #deskSidebar) never shows.
  assert.match(html, /const SHOW_PRICE = false;/);
  let marketing = html.replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '').replace(/<!--[\s\S]*?-->/g, '');
  marketing = stripBalanced(marketing, /<(dialog)\b[^>]*id="bookSheet"[^>]*>/);
  marketing = stripBalanced(marketing, /<([a-z0-9]+)\b(?:[^>"']|"[^"]*"|'[^']*')*?\shidden(?=[\s>/=])(?:[^>"']|"[^"]*"|'[^']*')*>/i);
  marketing = stripBalanced(marketing, /<([a-z0-9]+)\b[^>]*data-price-only[^>]*>/);
  marketing = marketing.replace(/<span data-rating="fiveStar">[^<]*<\/span>/g, ''); /* round D (D4): the review-share no-JS fallback is a rating, not a price; its value is pinned in the guest stories test */
  /* s138 (D-428): the cancellation answer's "we keep 50% of the stay" is the one policy percentage the page states; it is a cancellation term, not a price */
  const text = marketing.replace(/<[^>]+>/g, ' ').replace(/&#x20B1;|&#8369;|&peso;/gi, '₱').replace(/we keep 50% of the stay/g, 'we keep half of the stay');
  assert.doesNotMatch(text, /₱\s?\d|\b\d{1,3}\s?%|\b1,?780\b/);
});

/* Guest stories refresh (PLAN-refresh section 3 step 2, N5, N13, N14; Fable r6 "tests to add").
   Every guest quote on the page must be a contiguous excerpt of a dated review in tests/fixtures/reviews-verified.json
   (read from Airbnb 2026-11-24). Only curly/straight quotes, the ellipsis and whitespace are normalised; guest spelling stays exact.
   Two allowances: a heading quote may capitalise the first letter of a mid-sentence excerpt ("Super easy to locate"), and may end with
   a full stop where the source note cut the review right after the excerpt ("Check-in was a breeze ..."). */
const reviews = JSON.parse(await readFile(new URL('./fixtures/reviews-verified.json', import.meta.url), 'utf8'));
/* Quotes on the page before this release that are NOT in the 2026-11-24 read. Each one is an open item for Lloyd; the list must only shrink. */
const PENDING_VERIFICATION = [];
const ENT = { mdash: '—', ndash: '–', rsquo: '’', lsquo: '‘', ldquo: '“', rdquo: '”', hellip: '…', amp: '&', middot: '·', nbsp: ' ', rarr: '→' };
const decode = (x) => x.replace(/&#x([0-9a-f]+);/gi, (m, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (m, d) => String.fromCodePoint(+d)).replace(/&([a-z]+);/gi, (m, n) => ENT[n] ?? m);
const norm = (x) => x.replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/…|\.\.\./g, '…').replace(/\s+/g, ' ').trim();
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
/* Visible body markup only: no scripts, styles, comments or the booking-sheet dialog. Segments = text between tags. */
const bodyMarkup = html.slice(html.indexOf('<body')).replace(/<script[\s\S]*?<\/script>/g, '').replace(/<style[\s\S]*?<\/style>/g, '').replace(/<!--[\s\S]*?-->/g, '');
function guestQuotes() {
  const out = [];
  const flat = decode(bodyMarkup.replace(/<q\b[^>]*>/g, '“').replace(/<\/q>/g, '”').replace(/<(br|img)\b[^>]*>/g, ' ').replace(/<\/?(em|strong|i|b|span)\b[^>]*>/g, (t) => /^<\/?(em|i|b)\b/.test(t) ? '' : '\u0001').replace(/<[^>]+>/g, '\u0001'));
  for (const m of flat.matchAll(/“([^”\u0001]{3,300}(?:\u0001[^”\u0001]*)*)”/g)) {
    const quote = m[1].replace(/\u0001/g, ' ');
    const after = flat.slice(m.index + m[0].length).split('\u0001').map((s) => s.replace(/\s+/g, ' ').trim()).find((s) => s);
    out.push({ quote: quote.replace(/\s+/g, ' ').trim(), attribution: after || '' });
  }
  return out;
}

test('Guest stories: every on-page guest quote is an excerpt of a dated review in the 2026-11-24 fixture, attributed with its month', () => {
  const quotes = guestQuotes();
  assert.equal(quotes.length, 3, `found ${quotes.length} quotes; the invitation redesign (D2) allows exactly three: hero, between chapters, beside the booking card`);
  const pendingSeen = [];
  for (const { quote, attribution } of quotes) {
    if (PENDING_VERIFICATION.includes(quote)) { pendingSeen.push(quote); continue; }
    const core = norm(quote).replace(/^…\s*/, '').replace(/\s*…$/, '');
    const forms = [core, core[0].toLowerCase() + core.slice(1)];
    /* the source note cut the review right after the excerpt ("breeze ..."), so a closing full stop on the page cannot be checked */
    if (core.endsWith('.')) forms.push(...forms.map((f) => f.slice(0, -1) + ' …'));
    const hits = reviews.reviews.filter((r) => { const t = norm(r.text); return forms.some((f) => t.includes(f)); });
    assert.ok(hits.length, `quote not found in any dated fixture review: "${quote}"`);
    const a = attribution.match(/^(.+?), (January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec) (\d{4})\b/);
    assert.ok(a, `attribution without a month and year: "${attribution}" for "${quote}"`);
    /* the hero line no longer names the guest (privacy): "A returning guest, <month>" must be tied to a review of that month whose reviewer
       appears more than once in the fixture (a repeat guest), so the words are true; no name is rendered or logged here */
    const repeatReviewer = (r) => reviews.reviews.filter((x) => x.name === r.name).length > 1;
    const anon = a[1] === 'A returning guest', who = (r) => (anon ? repeatReviewer(r) : r.name === a[1]);
    const month = `${a[3]}-${String(MONTHS.findIndex((x) => x.startsWith(a[2].slice(0, 3))) + 1).padStart(2, '0')}`;
    assert.ok(hits.some((r) => who(r) && r.month === month), `"${quote}" is attributed to ${anon ? 'a returning guest' : a[1]}, ${month}; the fixture has reviews of ${hits.map((r) => r.month).join(' / ')} among the matches${anon ? ' (none from a repeat reviewer)' : ''}`);
    assert.ok(hits.some((r) => who(r) && r.month === month && r.stars === 5), `"${quote}" (${a[1]}, ${month}) comes from a review under five stars`);
  }
  assert.deepEqual(pendingSeen, PENDING_VERIFICATION, 'a pending quote left the page: drop it from PENDING_VERIFICATION');
});

test('Guest stories: no star glyph run claims a rating the fixture does not support (N14)', () => {
  const visible = bodyMarkup.replace(/<dialog\b[\s\S]*?<\/dialog>/g, '');
  const text = decode(visible.replace(/<[^>]+>/g, ''));
  assert.doesNotMatch(text, /[★☆]\s*[★☆]/, 'multi-star runs read as a per-review rating; the page must not show one');
  const fiveStarOnly = reviews.reviews.filter((r) => r.stars < 5).map((r) => norm(r.text.split(/[.!]/)[0]));
  for (const { quote } of guestQuotes()) assert.ok(!fiveStarOnly.some((t) => t && norm(quote).includes(t)), `a sub-5-star review is quoted: "${quote}"`);
});

test('Guest stories: rating facts and refresh copy (fiveStar from RATING, deposit step, CTA verbs)', () => {
  assert.equal(reviews.rating.score, 4.97); assert.equal(reviews.rating.count, 64);
  assert.match(html, new RegExp(`fiveStar: ${reviews.rating.fiveStarPct}, verifiedOn: '${reviews.rating.verifiedOn}'`));
  const noScript = html.replace(/<script[\s\S]*?<\/script>/g, '');
  assert.equal((noScript.match(/data-rating="fiveStar"/g) || []).length, 1, 'R4: only the rating band renders the five-star share (the hero line was removed); it reads RATING');
  /* round D (D4): each span carries the RATING value as a no-JS fallback that the script overwrites; the number lives nowhere else in markup */
  const fallbacks = [...noScript.matchAll(/<span data-rating="fiveStar">([^<]*)<\/span>/g)].map((m) => m[1]);
  assert.deepEqual(fallbacks, [`${reviews.rating.fiveStarPct}%`], 'the no-JS fallback is the RATING share');
  assert.doesNotMatch(noScript.replace(/<span data-rating="fiveStar">[^<]*<\/span>/g, ''), /\b97\s?%/, 'the five-star share is never hard-coded in markup outside the fallback');
  assert.match(html, /<span>Pay your stay in full by GCash or bank transfer\. We confirm every booking personally\.<\/span>/);
  assert.doesNotMatch(html, /Check today(’|&rsquo;|')s price|>Check price<|>Check my price</);
  assert.match(html, /id="stickyBookCtaBtn" data-gs-book>Reserve<\/a>/);
  assert.match(html, /<span class="hero-bk-cta-label">Reserve your stay<\/span>|>Reserve your stay</);
});

test('R4: the hero has no five-star line; the proof section keeps it; the wordmark is a script face with a one-line swap', () => {
  const noScript = html.replace(/<script[\s\S]*?<\/script>/g, '');
  const hero = noScript.slice(noScript.indexOf('<section class="hero luxury-hero-grid"'), noScript.indexOf('</section>', noScript.indexOf('<section class="hero luxury-hero-grid"')));
  assert.ok(hero.length > 500, 'hero section found');
  assert.doesNotMatch(hero, /97\s?%|gave five stars|gs-hero-proof/, 'no five-star line in the hero');
  assert.match(noScript, /<p class="gs-disp iv-proof-line"><span data-rating="fiveStar">97%<\/span> of guests gave five stars<\/p>/, 'the lower proof line stays');
  assert.doesNotMatch(html, /gs-hero-proof/, 'no dead CSS or JS left for the removed line');
  assert.match(html, /family=Pinyon\+Script&display=swap/, 'Pinyon Script loads through the existing fonts request');
  assert.match(html, /--gs-wordmark-font:\s*'Pinyon Script', 'Snell Roundhand', 'Apple Chancery', 'Cormorant Garamond', serif;/);
  assert.match(html, /\.site-header \.logo-name \{\s*font-family: var\(--gs-wordmark-font\);/);
});
