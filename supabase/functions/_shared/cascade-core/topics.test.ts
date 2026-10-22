// deno test --no-check supabase/functions/_shared/cascade-core/topics.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { recordTopics, TOPICS, topicsForTurn, topicsFromText } from './topics.ts';

Deno.test('the eleven contract keys, in order', () => {
  assertEquals([...TOPICS], ['directions', 'links', 'wifi', 'brownout', 'guest_count', 'early_checkin', 'late_checkout', 'parking', 'pets', 'id', 'complaint']);
});

Deno.test('topicsFromText: English, Tagalog and Bisaya wordings', () => {
  const cases: Array<[string, string[]]> = [
    ['Hi, what is the exact location?', ['directions']],
    ['Saan po ang pin ninyo?', ['directions']],
    ['Is there a brownout schedule?', ['brownout']],
    ['Nawalan ng kuryente po', ['brownout']],
    ['Walay kuryente diri', ['brownout']],
    ['How many people can stay? Extra person fee?', ['guest_count']],
    ['pwede po ba early check-in at 10am?', ['early_checkin']],
    ['Can we do a late checkout?', ['late_checkout']],
    ['Where do we park the van?', ['parking']],
    ['May aso po kami, allowed ba?', ['pets']],
    ['Do you need a valid ID?', ['id']],
    ['wifi password please', ['wifi']],
    ['send me the guest guide link', ['links']],
    ['the aircon is not working and it is dirty', ['complaint']],
    ['Wifi and parking?', ['wifi', 'parking']],
    ['maximum 4 guests ba?', ['guest_count']],
    ['Ilan po ang pwede na tao?', ['guest_count']],
    ['we will park outside', ['parking']],
    ['Can we check in at 11am?', ['early_checkin']],
    ['check out at 2pm', ['late_checkout']],
    ['can you send the pin?', ['directions']],
    ['the exact address please', ['directions']],
    ['power is out since 8', ['brownout']],
    ['Can we extend our stay by a day?', ['late_checkout']],
    ['maaga kaming dumating bukas', ['early_checkin']],
    // A TV that does not work is a real issue: complaint is intended here.
    ['the TV is not working', ['complaint']],
    ['the room smells bad and mabaho ang CR', ['complaint']],
  ];
  for (const [t, want] of cases) assertEquals(topicsFromText(t), want, t);
});

Deno.test('topicsFromText: nothing for small talk, empty text or look-alike words', () => {
  assertEquals(topicsFromText(''), []);
  assertEquals(topicsFromText('Thank you, see you on the 10th!'), []);
  assertEquals(topicsFromText('We are spinning the kid, dogged by traffic'), [], 'pin / dog inside other words');
  for (const t of ['Do you have a power outlet by the bed?', 'is there a power bank?', 'what is the door pin code?', 'The place was not dirty at all, very clean',
    'the smell of food nearby', 'sira ulo ako haha', 'check in at 3pm', 'check out at 11am', 'we have an extension cord', 'asa ka na?', 'your website is nice', 'strong signal at the beach',
    'what time is the grocery open?', 'nothing was broken', 'no leaks at all', 'it smells like home']) assertEquals(topicsFromText(t), [], t);
});

Deno.test('topicsForTurn: a sure Jev intent adds its topic, an unsure one does not, Jev down uses words', () => {
  assertEquals(topicsForTurn('how do I get there', { intent: 'directions', confidence: 0.9 }), ['directions']);
  assertEquals(topicsForTurn('hello', { intent: 'directions', confidence: 0.5 }), []);
  assertEquals(topicsForTurn('walay tubig', { intent: 'complaint', confidence: 0.95 }), ['complaint']);
  assertEquals(topicsForTurn('the TV is not working', null), [], 'Messenger takes complaint from Jev alone');
  assertEquals(topicsForTurn('wifi?', null), ['wifi']);
  assertEquals(topicsForTurn('price for 2 nights', { intent: 'price', confidence: 1 }), []);
});

Deno.test('recordTopics: one rpc per topic with the contract args; no guest or no topic = no call', async () => {
  const calls: any[] = [];
  const db = { rpc: (fn: string, a: Record<string, unknown>) => { calls.push([fn, a]); return Promise.resolve({ error: null }); } };
  await recordTopics(db, 'g1', 'b1', ['wifi', 'pets'], 'messenger');
  assertEquals(calls, [['record_guest_topic_v1', { p_guest_id: 'g1', p_booking_id: 'b1', p_topic: 'wifi', p_source: 'messenger' }], ['record_guest_topic_v1', { p_guest_id: 'g1', p_booking_id: 'b1', p_topic: 'pets', p_source: 'messenger' }]]);
  await recordTopics(db, null, null, ['wifi'], 'airbnb'); await recordTopics(db, 'g1', null, [], 'airbnb');
  assertEquals(calls.length, 2);
});

Deno.test('recordTopics never rejects: a throwing or erroring rpc still resolves', async () => {
  await recordTopics({ rpc: () => { throw new Error('boom'); } }, 'g1', null, ['wifi'], 'airbnb');
  await recordTopics({ rpc: () => Promise.reject(new Error('down')) }, 'g1', null, ['wifi'], 'airbnb');
  await recordTopics({ rpc: () => Promise.resolve({ error: { message: 'x' } }) }, 'g1', null, ['wifi', 'pets'], 'airbnb');
  assert(true);
});
