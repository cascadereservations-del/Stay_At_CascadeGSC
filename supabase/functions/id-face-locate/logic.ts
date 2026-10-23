// id-face-locate logic (SPEC-47b). Pure: model text -> stored face box, and the run loop with injected deps.
// Privacy: the model is asked for coordinates only; nothing it says is logged, and only counts leave this file.
import { parseModelJson } from '../_shared/cascade-core/vision.ts';

export const FACE_PROMPT =
  'Find the largest human face in this photo. Reply with ONLY this JSON and nothing else: {"face":[ymin,xmin,ymax,xmax]} ' +
  'with each number an integer from 0 to 1000 (fractions of the image height and width), or {"face":null} when no face is visible. ' +
  'Do not read, mention or describe any name, number, text or other detail.';

export type FaceBox = { x: number; y: number; w: number; h: number; src: 'vision' | 'none' };
// SQL CHECK needs all five keys even for "none", so none is the whole-image box with src none (the app ignores the numbers).
export const NONE: FaceBox = { x: 0, y: 0, w: 1, h: 1, src: 'none' };

export const PAD = 0.35;       // each side, of the box size (hair, chin)
export const MIN_W = 0.02;     // box narrower or shorter than 2% of the image = not a face
const r4 = (n: number) => Math.round(n * 10000) / 10000;
const clamp01 = (n: number) => Math.min(1, Math.max(0, n));

/** [ymin,xmin,ymax,xmax] (0-1000, or 0-1 when all four are <= 1) -> padded {x,y,w,h} 0-1 clamped to the image; unusable -> none. */
export function boxFromModel(face: number[]): FaceBox {
  const k = face.every((n) => n <= 1) ? 1 : 1000;
  const [a, b, c, d] = face.map((n) => clamp01(n / k));
  const y0 = Math.min(a, c), y1 = Math.max(a, c), x0 = Math.min(b, d), x1 = Math.max(b, d);
  const w = x1 - x0, h = y1 - y0;
  if (!(w >= MIN_W) || !(h >= MIN_W)) return NONE;
  const x = clamp01(x0 - w * PAD), y = clamp01(y0 - h * PAD);
  const xe = clamp01(x1 + w * PAD), ye = clamp01(y1 + h * PAD);
  const box = { x: r4(x), y: r4(y), w: r4(xe - x), h: r4(ye - y) };
  // rounding must never break the CHECK (x,y < 1; w,h > 0; x+w, y+h <= 1.0001)
  if (box.x >= 1 || box.y >= 1 || box.w <= 0 || box.h <= 0) return NONE;
  return { ...box, src: 'vision' };
}

/** Total: a reply with no usable box (not JSON, no face key, bad numbers) is "none", never retried (owner choice, fix round 1). */
export function parseFaceReply(text: string): FaceBox {
  const j = parseModelJson<unknown>(text, null);
  if (!j || typeof j !== 'object' || !('face' in j)) return NONE;
  const f = (j as { face: unknown }).face;
  if (!Array.isArray(f) || f.length !== 4 || !f.every((n) => typeof n === 'number' && Number.isFinite(n))) return NONE;
  return boxFromModel(f as number[]);
}

/** JPEG EXIF Orientation (1-8), or null when there is no APP1/Orientation or the bytes are not a JPEG. */
export function exifOrientation(b: Uint8Array): number | null {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;
  let i = 2;
  while (i + 4 <= b.length && b[i] === 0xff) {
    const m = b[i + 1];
    if (m === 0xda || m === 0xd9) return null; // image data / end: no EXIF before it
    const len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2) return null;
    if (m === 0xe1 && b[i + 4] === 0x45 && b[i + 5] === 0x78 && b[i + 6] === 0x69 && b[i + 7] === 0x66 && b[i + 8] === 0 && b[i + 9] === 0) {
      const t = i + 10, end = Math.min(b.length, i + 2 + len);
      const le = b[t] === 0x49;
      const u16 = (o: number) => (le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1]);
      const u32 = (o: number) => (le ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0 : ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0);
      if (t + 8 > end || (b[t] !== 0x49 && b[t] !== 0x4d) || u16(t + 2) !== 42) return null;
      const ifd = t + u32(t + 4);
      if (ifd + 2 > end) return null;
      const n = u16(ifd);
      for (let e = 0; e < n; e++) {
        const o = ifd + 2 + e * 12;
        if (o + 12 > end) return null;
        if (u16(o) === 0x0112) { const v = u16(o + 8); return v >= 1 && v <= 8 ? v : null; }
      }
      return null;
    }
    i += 2 + len;
  }
  return null;
}

/** Status code of a provider error (visionExtractText throws "openrouter_400: ..." / "gemini_429: ..."); null when none. Never logged. */
export function providerStatus(e: unknown): number | null {
  const m = /(?:openrouter|gemini)_(\d{3})/.exec(e instanceof Error ? e.message : String(e));
  return m ? Number(m[1]) : null;
}
/** A 4xx that is about THIS image (bad request / too large / unsupported / unprocessable). 401, 403, 404 and 429 are config or load, so transient. */
export const isBadImage = (e: unknown) => [400, 413, 415, 422].includes(providerStatus(e) ?? 0);

export function mimeFor(path: string): string {
  const e = path.toLowerCase().split('.').pop();
  return e === 'png' ? 'image/png' : e === 'webp' ? 'image/webp' : e === 'heic' ? 'image/heic' : 'image/jpeg';
}

export const MAX_CONSECUTIVE_FAILS = 3;
export const BUDGET_MS = 100_000;

export type Todo = { companion_id: string; path: string };
export type Deps = {
  todo: () => Promise<Todo[]>;
  /** bytes; null = the object is gone (permanent); throws on any other failure (transient). */
  download: (path: string) => Promise<Uint8Array | null>;
  vision: (bytes: Uint8Array, mime: string) => Promise<string>;
  save: (id: string, path: string, box: FaceBox) => Promise<boolean>;
  log: (m: string) => void;
  now?: () => number;
};
export type Summary = { todo: number; saved: number; none: number; skipped: number; save_refused: number; exif_rotated: number; stopped: boolean; budget_stopped: boolean };

export async function run(d: Deps): Promise<Summary> {
  const now = d.now ?? Date.now, t0 = now();
  const rows = await d.todo();
  const s: Summary = { todo: rows.length, saved: 0, none: 0, skipped: 0, save_refused: 0, exif_rotated: 0, stopped: false, budget_stopped: false };
  let fails = 0;
  for (const r of rows) {
    if (now() - t0 > BUDGET_MS) { s.budget_stopped = true; break; }
    const tag = String(r.companion_id).slice(0, 8);
    let box: FaceBox;
    try {
      const bytes = await d.download(r.path);
      if (!bytes) box = NONE;                                  // photo gone: nothing to retry
      else if ((exifOrientation(bytes) ?? 1) !== 1) { box = NONE; s.exif_rotated++; } // box would be in a frame the app cannot know
      else {
        try { box = parseFaceReply(await d.vision(bytes, mimeFor(r.path))); }
        catch (e) { if (isBadImage(e)) box = NONE; else throw e; }
      }
    } catch {
      // transient (429, 5xx, network, timeout, storage error): leave the row null, retried next run. Never log the error text.
      s.skipped++; fails++;
      d.log(`id-face-locate skip ${tag}: transient`);
      if (fails >= MAX_CONSECUTIVE_FAILS) { s.stopped = true; break; }
      continue;
    }
    fails = 0;
    if (!(await d.save(r.companion_id, r.path, box))) { s.save_refused++; d.log(`id-face-locate save_refused ${tag}`); continue; } // replaced meanwhile, or refused
    if (box.src === 'none') s.none++; else s.saved++;
  }
  return s;
}
