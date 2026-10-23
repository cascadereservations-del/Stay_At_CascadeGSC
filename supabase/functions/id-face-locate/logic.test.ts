import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { boxFromModel, parseFaceReply, run, mimeFor, type Deps, type FaceBox } from './logic.ts';

Deno.test('conversion + 35% padding (hand computed)', () => {
  // face y 200-400, x 300-500 -> w=h=0.2, pad 0.07: x .23, y .13, w .34, h .34
  assertEquals(boxFromModel([200, 300, 400, 500]), { x: 0.23, y: 0.13, w: 0.34, h: 0.34, src: 'vision' });
});
Deno.test('padding clamps to the image', () => {
  // y 0-200, x 800-1000: w=h=.2, pad .07 -> x .73, y 0, xe 1, ye .27
  assertEquals(boxFromModel([0, 800, 200, 1000]), { x: 0.73, y: 0, w: 0.27, h: 0.27, src: 'vision' });
});
Deno.test('tiny box (<2% width) -> none', () => {
  assertEquals(boxFromModel([100, 100, 300, 119]), { src: 'none' });
});
Deno.test('inverted box -> none', () => {
  assertEquals(boxFromModel([400, 500, 200, 300]), { src: 'none' });
});
Deno.test('null face -> none', () => {
  assertEquals(parseFaceReply('{"face":null}'), { src: 'none' });
});
Deno.test('fenced json parses', () => {
  assertEquals(parseFaceReply('```json\n{"face":[200,300,400,500]}\n```'), { x: 0.23, y: 0.13, w: 0.34, h: 0.34, src: 'vision' });
});
Deno.test('garbage / wrong shape -> null (retried)', () => {
  for (const t of ['', 'sorry I cannot', '{}', '{"face":"x"}', '{"face":[1,2,3]}', '{"face":[1,2,3,null]}', '[1,2,3,4]']) assertEquals(parseFaceReply(t), null, t);
});
Deno.test('mime by extension', () => {
  assertEquals([mimeFor('a/b.PNG'), mimeFor('x.webp'), mimeFor('x.jpg'), mimeFor('x')], ['image/png', 'image/webp', 'image/jpeg', 'image/jpeg']);
});

const deps = (replies: Array<string | Error>, saved: Array<[string, FaceBox]> = [], logs: string[] = []): Deps => {
  let i = 0;
  return {
    todo: () => Promise.resolve(replies.map((_, k) => ({ companion_id: `abcdef12-0000-0000-0000-00000000000${k}`, path: `p${k}.jpg` }))),
    download: () => Promise.resolve(new Uint8Array([1])),
    vision: () => { const r = replies[i++]; return r instanceof Error ? Promise.reject(r) : Promise.resolve(r); },
    save: (id, _p, b) => { saved.push([id, b]); return Promise.resolve(true); },
    log: (m) => logs.push(m),
  };
};

Deno.test('run: saves boxes and none, skips garbage, logs no content', async () => {
  const saved: Array<[string, FaceBox]> = [], logs: string[] = [];
  const s = await run(deps(['{"face":[200,300,400,500]}', '{"face":null}', 'blah SECRET NAME', '{"face":[200,300,400,500]}'], saved, logs));
  assertEquals(s, { todo: 4, saved: 2, none: 1, skipped: 1, stopped: false });
  assertEquals(saved.length, 3);
  assertEquals(logs.length, 1);
  assertEquals(logs[0].includes('SECRET'), false);
  assertEquals(logs[0].includes('p2.jpg'), false);
});
Deno.test('run: a vision error message never reaches the log', async () => {
  const logs: string[] = [];
  await run(deps([new Error('openrouter_500: /guest-id-photos/PATH Juan'), '{"face":null}'], [], logs));
  assertEquals(logs.length, 1);
  assertEquals(logs[0].includes('Juan'), false);
});
Deno.test('run: 3 consecutive failures stop the run', async () => {
  const saved: Array<[string, FaceBox]> = [];
  const s = await run(deps([new Error('openrouter_500'), 'junk', new Error('x'), '{"face":null}'], saved));
  assertEquals(s, { todo: 4, saved: 0, none: 0, skipped: 3, stopped: true });
  assertEquals(saved.length, 0);
});
Deno.test('run: a success resets the failure streak', async () => {
  const s = await run(deps(['junk', 'junk', '{"face":null}', 'junk', 'junk', '{"face":null}']));
  assertEquals(s.stopped, false);
  assertEquals(s.none, 2);
});
Deno.test('run: replaced photo (save false) counts as skipped, not a failure', async () => {
  const d = deps(['{"face":null}', '{"face":null}', '{"face":null}', '{"face":null}']);
  d.save = () => Promise.resolve(false);
  const s = await run(d);
  assertEquals(s, { todo: 4, saved: 0, none: 0, skipped: 4, stopped: false });
});
