import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const css = await readFile(new URL('../assets/css/cascade-luxury.css', import.meta.url), 'utf8');

test('loads the Quiet Urban Luxury stylesheet and theme class', () => {
  assert.match(html, /assets\/css\/cascade-luxury\.css/);
  assert.match(html, /<body class="theme-quiet-luxury">/);
});

test('defines the approved design tokens', () => {
  for (const token of [
    '--ch-ink: #1d1712', '--ch-mahogany: #2b1713',
    '--ch-parchment: #f2ece2', '--ch-bone: #fbf8f2',
    '--ch-brass: #9b7443', '--ch-line:'
  ]) assert.ok(css.includes(token), `missing ${token}`);
});

test('uses the approved type pairing', () => {
  assert.match(html, /Cormorant\+Garamond/);
  assert.match(html, /Manrope/);
  assert.doesNotMatch(html, /Raleway/);
});

test('does not restore rejected luxury-template patterns', () => {
  assert.doesNotMatch(css, /transition:\s*all/i);
  assert.doesNotMatch(css, /border-radius:\s*(9999px|50px|3rem)/i);
  assert.doesNotMatch(css, /box-shadow:[^;]*(#c9963a|rgb\(201\s+150\s+58)/i);
  assert.doesNotMatch(html, /world-class|pinnacle of luxury|bespoke|iconic destinations/i);
});

test('keeps every booking JavaScript hook exactly once', () => {
  for (const id of [
    'heroBookBar', 'qbwCiField', 'qbwCiVal', 'qbwCoField', 'qbwCoVal',
    'qbwPicker', 'qbwPickerPrev', 'qbwPickerNext', 'qbwPickerGrid',
    'qbwAvail', 'qbwError', 'qbwSubmit'
  ]) {
    assert.equal((html.match(new RegExp(`id="${id}"`, 'g')) || []).length, 1, id);
  }
});

test('hero uses the luxury grid layout classes', () => {
  assert.match(html, /class="hero luxury-hero-grid"/);
  assert.match(html, /luxury-hero-media/);
  assert.match(html, /luxury-hero-copy/);
});
