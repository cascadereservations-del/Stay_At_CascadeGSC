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

Deno.test('D-269: splitThread answers the guest lines after our last message; forHost drops the bot introduction', async () => {
  const { splitThread, forHost } = await import('./draft.ts');
  const s = splitThread([{ from: 'guest', text: 'Hi' }, { from: 'host', text: 'Hello Ana' }, { from: 'guest', text: 'Is party allowed?' }, { from: 'guest', text: 'for 5 friends' }]);
  assertEquals(s.latest, 'Is party allowed?\nfor 5 friends');
  assertEquals(s.before.length, 2);
  assertEquals(splitThread([{ from: 'guest', text: 'Hi po' }]).latest, 'Hi po');
  assertEquals(forHost("Hi Ana, thank you for reaching out. I'm Cassy, the home's digital concierge, here with Marifel and our team.\n\nThe night of Oct 3 is available."), "Hi Ana, thank you for reaching out.\n\nThe night of Oct 3 is available.");
});

Deno.test('D-270: forHost drops the bot-only "shared with our host" sentences (the host is the one sending)', async () => {
  const { forHost } = await import('./draft.ts');
  assertEquals(forHost("We're a quiet private retreat for registered guests. If you have a small occasion in mind, we've shared your message with our host, who will reply here personally."), "We're a quiet private retreat for registered guests.");
  assertEquals(forHost('For 30 nights it comes to PHP 40,050. Our host also looks at special requests personally, so we have shared your message with them.\n\nWhich dates suit you?'), 'For 30 nights it comes to PHP 40,050.\n\nWhich dates suit you?');
});
