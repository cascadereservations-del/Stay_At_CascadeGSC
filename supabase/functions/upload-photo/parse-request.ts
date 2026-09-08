// Pure parsing/validation for upload-photo's two accepted body shapes:
// JSON (fileData as base64 + metadata fields) and a raw image body
// (Content-Type: image/*, metadata in x-cascade-* headers — the transport
// the cleaner PWA's photo pipeline v2 (WP2) will move to, WP3). No
// Supabase client or Deno.serve dependency, so this is unit-testable
// without a live environment.

export interface ParsedUpload {
  bytes: Uint8Array;
  fileName: string;
  mimeType: string;
  propertyId: string;
  submissionId: string;
}

export type ParseResult =
  | { ok: true; value: ParsedUpload }
  | { ok: false; error: string; status: number };

// Decode a base64 string that may or may not carry a data-URI prefix.
export function decodeBase64(raw: string): Uint8Array {
  const clean = raw.includes(',') ? raw.split(',')[1] : raw;
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function safeFileName(raw: string): string {
  const clean = raw.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  if (!clean || clean.length > 120 || !/\.(jpe?g|png|webp)$/.test(clean)) {
    throw new Error('invalid_file_name');
  }
  return clean;
}

async function parseJsonBody(req: Request): Promise<ParseResult> {
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return { ok: false, error: 'invalid_json_body', status: 400 };
  }
  const { fileData, fileName, mimeType = 'image/jpeg', propertyId, submissionId } = body;
  if (!fileData || !fileName || !propertyId || !submissionId) {
    return { ok: false, error: 'fileData, fileName, propertyId and submissionId are required', status: 400 };
  }
  // Same 7.1MB string-length pre-check as before decoding — kept here so a
  // grossly oversized base64 payload is rejected without ever calling atob().
  if (typeof fileData !== 'string' || fileData.length > 7_100_000) {
    return { ok: false, error: 'invalid_image_size', status: 413 };
  }
  return {
    ok: true,
    value: {
      bytes: decodeBase64(fileData),
      fileName: String(fileName),
      mimeType: String(mimeType),
      propertyId: String(propertyId),
      submissionId: String(submissionId),
    },
  };
}

async function parseRawBody(req: Request, contentType: string): Promise<ParseResult> {
  const mimeType = contentType.split(';')[0].trim();
  const fileName = req.headers.get('x-cascade-file-name') || '';
  const propertyId = req.headers.get('x-cascade-property-id') || '';
  const submissionId = req.headers.get('x-cascade-submission-id') || '';
  if (!fileName || !propertyId || !submissionId) {
    return {
      ok: false,
      error: 'x-cascade-file-name, x-cascade-property-id and x-cascade-submission-id headers are required',
      status: 400,
    };
  }
  const arrayBuffer = await req.arrayBuffer();
  return { ok: true, value: { bytes: new Uint8Array(arrayBuffer), fileName, mimeType, propertyId, submissionId } };
}

// Both shapes converge on the same ParsedUpload so the rest of upload-photo
// (mime allowlist, submissionId format, size ceiling, path, storage upload)
// never branches on which one arrived.
export function parseUploadRequest(req: Request): Promise<ParseResult> {
  const contentType = req.headers.get('content-type') || '';
  return contentType.startsWith('image/') ? parseRawBody(req, contentType) : parseJsonBody(req);
}
