import { decodeBase64, parseUploadRequest, safeFileName } from './parse-request.ts';

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`);
}

const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const SUBMISSION_ID = '11111111-1111-4111-8111-111111111111';

function jsonRequest(body: Record<string, unknown> | null, rawBody?: string): Request {
  return new Request('https://example.test/upload-photo', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: rawBody ?? JSON.stringify(body),
  });
}

function rawImageRequest(byteValues: number[], headers: Record<string, string> = {}): Request {
  const buffer = new ArrayBuffer(byteValues.length);
  new Uint8Array(buffer).set(byteValues);
  return new Request('https://example.test/upload-photo', {
    method: 'POST',
    headers: { 'content-type': 'image/jpeg', ...headers },
    body: buffer,
  });
}

function tinyJpegBase64(): string {
  // Not a real JPEG — parseUploadRequest doesn't sniff magic bytes, only
  // upload-photo's mimeType/size checks (done by the caller) do that.
  return btoa('fake-jpeg-bytes');
}

Deno.test('JSON shape: accepts a well-formed request and decodes fileData', async () => {
  const result = await parseUploadRequest(jsonRequest({
    fileData: tinyJpegBase64(),
    fileName: 'preclean_2026-09-08.jpg',
    mimeType: 'image/jpeg',
    propertyId: PROPERTY_ID,
    submissionId: SUBMISSION_ID,
  }));
  if (!result.ok) throw new Error(`expected success, got ${result.error}`);
  equal(result.value.fileName, 'preclean_2026-09-08.jpg', 'fileName passes through');
  equal(result.value.propertyId, PROPERTY_ID, 'propertyId passes through');
  equal(new TextDecoder().decode(result.value.bytes), 'fake-jpeg-bytes', 'fileData is decoded to bytes');
});

Deno.test('JSON shape: rejects a request missing required fields', async () => {
  const result = await parseUploadRequest(jsonRequest({ fileData: tinyJpegBase64(), fileName: 'x.jpg' }));
  equal(result.ok, false, 'missing propertyId/submissionId must fail');
  if (result.ok) throw new Error('unreachable');
  equal(result.status, 400, 'missing-fields status');
});

Deno.test('JSON shape: rejects an oversized base64 payload before decoding', async () => {
  const oversized = 'a'.repeat(7_100_001);
  const result = await parseUploadRequest(jsonRequest(null, JSON.stringify({
    fileData: oversized, fileName: 'x.jpg', propertyId: PROPERTY_ID, submissionId: SUBMISSION_ID,
  })));
  equal(result.ok, false, 'oversized fileData must fail');
  if (result.ok) throw new Error('unreachable');
  equal(result.status, 413, 'oversized status');
  equal(result.error, 'invalid_image_size', 'oversized error code');
});

Deno.test('JSON shape: rejects an unparsable body', async () => {
  const result = await parseUploadRequest(jsonRequest(null, '{not json'));
  equal(result.ok, false, 'malformed JSON must fail');
  if (result.ok) throw new Error('unreachable');
  equal(result.status, 400, 'malformed JSON status');
});

Deno.test('raw shape (WP3): accepts a raw image body with x-cascade-* headers', async () => {
  const result = await parseUploadRequest(rawImageRequest([1, 2, 3, 4, 5], {
    'x-cascade-file-name': 'afterclean_2026-09-08.jpg',
    'x-cascade-property-id': PROPERTY_ID,
    'x-cascade-submission-id': SUBMISSION_ID,
  }));
  if (!result.ok) throw new Error(`expected success, got ${result.error}`);
  equal(result.value.mimeType, 'image/jpeg', 'mimeType comes from Content-Type');
  equal(result.value.fileName, 'afterclean_2026-09-08.jpg', 'fileName comes from header');
  equal(result.value.bytes.byteLength, 5, 'raw bytes pass through untouched, no base64 round-trip');
});

Deno.test('raw shape (WP3): rejects a raw body missing any x-cascade-* header', async () => {
  const result = await parseUploadRequest(rawImageRequest([1, 2, 3], {
    'x-cascade-file-name': 'a.jpg',
    'x-cascade-property-id': PROPERTY_ID,
    // submissionId header missing
  }));
  equal(result.ok, false, 'missing header must fail');
  if (result.ok) throw new Error('unreachable');
  equal(result.status, 400, 'missing header status');
});

Deno.test('safeFileName rejects unsupported extensions', () => {
  let threw = false;
  try { safeFileName('evil.sh'); } catch { threw = true; }
  equal(threw, true, 'non-image extension must throw');
});

Deno.test('safeFileName normalizes a valid name', () => {
  equal(safeFileName('Preclean Photo #1.JPG'.toLowerCase()), 'preclean-photo-1.jpg', 'normalized name');
});

Deno.test('decodeBase64 strips a data-URI prefix', () => {
  const withPrefix = `data:image/jpeg;base64,${btoa('hi')}`;
  equal(new TextDecoder().decode(decodeBase64(withPrefix)), 'hi', 'data-URI prefix stripped');
});
