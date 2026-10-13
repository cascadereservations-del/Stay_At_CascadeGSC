// deno test --node-modules-dir=none --allow-env upload-photo/hash.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { recordUploadHash, sha256Hex } from './hash.ts';

Deno.test('sha256Hex is the standard digest of the bytes', async () => {
  assertEquals(await sha256Hex(new TextEncoder().encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assertEquals(await sha256Hex(new Uint8Array(0)), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
});

Deno.test('recordUploadHash inserts into staff_upload_hashes with exactly path, sha256, uploaded_by, and never throws', async () => {
  const seen: Array<[string, unknown]> = [];
  const db = (err: unknown) => ({ from: (t: string) => ({ insert: (r: unknown) => { seen.push([t, r]); if (err === 'throw') throw new Error('boom'); return Promise.resolve({ error: err }); } }) });
  const row = { path: 'p/u/s/f.jpg', sha256: 'a'.repeat(64), uploaded_by: 'u' };
  assertEquals(await recordUploadHash(db(null), row), true);
  assertEquals(seen[0], ['staff_upload_hashes', row]);
  assertEquals(await recordUploadHash(db({ code: '23505' }), row), false);
  assertEquals(await recordUploadHash(db('throw'), row), false);
});
