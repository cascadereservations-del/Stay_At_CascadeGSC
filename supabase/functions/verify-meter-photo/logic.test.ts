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
Deno.test('ownsPath: only the exact upload-photo layout', () => {
  const sub = '11111111-1111-1111-1111-111111111111';
  const ok = `${P}/${U}/${sub}/${sub}-meter-1.jpg`;
  eq(ownsPath(ok, P, U), true, 'own');
  eq(ownsPath(ok.toUpperCase().replace('JPG', 'jpg'), P, U), true, 'case-insensitive');
  eq(ownsPath(ok.replace(U, 'fea44ac5-61b0-41a6-8616-d7823e99151b'), P, U), false, 'other user');
  eq(ownsPath(ok.replace(P, '00000000-0000-0000-0000-000000000000'), P, U), false, 'other property');
  eq(ownsPath(`${P}/${U}/../x/${sub}-a.jpg`, P, U), false, 'traversal');
  for (const dots of ['%2e%2e', '.%2e', '%2E.', '%2F']) eq(ownsPath(`${P}/${U}/${dots}/${sub}-a.jpg`, P, U), false, dots);
  eq(ownsPath(`${P}/${U}/${sub}/x.jpg`, P, U), false, 'file not <uuid>-name');
  eq(ownsPath(`${P}/${U}/${sub}/${sub}-a.gif`, P, U), false, 'extension');
  eq(ownsPath(`${P}/${U}/${sub}/${sub}-a.jpg/extra`, P, U), false, 'extra segment');
  eq(ownsPath(`${P}/${U}/x.jpg`, P, U), false, 'too short');
  eq(ownsPath(`/${ok}`, P, U), false, 'leading slash');
  eq(ownsPath(undefined, P, U), false, 'not a string');
});
Deno.test('retake carries a reason; garbled model reply is unavailable', () => {
  eq(precheckOutcome(read({ is_meter: false }), 'electric', null).reason, 'not_a_meter', 'not a meter');
  eq(precheckOutcome(read({ reading: null }), 'electric', null).reason, 'unreadable', 'unreadable');
  eq(precheckOutcome(read({ is_meter: false, garbled: true }), 'electric', null).status, 'unavailable', 'garbled');
});
Deno.test('placeholder and malformed rows are cache misses', () => {
  eq(asVisionResult({ pending: true }), null, 'pending');
  eq(asVisionResult({ ...read(), garbled: true }), null, 'garbled');
  eq(asVisionResult({ ...read(), reading: '5' }), null, 'reading type');
  eq(asVisionResult({ ...read(), confidence: undefined }), null, 'confidence type');
});
Deno.test('auth branch: only mode precheck leaves the cron gate', () => {
  eq(isPrecheckBody({ mode: 'precheck' }), true, 'precheck');
  eq(isPrecheckBody({}), false, 'empty'); eq(isPrecheckBody({ mode: 'sweep' }), false, 'other'); eq(isPrecheckBody(null), false, 'null');
});
Deno.test('asVisionResult rejects malformed cache rows', () => {
  eq(asVisionResult(null), null, 'null'); eq(asVisionResult({ reading: 1 }), null, 'no is_meter');
  eq(asVisionResult(read())?.reading, 12345, 'good');
});

import { agreesAllowingForDecimalPoint, alignedIfAgrees, alignToTyped, readText, storedVision } from './logic.ts';
Deno.test('alignToTyped picks the power of ten closest to the typed number', () => {
  eq(alignToTyped(431.2, 4292), 4312, '431.2 vs 4292');
  eq(alignToTyped(806, 81.852, 'water'), 80.6, '806 vs 81.852');
  eq(alignToTyped(4326, 4326), 4326, 'same');
  eq(alignToTyped(82, 82.743, 'water'), 82, '82 vs 82.743');
  eq(alignToTyped(431.2, null), 431.2, 'no typed');
  eq(alignToTyped(431.2, undefined), 431.2, 'undefined typed');
});
Deno.test('stored value is aligned; raw text only when it differs', () => {
  eq(storedVision(read({ reading: 431.2 }), 4313, 'electric'), 4312, 'stored');
  eq(storedVision(read({ reading: 5 }), 4292, 'electric'), 5, 'disagreeing read stays raw');
  eq(storedVision(null, 4292, 'electric'), null, 'no result');
  eq(storedVision(read({ reading: null }), 4292, 'electric'), null, 'null reading');
  eq(readText(4312, 431.2), '4312 (reader saw 431.2)', 'differs');
  eq(readText(4326, 4326), '4326', 'same');
});
Deno.test('precheck reports the aligned read', () => {
  const ok = precheckOutcome(read({ reading: 431.2 }), 'electric', 4313);
  eq(ok.reading, 4312, 'reading'); eq(ok.status, 'pass', 'status');
  eq(ok.message, 'Photo looks clear - reading 4,312 (reader saw 431.2).', 'message');
  const r = precheckOutcome(read({ reading: 5 }), 'electric', 4292);
  eq(r.reading, 5, 'raw kept'); eq(r.status, 'check_number', 'status');
  eq(r.message, 'The photo reads 5 but you typed 4,292. Please check the number.', 'message');
  eq(alignedIfAgrees(431.2, 4292, 'electric'), 431.2, 'aligned 4312 is 20 off 4292: raw');
  eq(alignedIfAgrees(806, 82.9, 'water'), 806, 'aligned 80.6 is 2.3 off: raw');
  eq(alignedIfAgrees(806, 81.852, 'water'), 806, 'whole part applies only to a whole-number read: 80.6 is 1.25 off');
  eq(agreesAllowingForDecimalPoint(806, 81.852, 0.5), false, 'now a mismatch');
  eq(agreesAllowingForDecimalPoint(82, 82.743, 0.5), true, 'whole read still agrees');
  eq(alignedIfAgrees(4.312, 4312, 'electric'), 4312, 'same shift set in both');
  eq(agreesAllowingForDecimalPoint(4.312, 4312, 2), true, 'x1000 shift agrees');
  eq(alignedIfAgrees(806, 80.6, 'water'), 80.6, 'agrees');
  eq(alignedIfAgrees(68, 68.827, 'water'), 68, 'whole part');
});
