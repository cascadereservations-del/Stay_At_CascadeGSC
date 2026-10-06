// deno test --no-check messenger-concierge/golden-failed.test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { failedIds } from './golden-score.ts';

Deno.test('failedIds: any ❌ row selects its conversation once; ✅-only and escaped pipes do not', () => {
  const md = [
    '| Conversation | Run | Turn | Guest | Reply | Result |', '|---|---|---|---|---|---|',
    '| a-ok | 1 | 1 | hi | Hello \\| ❌ not a result | ✅ |',
    '| b-bad | 1 | 1 | hi | x | ❌ P: no |', '| b-bad | 2 | 1 | hi | x | ❌ P: no |',
    '| c-mixed | 1 | 1 | hi | x | ✅ |', '| c-mixed | 3 | 2 | hi | x | ❌ E: lost |',
    '| d-probe | 1 | 0 | - |  | ❌ probe failed: HTTP 500 |',
  ].join('\n');
  assertEquals(failedIds(md), ['b-bad', 'c-mixed', 'd-probe']);
  assertEquals(failedIds('# Golden run\n\n**3 / 3 pass**'), []);
});
