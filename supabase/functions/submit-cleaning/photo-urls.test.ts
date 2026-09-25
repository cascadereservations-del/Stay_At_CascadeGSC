// deno test --no-check --allow-env submit-cleaning/photo-urls.test.ts
import { assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { refreshSignedPhotoUrls } from './photos.ts';

/* Regression, 2026-09-18. Cleaning photos stopped reaching Drive on 2026-08-30 (f89caaa) and nobody
   noticed for three weeks, because nothing failed loudly: the Drive folders were still created, the
   report e-mail still arrived, and Apps Script logged the skip where no one reads it.

   The contract spans two runtimes. Code.gs picks a photo source in this order:
       photo.data  ->  photo.url  ->  return    (silent skip)
   so a payload carrying only `fileUrl` is silently dropped, every time. These tests pin the field
   names on this side. If Code.gs is ever taught to read `fileUrl`, they can relax - not before. */

const fakeClient = (signed = 'https://example.invalid/signed?token=abc') => ({
  storage: {
    from: (_bucket: string) => ({
      createSignedUrl: (_path: string, _secs: number) => Promise.resolve({ data: { signedUrl: signed }, error: null }),
    }),
  },
});

Deno.test('a refreshed photo carries `url`, which is the field Apps Script actually reads', async () => {
  const photos = { section_preclean: [{ fileId: 'prop/user/sub/a.jpg', url: 'https://old/expired', fileUrl: 'https://old/expired' }] };
  await refreshSignedPhotoUrls(fakeClient(), photos as never);
  const p = photos.section_preclean[0] as Record<string, unknown>;
  assertEquals(p.url, 'https://example.invalid/signed?token=abc', 'Code.gs reads photo.url; without it the photo is skipped');
  assertEquals(p.fileUrl, 'https://example.invalid/signed?token=abc', 'and submit-cleaning/Telegram read fileUrl');
});

Deno.test('the stale url is replaced, not merely left in place', async () => {
  const photos = { section_meter: [{ fileId: 'prop/user/sub/m.jpg', url: 'https://old/expired-900s' }] };
  await refreshSignedPhotoUrls(fakeClient('https://fresh/signed'), photos as never);
  assertEquals((photos.section_meter[0] as Record<string, unknown>).url, 'https://fresh/signed');
});

Deno.test('base64 is still stripped, so the payload does not carry image bytes', async () => {
  const photos = { section_afterclean: [{ fileId: 'prop/user/sub/b.jpg', data: 'data:image/jpeg;base64,AAAA' }] };
  await refreshSignedPhotoUrls(fakeClient(), photos as never);
  assertEquals('data' in (photos.section_afterclean[0] as Record<string, unknown>), false);
});

Deno.test('every section is refreshed, not just the first', async () => {
  const photos = {
    section_preclean: [{ fileId: 'p/1.jpg' }, { fileId: 'p/2.jpg' }],
    section_meter: [{ fileId: 'm/1.jpg' }],
  };
  await refreshSignedPhotoUrls(fakeClient(), photos as never);
  for (const list of Object.values(photos)) {
    for (const p of list) assertEquals((p as Record<string, unknown>).url, 'https://example.invalid/signed?token=abc');
  }
});

Deno.test('a signing failure is loud, because a silent one is what caused this bug', async () => {
  const broken = {
    storage: { from: () => ({ createSignedUrl: () => Promise.resolve({ data: null, error: { message: 'nope' } }) }) },
  };
  await assertRejects(
    () => refreshSignedPhotoUrls(broken as never, { s: [{ fileId: 'x.jpg' }] } as never),
    Error,
    'photo_access_refresh_failed',
  );
});

import { photoOutsideScope } from './photos.ts';
Deno.test('2026-09-25: photos from the same cleaner under an earlier submission of hers are accepted; anyone else is refused', () => {
  const P = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', U = '50ccca5a-3e59-4299-9680-837fd8d88ac4';
  const mine = (sub: string) => ({ fileId: `${P}/${U}/${sub}/section_preclean/1.jpg` });
  assertEquals(photoOutsideScope({ a: [mine('7e10316e'), mine('afabd561')] }, P, U), false);
  assertEquals(photoOutsideScope({ a: [mine('afabd561'), { fileId: `${P}/another-user/afabd561/x.jpg` }] }, P, U), true);
  assertEquals(photoOutsideScope({ a: [{ fileId: `other-property/${U}/afabd561/x.jpg` }] }, P, U), true);
  assertEquals(photoOutsideScope({ a: [{ fileId: `${P}/${U}/../other/x.jpg` }] }, P, U), true);
  assertEquals(photoOutsideScope({ a: [{ fileId: '' }] }, P, U), true);
});
