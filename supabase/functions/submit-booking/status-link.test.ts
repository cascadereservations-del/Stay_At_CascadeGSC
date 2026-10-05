// deno test --allow-read submit-booking/status-link.test.ts
// SPEC-42 s6: submit-booking mints the status token after the request exists, returns the link to the guest only, and never
// puts it in a Telegram card or the e-mail relay (sending the link to guests is a later wave, by an explicit host tap).
import { assert } from 'https://deno.land/std@0.224.0/assert/mod.ts';
const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));

Deno.test('the token is minted after the inquiry insert and a failure never fails the booking', () => {
  const insert = src.indexOf(".from('booking_inquiries').insert("), mint = src.indexOf('mintStatusToken(');
  assert(insert > 0 && mint > insert, 'mint comes after the booking exists');
  assert(/mintStatusToken\([\s\S]{0,260}\.catch\(\(\) => null\)/.test(src), 'a mint failure is swallowed (no link, booking still created)');
});

Deno.test('status_url is returned in the response and stays out of Telegram and the e-mail relay', () => {
  assert(/status_url:\s+statusToken \? STATUS_PAGE \+ statusToken : null/.test(src), 'response carries status_url');
  const uses = [...src.matchAll(/statusToken|STATUS_PAGE/g)].map((m) => m.index!);
  const notify = src.indexOf('async function notifyTelegram'), response = src.indexOf('return json({\n    ok:') >= 0 ? src.indexOf('return json({\n    ok:') : src.indexOf('return json({\r\n    ok:');
  assert(response > 0, 'found the success response');
  for (const at of uses) assert(at < notify || at > response, 'statusToken is not used inside the notification or relay functions');
  assert(!/console\.(log|error|warn)\([^)]*statusToken/.test(src), 'the token is never logged');
});

Deno.test('the link keeps the token in the fragment', () => {
  assert(src.includes("stay.html#t='"), 'fragment, never a query string');
});
