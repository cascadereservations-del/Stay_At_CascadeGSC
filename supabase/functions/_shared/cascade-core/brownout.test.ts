// deno test supabase/functions/_shared/cascade-core/brownout.test.ts - the callback payloads the brownout and task cards carry.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { brownoutUid, nightsList, nightsPhrase, parsePwTap, parseTaskTap, pwData, releasable, rpcMissing, validYmd, type NoticeState } from './brownout.ts';

Deno.test('pw taps: three actions on a real date, nothing else', () => {
  assertEquals(parsePwTap('pw:done:2026-10-15'), { kind: 'done', date: '2026-10-15' });
  assertEquals(parsePwTap('pw:undo:2026-10-15'), { kind: 'undo', date: '2026-10-15' });
  assertEquals(parsePwTap('pw:unblock:2026-10-15'), { kind: 'unblock', date: '2026-10-15' });
  for (const bad of ['pw:done:2026-13-45', 'pw:done:2026-02-30', 'pw:done:20261015', 'pw:remove:2026-10-15', 'pw:done:2026-10-15:x', 'pw:done:', 'pw:done:2026-10-15 ', 'xpw:done:2026-10-15', '', 'pw:DONE:2026-10-15'])
    assertEquals(parsePwTap(bad), null, bad);
  assertEquals(pwData('unblock', '2026-10-15'), 'pw:unblock:2026-10-15');
});

Deno.test('task taps: stc needs a 6-12 character A-Z0-9 code, crm needs a uuid, both a real date', () => {
  assertEquals(parseTaskTap('stc:done:2026-10-15:HMABC123XY'), { kind: 'stc', date: '2026-10-15', ref: 'HMABC123XY', sourceKind: 'stay_continues', sourceRef: '2026-10-15:HMABC123XY' });
  const id = '3f2b8c1e-5a4d-4e7a-9b61-0c2d8e4f7a10';
  assertEquals(parseTaskTap(`crm:done:2026-10-15:${id}`), { kind: 'crm', date: '2026-10-15', ref: id, sourceKind: 'guest_details', sourceRef: `2026-10-15:${id}` });
  assertEquals(parseTaskTap(`crm:done:2026-10-15:${id.toUpperCase()}`)?.ref, id, 'uuid is lower-cased');
  for (const bad of ['stc:done:2026-10-15:abc', 'stc:done:2026-10-15:ABC12', 'stc:done:2026-10-15:ABCDEFGHIJKLM', 'stc:done:2026-10-15:abcdef12', 'stc:done:2026-10-15:HM-ABC123',
    'stc:done:2026-10-15:HMABC123;', 'stc:done:2026-13-15:HMABC123', 'stc:done:2026-10-15', 'stc:undo:2026-10-15:HMABC123',
    'crm:done:2026-10-15:not-a-uuid', 'crm:done:2026-10-15:HMABC123', `crm:done:2026-10-15:${id}0`, `crm:done:2026-10-32:${id}`, `crm:done:2026-10-15:${id}:x`, `stc:done:2026-10-15:${id}`, '', 'crm:done:'])
    assertEquals(parseTaskTap(bad), null, bad);
  // Telegram caps callback_data at 64 bytes
  assert(new TextEncoder().encode(`crm:done:2026-10-15:${id}`).length <= 64);
  assert(new TextEncoder().encode('stc:done:2026-10-15:ABCDEFGHIJKL').length <= 64);
});

Deno.test('dates and wording', () => {
  assertEquals([validYmd('2026-10-15'), validYmd('2026-02-30'), validYmd('2026-1-5'), validYmd(null)], [true, false, false, false]);
  assertEquals(nightsList(['2026-10-14']), 'Oct 14');
  assertEquals(nightsList(['2026-10-14', '2026-10-15', '2026-10-16']), 'Oct 14, Oct 15 and Oct 16');
  assertEquals(nightsPhrase(['2026-10-14']), 'night of Oct 14');
  assertEquals(nightsPhrase(['2026-10-14', '2026-10-15']), 'nights of Oct 14 and Oct 15');
  assertEquals(brownoutUid('2026-10-14'), 'brownout:2026-10-14');
});

Deno.test('rpcMissing: a function that is not deployed yet is not a failure, a real error is', () => {
  assert(rpcMissing({ code: 'PGRST202', message: 'x' }));
  assert(rpcMissing({ code: '42883', message: 'function system_task_close_v1 does not exist' }));
  assert(rpcMissing({ message: 'Could not find the function public.system_task_close_v1' }));
  assert(!rpcMissing({ code: '23505', message: 'duplicate key' }));
  assert(!rpcMissing(null));
});

Deno.test('releasable keeps a night another active notice still holds', () => {
  const s = (date: string, blocked: string[], status: NoticeState['status'] = 'active') => ({ date, blocked, status }) as NoticeState;
  const a = s('2026-10-15', ['2026-10-14', '2026-10-15']), b = s('2026-10-14', ['2026-10-14']);
  assertEquals(releasable(a, [a, b]), ['2026-10-15']);
  assertEquals(releasable(a, [a, s('2026-10-14', ['2026-10-14'], 'undone')]), ['2026-10-14', '2026-10-15'], 'an undone notice holds nothing');
});
