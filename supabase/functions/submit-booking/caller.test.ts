// deno test --allow-read submit-booking/caller.test.ts
// s78 (TASKS #20b, #21): the hourly cap per hashed caller, and the calendar hold written before the request.
// The cap's counting rules are pgTAP (s78_direct_no_overlap_and_submit_cap.sql); this proves the function's side.
import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { callerHash, clientIp } from './caller.ts';
const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));

Deno.test('clientIp: cf-connecting-ip wins over a caller-written x-forwarded-for', () => {
  assertEquals(clientIp(new Headers({ 'cf-connecting-ip': '203.0.113.7', 'x-forwarded-for': '198.51.100.1, 203.0.113.7' })), '203.0.113.7');
  assertEquals(clientIp(new Headers({ 'x-real-ip': '2001:DB8::1' })), '2001:db8::1');
  assertEquals(clientIp(new Headers({ 'x-forwarded-for': ' 198.51.100.9 , 10.0.0.1' })), '198.51.100.9');
});

Deno.test('clientIp: nothing usable is null (the cap is skipped and logged, never a shared bucket)', () => {
  assertEquals(clientIp(new Headers()), null);
  assertEquals(clientIp(new Headers({ 'x-forwarded-for': 'unknown' })), null);
  assertEquals(clientIp(new Headers({ 'cf-connecting-ip': '1.2.3.4; drop table' })), null);
});

Deno.test('callerHash: 64 hex, keyed by the secret, stable per address', async () => {
  const a = await callerHash('secret-one', '203.0.113.7');
  assert(/^[0-9a-f]{64}$/.test(a), 'matches the table check');
  assertEquals(a, await callerHash('secret-one', '203.0.113.7'));
  assertNotEquals(a, await callerHash('secret-two', '203.0.113.7'));
  assertNotEquals(a, await callerHash('secret-one', '203.0.113.8'));
});

Deno.test('the cap runs after validation and before anything is written, and only the hash is sent', () => {
  const cap = src.indexOf("rpc('booking_submit_allowed_v1'");
  assert(cap > src.indexOf("'above_maximum_nights'"), 'after the request is validated');
  for (const w of ["rpc('supersede_pending_direct_requests_v1'", ".from('calendar_events').insert(", ".from('booking_inquiries').insert("]) {
    assert(cap < src.indexOf(w), `before ${w}`);
  }
  assert(/booking_submit_allowed_v1', \{ p_ip_hash: await callerHash\(SERVICE_KEY, callerIp\) \}/.test(src), 'the RPC gets the hash only');
  assert(/allowed === false\) \{[\s\S]{0,120}return json\(\{ error: 'too_many_requests' \}, 429\)/.test(src), 'refused is a 429');
  assert(/capErr\) console\.warn\([^\n]*request allowed/.test(src), 'a failed count lets the request through');
  assert(!/console\.(log|warn|error)\([^\n]*callerIp/.test(src), 'the address is never logged');
});

Deno.test('the calendar hold is written before the request, and a 23P01 is dates_unavailable with nothing else made', () => {
  const avail = src.indexOf(".rpc('check_availability'"), cal = src.indexOf(".from('calendar_events').insert("), inq = src.indexOf(".from('booking_inquiries').insert(");
  assert(avail > 0 && cal > avail && inq > cal, 'availability, then the hold, then the request');
  assert(/uid:\s+'direct:' \+ bookingId/.test(src) && /id:\s+bookingId,/.test(src), 'one id names both rows');
  const refuse = src.indexOf("ce?.code === '23P01') return json({ error: 'dates_unavailable', conflicts: [] }, 409)");
  assert(refuse > cal && refuse < inq, 'the race loser is refused before its request exists');
  assert(/if \(ie \|\| !inquiry\) \{[\s\S]{0,200}update\(\{ status: 'cancelled' \}\)[\s\S]{0,80}'direct:' \+ bookingId/.test(src), 'a failed request releases its hold');
  assertEquals(src.split(".from('calendar_events').insert(").length - 1, 1, 'one calendar insert');
});
