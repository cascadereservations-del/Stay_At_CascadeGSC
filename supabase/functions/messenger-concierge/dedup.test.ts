// deno test --no-check --allow-env messenger-concierge/dedup.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';

const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));

/* SPEC-06 section 4. The guard's whole value is WHERE it sits: this function answers synchronously
   before returning 200, so a retried webhook must be dropped before anything is sent, named or
   charged for. These assertions fail if someone moves it below an effect. */

Deno.test('a retried webhook is dropped before any work is done', () => {
  const handle = src.slice(src.indexOf('async function handle('));
  const guard = handle.indexOf('msg.mid === thread.last_mid');
  assertEquals(guard > -1, true, 'the mid guard is gone');

  // It must come after the thread is loaded (it needs last_mid) and before the first outward effect.
  const load = handle.indexOf(".from('concierge_threads').select('*')");
  assertEquals(load > -1 && load < guard, true, 'the guard must read the loaded thread');

  for (const effect of ['fx.name(', 'fx.send(', 'fx.ops(']) {
    const at = handle.indexOf(effect);
    if (at > -1) assertEquals(guard < at, true, `the guard must precede ${effect}`);
  }
});

Deno.test('the mid is remembered, or the guard can never fire twice', () => {
  assertEquals(/last_mid: msg\.mid \?\? thread\.last_mid \?\? null/.test(src), true);
  // Falling back to the stored value matters: a message without a mid must not erase the last one.
  assertEquals(/type Thread = .*last_mid\?: string \| null/.test(src), true);
});

Deno.test('the duplicate is logged, so a double reply can be traced afterwards', () => {
  assertEquals(src.includes("console.log('duplicate_mid_ignored'"), true);
});

Deno.test('D-222 P0: a failed thread read stops the turn instead of overwriting the history with a blank one', () => {
  const handle = src.slice(src.indexOf('async function handle('));
  assertEquals(/if \(rowErr\) throw new Error\('thread_read_failed/.test(handle), true);
});

Deno.test('D-222 P0: any failed event reaches the host, so no guest message ends in silence', () => {
  assertEquals(src.includes("console.error('concierge_event_failed'"), true);
  assertEquals(/concierge_event_failed[\s\S]{0,400}liveEffects\.ops\(/.test(src), true);
});
