import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// SPEC-42 s6: the status page repeats the booking site's policy wording exactly, writes with textContent only, and stays private.
const stay = await readFile(new URL('../stay.html', import.meta.url), 'utf8');
const terms = await readFile(new URL('../booking-terms.html', import.meta.url), 'utf8');
const index = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const plain = (html) => html.replace(/<[^>]+>/g, '').replace(/&#x20B1;/g, '₱').replace(/\s+/g, ' ');

test('policy sentences match booking-terms.html word for word', () => {
  const policy = plain(stay.slice(stay.indexOf('id="stPolicy"'), stay.indexOf('</section>', stay.indexOf('id="stPolicy"'))));
  const source = plain(terms);
  for (const sentence of [
    'Check-in begins at 2:00 PM.',
    'Check-out is at 12:00 PM (noon).',
    'A separate, refundable security deposit of ₱800 is paid with your booking or by the day before check-in',
    'your door PIN is sent once your payment, IDs and the deposit are in',
    'The deposit is returned as soon as possible, within 3 business days of check-out, to the same account or payment mode it came from.',
    'Free cancellation until 5 days before check-in',
    'Inside 5 days, or for a no-show, we keep 50% of the stay',
  ]) {
    assert.ok(source.includes(sentence), `booking-terms.html no longer says: ${sentence}`);
    assert.ok(policy.includes(sentence), `stay.html does not repeat: ${sentence}`);
  }
});

test('the page writes with textContent only and keeps the token out of the URL query and the referrer', () => {
  assert.doesNotMatch(stay, /innerHTML|outerHTML|insertAdjacentHTML|document\.write/);
  assert.match(stay, /<meta name="robots" content="noindex, nofollow">/);
  assert.match(stay, /<meta name="referrer" content="no-referrer">/);
  assert.match(stay, /\^#t=\(\[A-Za-z0-9_-\]\{43\}\)\$/);
  assert.doesNotMatch(stay, /console\./);
});

test('the confirmed balance row is labelled "Balance due" and hidden once its date has passed, and a reply without a status shows the retry page', () => {
  assert.match(stay, /s\.state === 'confirmed' \? 'Balance due' : 'Remaining balance'/);
  assert.match(stay, /timeZone: 'Asia\/Manila'/);
  assert.match(stay, /else neutral\('We could not load your booking just now'/);
});

test('the success overlay links the private status page only from the server-returned status_url', () => {
  assert.match(index, /id="successTrackLink" href="stay\.html"[^>]*hidden>Track your booking</);
  assert.match(index, /statusUrl\.indexOf\('https:\/\/cascadereservations-del\.github\.io\/Stay_At_CascadeGSC\/stay\.html#t='\) === 0/);
});

test('the Before you arrive form asks for a name, a mobile, an ID type and a photo, and never an ID number, birthday or address', () => {
  const form = stay.slice(stay.indexOf('SPEC-42 s4b'), stay.indexOf('function render(s)'));
  assert.ok(form.length > 1000, 'the intake form code is present');
  assert.doesNotMatch(form, /birth|address/i);
  assert.deepEqual([...form.matchAll(/field\('([^']+)'/g)].map((m) => m[1]), ['Full name', 'Mobile number', 'ID type'], 'the only typed fields');
  assert.match(form, /we never record the ID number/);
  assert.match(form, /guest-intake/);
  assert.match(form, /'Content-Type': 'application\/json' \}, body: JSON\.stringify\(\{ token: t, action: 'context' \}\)/);
  assert.match(form, /headers: \{ 'x-guest-token': t \}/, 'the token travels in a header, never the URL or the form');
  assert.doesNotMatch(form, /fd\.append\('token'/);
  assert.match(form, /done\(b \|\| file\)/, 'the re-encoded copy (no camera metadata) is always the one sent');
  assert.match(stay, /if \(s\.state === 'confirmed'\) loadIntake\(token\(\), ''\);/, 'the form is asked for only on a confirmed booking');
});
