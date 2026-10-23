// id-face-locate logic (SPEC-47b). Pure: model text -> stored face box, and the run loop with injected deps.
// Privacy: the model is asked for coordinates only; nothing it says is logged, and only counts leave this file.
import { parseModelJson } from '../_shared/cascade-core/vision.ts';

export const FACE_PROMPT =
  'Find the largest human face in this photo. Reply with ONLY this JSON and nothing else: {"face":[ymin,xmin,ymax,xmax]} ' +
  'with each number an integer from 0 to 1000 (fractions of the image height and width), or {"face":null} when no face is visible. ' +
  'Do not read, mention or describe any name, number, text or other detail.';

export type FaceBox = { x: number; y: number; w: number; h: number; src: 'vision' } | { src: 'none' };
/** null = unusable reply: leave the row alone, it is retried next run. */
export type Parsed = FaceBox | null;

export const PAD = 0.35;       // each side, of the box size (hair, chin)
export const MIN_W = 0.02;     // box narrower than 2% of the image width = not a face
const r4 = (n: number) => Math.round(n * 10000) / 10000;
const clamp01 = (n: number) => Math.min(1, Math.max(0, n));

/** [ymin,xmin,ymax,xmax] on 0-1000 -> padded {x,y,w,h} 0-1 clamped to the image; tiny/inverted box -> none. */
export function boxFromModel(face: number[]): FaceBox {
  const [y0, x0, y1, x1] = face.map((n) => clamp01(n / 1000));
  const w = x1 - x0, h = y1 - y0;
  if (!(w >= MIN_W) || !(h > 0)) return { src: 'none' };
  const x = clamp01(x0 - w * PAD), y = clamp01(y0 - h * PAD);
  const xe = clamp01(x1 + w * PAD), ye = clamp01(y1 + h * PAD);
  const box = { x: r4(x), y: r4(y), w: r4(xe - x), h: r4(ye - y) };
  // rounding must never break the CHECK (x,y < 1; w,h > 0; x+w, y+h <= 1.0001)
  if (box.x >= 1 || box.y >= 1 || box.w <= 0 || box.h <= 0) return { src: 'none' };
  return { ...box, src: 'vision' };
}

export function parseFaceReply(text: string): Parsed {
  const j = parseModelJson<unknown>(text, null);
  if (!j || typeof j !== 'object' || !('face' in j)) return null;
  const f = (j as { face: unknown }).face;
  if (f === null) return { src: 'none' };
  if (!Array.isArray(f) || f.length !== 4 || !f.every((n) => typeof n === 'number' && Number.isFinite(n))) return null;
  return boxFromModel(f as number[]);
}

export function mimeFor(path: string): string {
  const e = path.toLowerCase().split('.').pop();
  return e === 'png' ? 'image/png' : e === 'webp' ? 'image/webp' : e === 'heic' ? 'image/heic' : 'image/jpeg';
}

export const MAX_CONSECUTIVE_FAILS = 3;

export type Todo = { companion_id: string; path: string };
export type Deps = {
  todo: () => Promise<Todo[]>;
  download: (path: string) => Promise<Uint8Array | null>;
  vision: (bytes: Uint8Array, mime: string) => Promise<string>;
  save: (id: string, path: string, box: FaceBox) => Promise<boolean>;
  log: (m: string) => void;
};
export type Summary = { todo: number; saved: number; none: number; skipped: number; stopped: boolean };

export async function run(d: Deps): Promise<Summary> {
  const rows = await d.todo();
  const s: Summary = { todo: rows.length, saved: 0, none: 0, skipped: 0, stopped: false };
  let fails = 0;
  for (const r of rows) {
    const tag = String(r.companion_id).slice(0, 8);
    try {
      const bytes = await d.download(r.path);
      if (!bytes) throw new Error('no_object');
      const parsed = parseFaceReply(await d.vision(bytes, mimeFor(r.path)));
      if (!parsed) throw new Error('unparsable');
      fails = 0;
      if (!(await d.save(r.companion_id, r.path, parsed))) { s.skipped++; continue; } // photo replaced meanwhile
      if (parsed.src === 'none') s.none++; else s.saved++;
    } catch (e) {
      s.skipped++; fails++;
      // only our own fixed reasons are logged; a vision/db error message could carry a path or model text
      d.log(`id-face-locate skip ${tag}: ${e instanceof Error && ['no_object', 'unparsable'].includes(e.message) ? e.message : 'error'}`);
      if (fails >= MAX_CONSECUTIVE_FAILS) { s.stopped = true; break; }
    }
  }
  return s;
}
