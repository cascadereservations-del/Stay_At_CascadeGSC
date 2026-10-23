import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { boxFromModel, parseFaceReply, run, mimeFor, exifOrientation, providerStatus, isBadImage, NONE, type Deps, type FaceBox } from './logic.ts';

// JS copy of the SQL CHECK on guest_companions.id_face_box
const CHECK = (b: FaceBox) => {
  const keys = Object.keys(b).sort().join();
  return keys === 'h,src,w,x,y' && (b.src === 'vision' || b.src === 'none') && b.x >= 0 && b.y >= 0 && b.x < 1 && b.y < 1 &&
    b.w > 0 && b.h > 0 && b.w <= 1 && b.h <= 1 && b.x + b.w <= 1.0001 && b.y + b.h <= 1.0001;
};

Deno.test('conversion + 35% padding (hand computed)', () => {
  // face y 200-400, x 300-500 -> w=h=0.2, pad 0.07: x .23, y .13, w .34, h .34
  assertEquals(boxFromModel([200, 300, 400, 500]), { x: 0.23, y: 0.13, w: 0.34, h: 0.34, src: 'vision' });
});
Deno.test('padding clamps to the image', () => {
  // y 0-200, x 800-1000: w=h=.2, pad .07 -> x .73, y 0, xe 1, ye .27
  assertEquals(boxFromModel([0, 800, 200, 1000]), { x: 0.73, y: 0, w: 0.27, h: 0.27, src: 'vision' });
});
Deno.test('tiny box (<2% width) -> none', () => {
  assertEquals(boxFromModel([100, 100, 300, 119]), NONE);
});
Deno.test('too short (<2% height) -> none', () => {
  assertEquals(boxFromModel([300, 300, 310, 600]), NONE);
});
Deno.test('0-1 scale reply is read as fractions', () => {
  assertEquals(boxFromModel([0.2, 0.3, 0.4, 0.5]), { x: 0.23, y: 0.13, w: 0.34, h: 0.34, src: 'vision' });
});
Deno.test('inverted axes are swapped, not discarded', () => {
  assertEquals(boxFromModel([400, 500, 200, 300]), { x: 0.23, y: 0.13, w: 0.34, h: 0.34, src: 'vision' });
});
Deno.test('fenced json parses', () => {
  assertEquals(parseFaceReply('```json\n{"face":[200,300,400,500]}\n```'), { x: 0.23, y: 0.13, w: 0.34, h: 0.34, src: 'vision' });
});
Deno.test('null face / garbage / wrong shape -> none (whole-image numbers, src none)', () => {
  for (const t of ['{"face":null}', '', 'sorry I cannot', '{}', '{"face":"x"}', '{"face":[1,2,3]}', '{"face":[1,2,3,null]}', '[1,2,3,4]']) assertEquals(parseFaceReply(t), NONE, t);
});
Deno.test('every output passes a JS copy of the SQL CHECK', () => {
  const faces: number[][] = [[200, 300, 400, 500], [0, 800, 200, 1000], [0, 0, 1000, 1000], [999, 999, 1000, 1000], [100, 100, 300, 119], [400, 500, 200, 300],
    [-50, -50, 2000, 2000], [0.2, 0.3, 0.4, 0.5], [0, 0, 1, 1], [500, 500, 500, 500], [1000, 1000, 1000, 1000], [0, 0, 0, 0], [300, 300, 310, 600]];
  for (const f of faces) assertEquals(CHECK(boxFromModel(f)), true, JSON.stringify(f));
  for (const t of ['{"face":null}', 'junk', '{"face":[200,300,400,500]}']) assertEquals(CHECK(parseFaceReply(t)), true, t);
  assertEquals(CHECK(NONE), true);
});
Deno.test('mime by extension', () => {
  assertEquals([mimeFor('a/b.PNG'), mimeFor('x.webp'), mimeFor('x.jpg'), mimeFor('x')], ['image/png', 'image/webp', 'image/jpeg', 'image/jpeg']);
});

// ---- EXIF orientation: hand-built JPEG headers
const exif = (le: boolean, orient: number | null): Uint8Array => {
  const u16 = (n: number) => (le ? [n & 255, n >> 8] : [n >> 8, n & 255]);
  const u32 = (n: number) => (le ? [n & 255, (n >> 8) & 255, 0, 0] : [0, 0, (n >> 8) & 255, n & 255]);
  const entry = orient === null ? [...u16(0x011a), ...u16(3), ...u32(1), ...u16(72), 0, 0] : [...u16(0x0112), ...u16(3), ...u32(1), ...u16(orient), 0, 0];
  const tiff = [le ? 0x49 : 0x4d, le ? 0x49 : 0x4d, ...u16(42), ...u32(8), ...u16(1), ...entry, 0, 0, 0, 0];
  const body = [0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff];
  const len = body.length + 2;
  return new Uint8Array([0xff, 0xd8, 0xff, 0xe1, len >> 8, len & 255, ...body, 0xff, 0xda, 0, 2]);
};
Deno.test('exif: Orientation 1, 6 (big endian), 8 (little endian)', () => {
  assertEquals(exifOrientation(exif(false, 1)), 1);
  assertEquals(exifOrientation(exif(false, 6)), 6);
  assertEquals(exifOrientation(exif(true, 8)), 8);
});
Deno.test('exif: no APP1, no Orientation tag, PNG, empty -> null', () => {
  assertEquals(exifOrientation(new Uint8Array([0xff, 0xd8, 0xff, 0xda, 0, 2, 0, 0])), null);
  assertEquals(exifOrientation(exif(false, null)), null);
  assertEquals(exifOrientation(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), null);
  assertEquals(exifOrientation(new Uint8Array([])), null);
});
Deno.test('provider status: bad image vs transient', () => {
  assertEquals(providerStatus(new Error('openrouter_400: {"error":"x"}')), 400);
  assertEquals(providerStatus(new Error('timeout')), null);
  assertEquals([400, 413, 415, 422].every((c) => isBadImage(new Error(`gemini_${c}: x`))), true);
  assertEquals([401, 403, 404, 429, 500, 503].some((c) => isBadImage(new Error(`openrouter_${c}: x`))), false);
});

// ---- run loop
const JPG = new Uint8Array([0xff, 0xd8, 0xff, 0xda, 0, 2]);
const deps = (replies: Array<string | Error>, saved: Array<[string, FaceBox]> = [], logs: string[] = []): Deps => {
  let i = 0;
  return {
    todo: () => Promise.resolve(replies.map((_, k) => ({ companion_id: `abcdef12-0000-0000-0000-00000000000${k}`, path: `p${k}.jpg` }))),
    download: () => Promise.resolve(JPG),
    vision: () => { const r = replies[i++]; return r instanceof Error ? Promise.reject(r) : Promise.resolve(r); },
    save: (id, _p, b) => { saved.push([id, b]); return Promise.resolve(true); },
    log: (m) => logs.push(m),
  };
};
const S = (o: Record<string, unknown>) => ({ todo: 0, saved: 0, none: 0, skipped: 0, save_refused: 0, exif_rotated: 0, stopped: false, budget_stopped: false, ...o });

Deno.test('run: boxes and none saved; garbage reply is none (no retry); every payload passes CHECK; no content logged', async () => {
  const saved: Array<[string, FaceBox]> = [], logs: string[] = [];
  const s = await run(deps(['{"face":[200,300,400,500]}', '{"face":null}', 'blah SECRET NAME'], saved, logs));
  assertEquals(s, S({ todo: 3, saved: 1, none: 2 }));
  assertEquals(saved.every(([, b]) => CHECK(b)), true);
  assertEquals(logs.join().includes('SECRET'), false);
});
Deno.test('run: provider 4xx for the image -> none; transient error logs no error text', async () => {
  const saved: Array<[string, FaceBox]> = [], logs: string[] = [];
  const s = await run(deps([new Error('openrouter_400: bad image Juan /guest-id-photos/x'), new Error('openrouter_429: Juan'), '{"face":null}'], saved, logs));
  assertEquals(s, S({ todo: 3, none: 2, skipped: 1 }));
  assertEquals(saved[0][1], NONE);
  assertEquals(logs.length, 1);
  assertEquals(logs[0].includes('Juan'), false);
});
Deno.test('run: object gone -> none', async () => {
  const saved: Array<[string, FaceBox]> = [];
  const d = deps(['x'], saved);
  d.download = () => Promise.resolve(null);
  assertEquals(await run(d), S({ todo: 1, none: 1 }));
  assertEquals(saved[0][1], NONE);
});
Deno.test('run: download throw is transient and counts toward the stop', async () => {
  const d = deps(['x', 'x', 'x', 'x']);
  d.download = () => Promise.reject(new Error('storage down'));
  assertEquals(await run(d), S({ todo: 4, skipped: 3, stopped: true }));
});
Deno.test('run: 3 consecutive transient failures stop the run', async () => {
  const saved: Array<[string, FaceBox]> = [];
  const s = await run(deps([new Error('openrouter_500'), new Error('network'), new Error('gemini_503'), '{"face":null}'], saved));
  assertEquals(s, S({ todo: 4, skipped: 3, stopped: true }));
  assertEquals(saved.length, 0);
});
Deno.test('run: a success resets the failure streak', async () => {
  const e = new Error('openrouter_500');
  const s = await run(deps([e, e, '{"face":null}', e, e, '{"face":null}']));
  assertEquals(s, S({ todo: 6, none: 2, skipped: 4 }));
});
Deno.test('run: save false is counted and logged as save_refused', async () => {
  const logs: string[] = [];
  const d = deps(['{"face":null}', '{"face":null}'], [], logs);
  d.save = () => Promise.resolve(false);
  assertEquals(await run(d), S({ todo: 2, save_refused: 2 }));
  assertEquals(logs.length, 2);
  assertEquals(logs[0].includes('save_refused'), true);
});
Deno.test('run: rotated EXIF photo -> none without calling vision', async () => {
  const d = deps([]);
  d.todo = () => Promise.resolve([{ companion_id: 'abcdef12-0', path: 'a.jpg' }, { companion_id: 'abcdef12-1', path: 'b.jpg' }]);
  const files = [exif(false, 6), exif(false, 1)];
  let k = 0, calls = 0;
  d.download = () => Promise.resolve(files[k++]);
  d.vision = () => { calls++; return Promise.resolve('{"face":null}'); };
  assertEquals(await run(d), S({ todo: 2, none: 2, exif_rotated: 1 }));
  assertEquals(calls, 1);
});
Deno.test('run: stops picking rows after the 35 s budget (one slow call still fits the 150 s wall clock)', async () => {
  let t = 0;
  const d = deps(['{"face":null}', '{"face":null}', '{"face":null}']);
  d.now = () => t;
  const v = d.vision;
  d.vision = (b, m) => { t += 20_000; return v(b, m); };
  assertEquals(await run(d), S({ todo: 3, none: 2, budget_stopped: true }));
});
Deno.test('run: 3 provider 400s in a row (bad key looks like a bad image) stop the run and save nothing', async () => {
  const saved: Array<[string, FaceBox]> = [];
  const e = new Error('gemini_400: API_KEY_INVALID');
  const s = await run(deps([e, e, e, '{"face":[200,300,400,500]}'], saved));
  assertEquals(s, S({ todo: 4, stopped: true }));
  assertEquals(saved.length, 0);
});
Deno.test('run: held bad-image nones are saved once a later row succeeds or the run ends', async () => {
  const saved: Array<[string, FaceBox]> = [];
  const e = new Error('openrouter_400: bad image');
  assertEquals(await run(deps([e, e, '{"face":[200,300,400,500]}'], saved)), S({ todo: 3, none: 2, saved: 1 }));
  assertEquals(saved.map(([, b]) => b.src), ['none', 'none', 'vision']);
  const tail: Array<[string, FaceBox]> = [];
  assertEquals(await run(deps(['{"face":null}', e], tail)), S({ todo: 2, none: 2 }));
});
