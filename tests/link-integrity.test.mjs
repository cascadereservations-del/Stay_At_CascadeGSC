import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
const hrefs = [...html.matchAll(/<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1/gi)].map((match) => match[2].trim());
const ids = new Set([...html.matchAll(/\bid\s*=\s*(["'])(.*?)\1/gi)].map((match) => match[2]));

test('internal hash links resolve to a real page target', () => {
  for (const href of hrefs.filter((value) => value.startsWith('#'))) {
    const target = href.slice(1);
    assert.ok(target && ids.has(target), `missing anchor target for ${href}`);
  }
});

test('local pages linked from the booking surface exist', () => {
  for (const href of hrefs.filter((value) => /^(?![a-z][a-z0-9+.-]*:|#)/i.test(value))) {
    const pathname = href.split(/[?#]/, 1)[0];
    if (!pathname) continue;
    assert.ok(existsSync(new URL(`../${pathname}`, import.meta.url)), `missing local target ${href}`);
  }
});

test('communication links are complete and avoid failing short domains', () => {
  for (const href of hrefs.filter((value) => /^(https?:|mailto:|tel:)/i.test(value))) {
    if (/^mailto:/i.test(href)) {
      assert.match(href, /^mailto:[^?\s@]+@[^?\s@]+/i, `invalid email link ${href}`);
      continue;
    }
    if (/^tel:/i.test(href)) {
      assert.match(href, /^tel:\+?[0-9][0-9 .()-]*$/i, `invalid phone link ${href}`);
      continue;
    }
    const url = new URL(href);
    assert.ok(url.hostname, `missing hostname in ${href}`);
    assert.notEqual(url.hostname, 'wa.me', `use full WhatsApp domain: ${href}`);
    assert.notEqual(url.hostname, 'm.me', `use full Messenger domain: ${href}`);
  }
});
