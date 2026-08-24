const MAX_RECEIPT_BYTES = 10 * 1024 * 1024;

const FILE_TYPES: Record<string, { extension: string; matches: (bytes: Uint8Array) => boolean }> = {
  'image/jpeg': {
    extension: 'jpg',
    matches: (bytes) => bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff,
  },
  'image/png': {
    extension: 'png',
    matches: (bytes) => bytes.length >= 8 && [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((value, index) => bytes[index] === value),
  },
  'image/webp': {
    extension: 'webp',
    matches: (bytes) => bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === 'RIFF' && String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP',
  },
  'application/pdf': {
    extension: 'pdf',
    matches: (bytes) => bytes.length >= 5 && String.fromCharCode(...bytes.slice(0, 5)) === '%PDF-',
  },
};

export type ReceiptUploadClaim = {
  bookingId: string;
  nonce: string;
  expiresAt: number;
};

type ReceiptUploadInput = {
  filename: string;
  mimeType: string;
  bytes: Uint8Array;
  contentLength: number;
  existingReceiptPath: string | null;
};

type ReceiptValidation =
  | { ok: true; extension: string }
  | { ok: false; error: 'unsupported_file_type' | 'file_too_large' | 'invalid_filename' | 'receipt_already_uploaded' | 'file_content_mismatch' };

const encoder = new TextEncoder();

function toBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function fromBase64Url(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const padded = value.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - value.length % 4) % 4);
    return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
  } catch {
    return null;
  }
}

async function sign(secret: string, payload: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(payload)));
}

export async function issueReceiptUploadToken(claim: ReceiptUploadClaim, secret: string): Promise<string> {
  const payload = toBase64Url(encoder.encode(JSON.stringify(claim)));
  return `${payload}.${toBase64Url(await sign(secret, payload))}`;
}

export async function verifyReceiptUploadToken(token: string, secret: string, now = Date.now()): Promise<ReceiptUploadClaim | null> {
  const [payload, signature, extra] = token.split('.');
  if (!payload || !signature || extra) return null;
  const received = fromBase64Url(signature);
  if (!received) return null;
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  if (!await crypto.subtle.verify('HMAC', key, received as unknown as BufferSource, encoder.encode(payload))) return null;
  const decoded = fromBase64Url(payload);
  if (!decoded) return null;
  try {
    const claim = JSON.parse(new TextDecoder().decode(decoded)) as ReceiptUploadClaim;
    if (!claim.bookingId || !claim.nonce || !Number.isFinite(claim.expiresAt) || claim.expiresAt <= now) return null;
    return claim;
  } catch {
    return null;
  }
}

export function validateReceiptUpload(input: ReceiptUploadInput): ReceiptValidation {
  if (input.existingReceiptPath) return { ok: false, error: 'receipt_already_uploaded' };
  if (!input.filename || input.filename !== input.filename.split(/[\\/]/).pop() || /[\x00-\x1f]/.test(input.filename)) return { ok: false, error: 'invalid_filename' };
  if (!Number.isFinite(input.contentLength) || input.contentLength < 1 || input.contentLength > MAX_RECEIPT_BYTES) return { ok: false, error: 'file_too_large' };
  const fileType = FILE_TYPES[input.mimeType.toLowerCase()];
  if (!fileType) return { ok: false, error: 'unsupported_file_type' };
  if (!fileType.matches(input.bytes)) return { ok: false, error: 'file_content_mismatch' };
  return { ok: true, extension: fileType.extension };
}

export function buildReceiptObjectPath(bookingId: string, nonce: string, extension: string): string {
  return `${bookingId}/${nonce}.${extension}`;
}
