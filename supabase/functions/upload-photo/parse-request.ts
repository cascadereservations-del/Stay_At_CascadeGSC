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
  // s86 D-photo: set only for purpose 'inventory' (cleaning values are unchanged).
  purpose?: 'inventory';
  itemId?: string;
  action?: 'sign';
  paths?: unknown;
}

export type ParseResult =
  | { ok: true; value: ParsedUpload }
  | { ok: false; error: string; status: number };

// The final size ceiling index.ts enforces on decoded bytes, for either
// shape. Exported so both parse-request.ts's early raw-body Content-Length
// check and index.ts's post-parse bytes.byteLength check use one number.
export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;
// Inventory item photos are resized on the phone to about 100 KB; 1 MB is the ceiling (matches the bucket file_size_limit).
export const MAX_INVENTORY_BYTES = 1024 * 1024;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
export const INVENTORY_PATH_RE = new RegExp(`^items/${UUID}/${UUID}\\.(jpg|webp)$`); // lower case only: storage names are case-sensitive and R7 checks lower-case ids

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
  const purpose = body.purpose ?? 'cleaning';
  if (purpose === 'inventory') return parseInventoryJson(body);
  if (purpose !== 'cleaning') return { ok: false, error: 'invalid_purpose', status: 400 };
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

// Inventory: either action 'sign' (paths validated here so a bad list never reaches auth or storage) or an upload of base64
// fileData for itemId. No file name is read: the object name is a fresh uuid and the extension comes from the mime type.
function parseInventoryJson(body: Record<string, unknown>): ParseResult {
  const { fileData, mimeType = 'image/jpeg', propertyId, itemId, action, paths } = body;
  if (!propertyId) return { ok: false, error: 'propertyId is required', status: 400 };
  if (action !== undefined) {
    if (action !== 'sign') return { ok: false, error: 'invalid_action', status: 400 };
    if (!Array.isArray(paths) || paths.length < 1 || paths.length > 200 || !paths.every((p) => typeof p === 'string' && INVENTORY_PATH_RE.test(p))) {
      return { ok: false, error: 'invalid_path', status: 400 };
    }
    return { ok: true, value: { bytes: new Uint8Array(0), fileName: '', mimeType: '', propertyId: String(propertyId), submissionId: '', purpose: 'inventory', action: 'sign', paths } };
  }
  if (!fileData || !itemId) return { ok: false, error: 'fileData, propertyId and itemId are required', status: 400 };
  // 1 MB of bytes is about 1.4M base64 characters; reject anything grossly larger before atob().
  if (typeof fileData !== 'string' || fileData.length > 1_500_000) return { ok: false, error: 'invalid_image_size', status: 413 };
  return {
    ok: true,
    value: { bytes: decodeBase64(fileData), fileName: '', mimeType: String(mimeType), propertyId: String(propertyId), submissionId: '', purpose: 'inventory', itemId: String(itemId) },
  };
}

async function parseRawBody(req: Request, contentType: string): Promise<ParseResult> {
  const mimeType = contentType.split(';')[0].trim();
  const fileName = req.headers.get('x-cascade-file-name') || '';
  const propertyId = req.headers.get('x-cascade-property-id') || '';
  const submissionId = req.headers.get('x-cascade-submission-id') || '';
  const purpose = req.headers.get('x-cascade-purpose') || 'cleaning';
  if (purpose === 'inventory') {
    const itemId = req.headers.get('x-cascade-item-id') || '';
    if (!propertyId || !itemId) return { ok: false, error: 'x-cascade-property-id and x-cascade-item-id headers are required', status: 400 };
    if (Number(req.headers.get('content-length') || 0) > MAX_INVENTORY_BYTES) return { ok: false, error: 'invalid_image_size', status: 413 };
    const bytes = new Uint8Array(await req.arrayBuffer());
    return { ok: true, value: { bytes, fileName: '', mimeType, propertyId, submissionId: '', purpose: 'inventory', itemId } };
  }
  if (purpose !== 'cleaning') return { ok: false, error: 'invalid_purpose', status: 400 };
  if (!fileName || !propertyId || !submissionId) {
    return {
      ok: false,
      error: 'x-cascade-file-name, x-cascade-property-id and x-cascade-submission-id headers are required',
      status: 400,
    };
  }
  // Same size ceiling the JSON path checks before atob() — reject an
  // oversized body from its declared Content-Length before buffering it,
  // rather than only catching it after req.arrayBuffer() has already paid
  // the cost. A missing/lying Content-Length still falls through to the
  // post-parse bytes.byteLength check in index.ts, same as before.
  const declaredLength = Number(req.headers.get('content-length') || 0);
  if (declaredLength > MAX_UPLOAD_BYTES) {
    return { ok: false, error: 'invalid_image_size', status: 413 };
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
