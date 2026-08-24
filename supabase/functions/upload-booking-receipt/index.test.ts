import {
  buildReceiptObjectPath,
  issueReceiptUploadToken,
  validateReceiptUpload,
  verifyReceiptUploadToken,
} from '../_shared/receipt-security.ts';

const SECRET = 'test-receipt-secret';
const BOOKING_ID = '11111111-1111-4111-8111-111111111111';
const NOW = Date.UTC(2026, 7, 24, 0, 0, 0);

function expect(value: unknown, message: string): void {
  if (!value) throw new Error(message);
}

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`);
}

function failure(result: ReturnType<typeof validateReceiptUpload>): string {
  if (result.ok) throw new Error('expected validation failure');
  return result.error;
}

function success(result: ReturnType<typeof validateReceiptUpload>): string {
  if (!result.ok) throw new Error(`expected validation success, got ${result.error}`);
  return result.extension;
}

function jpegBytes(): Uint8Array {
  return new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]);
}

function token(expiresAt = NOW + 15 * 60 * 1000): Promise<string> {
  return issueReceiptUploadToken({ bookingId: BOOKING_ID, nonce: 'nonce-123', expiresAt }, SECRET);
}

Deno.test('rejects a missing receipt upload token', async () => {
  equal(await verifyReceiptUploadToken('', SECRET, NOW), null, 'missing token must be rejected');
});

Deno.test('rejects an expired receipt upload token', async () => {
  equal(await verifyReceiptUploadToken(await token(NOW - 1), SECRET, NOW), null, 'expired token must be rejected');
});

Deno.test('rejects a MIME type outside the receipt allowlist', async () => {
  const result = validateReceiptUpload({ filename: 'receipt.exe', mimeType: 'application/octet-stream', bytes: jpegBytes(), contentLength: 6, existingReceiptPath: null });
  equal(result.ok, false, 'unexpected MIME type must fail');
  equal(failure(result), 'unsupported_file_type', 'unexpected MIME error code');
});

Deno.test('rejects a receipt larger than ten megabytes before storage', () => {
  const result = validateReceiptUpload({ filename: 'receipt.jpg', mimeType: 'image/jpeg', bytes: jpegBytes(), contentLength: 10 * 1024 * 1024 + 1, existingReceiptPath: null });
  equal(result.ok, false, 'oversized receipt must fail');
  equal(failure(result), 'file_too_large', 'oversized error code');
});

Deno.test('rejects filename traversal', () => {
  const result = validateReceiptUpload({ filename: '../../receipt.jpg', mimeType: 'image/jpeg', bytes: jpegBytes(), contentLength: 6, existingReceiptPath: null });
  equal(result.ok, false, 'traversal filename must fail');
  equal(failure(result), 'invalid_filename', 'traversal error code');
});

Deno.test('rejects a second receipt for the same booking', () => {
  const result = validateReceiptUpload({ filename: 'receipt.jpg', mimeType: 'image/jpeg', bytes: jpegBytes(), contentLength: 6, existingReceiptPath: 'booking/old.jpg' });
  equal(result.ok, false, 'duplicate receipt must fail');
  equal(failure(result), 'receipt_already_uploaded', 'duplicate error code');
});

Deno.test('rejects a MIME type whose magic bytes do not match', () => {
  const result = validateReceiptUpload({ filename: 'receipt.png', mimeType: 'image/png', bytes: jpegBytes(), contentLength: 6, existingReceiptPath: null });
  equal(result.ok, false, 'mismatched magic bytes must fail');
  equal(failure(result), 'file_content_mismatch', 'magic-byte error code');
});

Deno.test('accepts a valid image receipt and uses a private object path', () => {
  const result = validateReceiptUpload({ filename: 'receipt.jpg', mimeType: 'image/jpeg', bytes: jpegBytes(), contentLength: 6, existingReceiptPath: null });
  expect(result.ok, 'valid receipt must pass');
  const extension = success(result);
  equal(extension, 'jpg', 'JPEG extension');
  const path = buildReceiptObjectPath(BOOKING_ID, 'nonce-123', extension);
  equal(path, `${BOOKING_ID}/nonce-123.jpg`, 'private object path');
  expect(!path.includes('receipt.jpg'), 'object path must not retain user filename');
});

Deno.test('verifies an unexpired signed upload token for the original booking only', async () => {
  const claim = await verifyReceiptUploadToken(await token(), SECRET, NOW);
  if (!claim) throw new Error('valid token must verify');
  equal(claim.bookingId, BOOKING_ID, 'token booking ID');
  equal(claim.nonce, 'nonce-123', 'token nonce');
});
