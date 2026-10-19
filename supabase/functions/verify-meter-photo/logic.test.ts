import { asVisionResult, isPrecheckBody, ownsPath, precheckOutcome, type VisionResult } from './logic.ts';

const P = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const U = '50ccca5a-3e59-4299-9680-837fd8d88ac4';
const eq = (a: unknown, b: unknown, m: string) => { if (a !== b) throw new Error(`${m}: expected ${b}, got ${a}`); };
const read = (o: Partial<VisionResult> = {}): VisionResult => ({ is_meter: true, meter_type: 'electric', reading: 12345, confidence: 0.9, note: '', ...o });

Deno.test('pass: clear read, nothing typed', () => {
  const r = precheckOutcome(read(), 'electric', null);
  eq(r.status, 'pass', 'status'); eq(r.reading, 12345, 'reading'); eq(r.message, 'Photo looks clear - reading 12,345.', 'message');
});
Deno.test('pass: typed agrees within tolerance', () => { eq(precheckOutcome(read(), 'electric', 12346).status, 'pass', 'within 2 kWh'); });
Deno.test('check_number: typed disagrees', () => {
  const r = precheckOutcome(read(), 'electric', 12354);
  eq(r.status, 'check_number', 'status'); eq(r.message, 'The photo reads 12,345 but you typed 12,354. Please check the number.', 'message');
});
Deno.test('water: decimal point shift and whole part both agree', () => {
  eq(precheckOutcome(read({ reading: 708 }), 'water', 70.873).status, 'pass', 'shift');
  eq(precheckOutcome(read({ reading: 68 }), 'water', 68.827).status, 'pass', 'whole part');
  eq(precheckOutcome(read({ reading: 3814 }), 'water', 3832).status, 'check_number', 'different digits');
});
Deno.test('retake: not a meter, null reading, low confidence', () => {
  eq(precheckOutcome(read({ is_meter: false }), 'electric', 1).status, 'retake', 'not a meter');
  eq(precheckOutcome(read({ reading: null }), 'electric', null).status, 'retake', 'null');
  eq(precheckOutcome(read({ confidence: 0.54 }), 'electric', null).status, 'retake', 'low confidence');
  eq(precheckOutcome(read({ confidence: 0.55 }), 'electric', null).status, 'pass', 'at the floor');
});
Deno.test('unavailable: provider failed or timed out (null)', () => {
  eq(precheckOutcome(null, 'water', 5).status, 'unavailable', 'status');
  eq(precheckOutcome(null, 'water', 5).message.includes('!'), false, 'no exclamation');
});
Deno.test('ownsPath: only <property>/<own user>/<submission>/<file>', () => {
  const ok = `${P}/${U}/11111111-1111-1111-1111-111111111111/a-b.jpg`;
  eq(ownsPath(ok, P, U), true, 'own');
  eq(ownsPath(ok.replace(U, 'fea44ac5-61b0-41a6-8616-d7823e99151b'), P, U), false, 'other user');
  eq(ownsPath(ok.replace(P, 'other'), P, U), false, 'other property');
  eq(ownsPath(`${P}/${U}/../x/y.jpg`, P, U), false, 'traversal');
  eq(ownsPath(`${P}/${U}/x.jpg`, P, U), false, 'too short');
  eq(ownsPath(`/${ok}`, P, U), false, 'leading slash');
  eq(ownsPath(undefined, P, U), false, 'not a string');
});
Deno.test('auth branch: only mode precheck leaves the cron gate', () => {
  eq(isPrecheckBody({ mode: 'precheck' }), true, 'precheck');
  eq(isPrecheckBody({}), false, 'empty'); eq(isPrecheckBody({ mode: 'sweep' }), false, 'other'); eq(isPrecheckBody(null), false, 'null');
});
Deno.test('asVisionResult rejects malformed cache rows', () => {
  eq(asVisionResult(null), null, 'null'); eq(asVisionResult({ reading: 1 }), null, 'no is_meter');
  eq(asVisionResult(read())?.reading, 12345, 'good');
});
