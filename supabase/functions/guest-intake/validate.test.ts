// deno test --no-lock --node-modules-dir=auto --allow-env --allow-read guest-intake/
// SPEC-42 s4b: the form's pure rules, parity with the Telegram intake rules, and source guards on index.ts.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { cleanName as tgCleanName, sniffImage as tgSniff } from '../telegram-expense/guest.ts';
import { cleanContact, cleanName, MAX_PHOTO_BYTES, parseSubmission, sniffImage } from './validate.ts';

const TOKEN = 'A'.repeat(43);
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
const WEBP = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
const SVG = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>');

function form(people: unknown, files: Record<string, Uint8Array> = {}, token: string = TOKEN): FormData {
  const f = new FormData();
  f.set('token', token);
  f.set('people', JSON.stringify(people));
  for (const [k, v] of Object.entries(files)) f.set(k, new File([v as BlobPart], 'id.jpg', { type: 'image/jpeg' }));
  return f;
}

Deno.test('photos: JPEG, PNG and WebP by magic bytes; SVG, text, tiny and oversize files are refused', () => {
  assertEquals(sniffImage(JPEG)?.ext, 'jpg');
  assertEquals(sniffImage(PNG)?.ext, 'png');
  assertEquals(sniffImage(WEBP)?.ext, 'webp');
  assertEquals(sniffImage(SVG), null);
  assertEquals(sniffImage(new TextEncoder().encode('%PDF-1.7 not an image at all')), null);
  assertEquals(sniffImage(new Uint8Array(4)), null);
  assertEquals(sniffImage(new Uint8Array(MAX_PHOTO_BYTES + 1).fill(0xff)), null);
});

Deno.test('parity: the form reads a name and a photo exactly as the Telegram intake does', () => {
  for (const s of ['Ben Cruz', 'CRUZ MARIA', "o'neil-smith", 'Ana', 'A', 'Id 123456789', 'x'.repeat(90), '<b>Bob</b> Lee']) {
    assertEquals(cleanName(s), s.includes(',') ? undefined : tgCleanName(s), `name: ${s}`);
  }
  for (const b of [JPEG, PNG, WEBP, SVG, new Uint8Array(4)]) assertEquals(sniffImage(b), tgSniff(b));
});

Deno.test('names: no ID-number-like digits, no markup, Title Case for all caps', () => {
  assertEquals(cleanName('MARIA SANTOS'), 'Maria Santos');
  assertEquals(cleanName('Passport 12345678'), null);
  assertEquals(cleanName('<script>x</script>'), 'Scriptxscript');
  assertEquals(cleanName(''), null);
});

Deno.test('contact: digits with an optional plus, 7 to 15; blank is no number; junk is refused', () => {
  assertEquals(cleanContact('0917 000-1111'), '09170001111');
  assertEquals(cleanContact('+44 20 7946 0958'), '+442079460958');
  assertEquals(cleanContact(''), null);
  assertEquals(cleanContact(null), null);
  assertEquals(cleanContact('abc'), false);
  assertEquals(cleanContact('12345'), false);
});

Deno.test('parseSubmission: people, photos and the self flag come through; anything off is refused whole', async () => {
  const ok = await parseSubmission(form([{ name: 'ben cruz', id_type: 'passport', contact: '0917 000 1111', self: true }, { name: 'Ana Cruz', id_type: '' }], { photo_0: JPEG }));
  assert(ok.ok);
  if (!ok.ok) return;
  assertEquals(ok.people.map((p) => [p.name, p.idType, p.contact, p.self, p.photo !== null]), [['Ben Cruz', 'passport', '09170001111', true, true], ['Ana Cruz', null, null, false, false]]);

  for (const bad of [
    form([], {}),
    form([{ name: 'Ben Cruz' }], {}, 'short'),
    form([{ name: 'Ben 123456' }], {}),
    form([{ name: 'Ben Cruz', id_type: 'visa' }], {}),
    form([{ name: 'Ben Cruz', contact: 'abc' }], {}),
    form([{ name: 'Ben Cruz', self: true }, { name: 'Ana Cruz', self: true }], {}),
    form(Array.from({ length: 13 }, (_, i) => ({ name: `Guest ${String.fromCharCode(65 + i)}${String.fromCharCode(97 + i)}` })), {}),
  ]) assertEquals((await parseSubmission(bad)).ok, false);
  const big = form([{ name: 'Ben Cruz' }], { photo_0: new Uint8Array(MAX_PHOTO_BYTES + 1) });
  const r = await parseSubmission(big);
  assert(!r.ok && r.error === 'photo_too_large');
});

Deno.test('index.ts: service key only on the server, token never logged, neutral 404, no ID number field, bucket untouched', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(src.includes("withObservability({ functionName: 'guest-intake', route: 'guest' }, async"));
  assert(!/console\.[a-z]+\([^)]*token/i.test(src), 'the token must never reach a log line');
  assert(src.includes("invalid_guest_access"), 'unknown tokens get the neutral 404');
  assert(!/id_number|birthday|address/i.test(src.replace(/\/\/.*$/gm, '')), 'no ID number, birthday or address anywhere in the handler');
  assert(src.includes("const BUCKET = 'guest-id-photos'"));
  assert(!/createBucket|updateBucket|listBuckets/.test(src), 'the bucket is never created, changed or listed here');
});
