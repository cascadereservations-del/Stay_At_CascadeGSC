import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { draftRequest } from './draft.ts';

Deno.test('draftRequest recognises the reply/draft/how-should-I-answer forms', () => {
  assertEquals(draftRequest('reply: Hi po, available ba Oct 3-4?'), { draft: true, text: 'Hi po, available ba Oct 3-4?' });
  assertEquals(draftRequest('draft'), { draft: true, text: '' });
  assertEquals(draftRequest('how should I answer this: pwede pets?'), { draft: true, text: 'pwede pets?' });
  assertEquals(draftRequest('what do we say: may discount?').draft, true);
  assertEquals(draftRequest('who is Queenie Gonzales?').draft, false);
  assertEquals(draftRequest('status').draft, false);
});
