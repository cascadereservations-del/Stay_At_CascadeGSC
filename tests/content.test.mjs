import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');

test('public HTML does not expose the exact lot address', () => {
  assert.doesNotMatch(html, /Block\s*47\s*,?\s*Lot\s*39/i);
});

test('public HTML does not claim instant confirmation', () => {
  assert.doesNotMatch(html, /instant confirmation|confirmed immediately|confirms your stay immediately/i);
});

test('public HTML does not use unsupported luxury superlatives', () => {
  assert.doesNotMatch(html, /world-class|pinnacle of luxury|bespoke|iconic destinations|elevated stays/i);
});

test('all WhatsApp links use the configured public destination', () => {
  const numbers = [...html.matchAll(/wa\.me\/(\d+)/g)].map(match => match[1]);
  assert.ok(numbers.length > 0);
  assert.equal(new Set(numbers).size, 1);
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

test('Airbnb rating and review count are reconciled to a single current value', () => {
  assert.doesNotMatch(html, />4\.97</);
  assert.doesNotMatch(html, /"4\.97"/);
  assert.doesNotMatch(html, /4\.97\s*(star|&#9733;|&#x2605;|out of 5|&#9733;\s*&middot;|␣)/i);
  assert.doesNotMatch(html, /\b34\s+(Airbnb\s+)?[Rr]eviews\b/);
  assert.doesNotMatch(html, /\b31\s+Guests\b/);
});

test('parking copy matches the reconciled Airbnb fact (shared roadside, not "secured")', () => {
  assert.doesNotMatch(html, /secured parking/i);
});

test('reserves a dated, non-live Airbnb proof fallback', () => {
  assert.match(html, /Verified on 24 Aug 2026/);
  assert.match(html, /id="airbnbProofEmbed"/);
});

test('does not fetch or scrape airbnb.com from client code', () => {
  assert.doesNotMatch(html, /fetch\(['"`][^'"`]*airbnb\.com/i);
});
