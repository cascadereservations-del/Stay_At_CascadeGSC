// Pure helpers for verify-meter-photo (s94): shared by the sweep and by mode:'precheck'. No I/O, no Deno APIs.

export type Which = 'electric' | 'water';

export type VisionResult = {
  is_meter: boolean;
  meter_type: string;
  reading: number | null;
  confidence: number;
  note: string;
  via?: 'gemini' | 'openrouter';  // which provider actually read it (session 46 fallback)
};

// How far a read may sit from the typed number before it counts as a mismatch.
// The failure worth catching is a wrong digit in a five-digit index, not a
// rounding difference, and a tolerance that is too tight would accuse an
// honest cleaner every week.
export const ELECTRIC_TOLERANCE = 2;    // kWh
export const WATER_TOLERANCE    = 0.5;  // m3
// Below this the model is guessing, and a guess must never accuse anyone.
export const MIN_CONFIDENCE     = 0.55;

/* A water meter face is number wheels plus fraction dials, and a reader can
   easily return the digits without the decimal point: the 2026-09-03 report
   recorded 70.873 m3 and the first sweep read the same face as "708", which
   was recorded as a mismatch. The digits agree; only the decimal placement
   differs, and that is a reading convention rather than a discrepancy.

   So before calling a mismatch, try shifting the read by powers of ten. This
   forgives 708 against 70.873 and still catches 3814 against 3832, because
   no power of ten makes different digits agree. Loosening the tolerance
   instead would have hidden real differences. */
export function agreesAllowingForDecimalPoint(read: number, typed: number, tol: number): boolean {
  // The prompt asks for the WHOLE cubic metres and to ignore the fraction
  // dials, so a correct read of a 68.827 face is "68" and comparing that to
  // the typed 68.827 flagged a mismatch on the first full sweep. The
  // whole-number part of the typed reading is therefore an accepted answer.
  const targets = [typed, Math.floor(typed)];
  for (let k = -2; k <= 3; k++) {
    const scaled = read / Math.pow(10, k);
    for (const t of targets) {
      if (Math.abs(scaled - t) <= tol) return true;
    }
  }
  return false;
}

/** The caller may check only a photo it uploaded: upload-photo writes <property>/<user id>/<submission>/<file>. */
export function ownsPath(path: unknown, propertyId: string, userId: string): path is string {
  if (typeof path !== 'string' || path.length > 400 || path.includes('..') || path.includes(String.fromCharCode(92))) return false;
  const parts = path.split('/');
  return parts.length >= 4 && parts.every((p) => p !== '') &&
    parts[0].toLowerCase() === propertyId.toLowerCase() && parts[1].toLowerCase() === userId.toLowerCase();
}

export type PrecheckStatus = 'pass' | 'retake' | 'check_number' | 'unavailable';
export type PrecheckOutcome = { status: PrecheckStatus; reading: number | null; message: string };

const fmt = (n: number) => n.toLocaleString('en-US', { maximumFractionDigits: 3 });

export const UNAVAILABLE_MESSAGE = 'The photo check is not available just now. You can carry on; the photo will be checked later.';

/** One meter photo -> what the cleaner is told. Never blocks and never accuses (Cassy voice: calm, no exclamation marks). */
export function precheckOutcome(r: VisionResult | null, which: Which, typed: number | null | undefined): PrecheckOutcome {
  if (!r) return { status: 'unavailable', reading: null, message: UNAVAILABLE_MESSAGE };
  if (!r.is_meter) {
    return { status: 'retake', reading: null, message: 'This does not look like the meter. Please take the photo again, close and straight on.' };
  }
  if (r.reading === null || r.confidence < MIN_CONFIDENCE) {
    return { status: 'retake', reading: null, message: 'The numbers are hard to read in this photo. Please take it again, close and straight on, with less glare.' };
  }
  const tol = which === 'electric' ? ELECTRIC_TOLERANCE : WATER_TOLERANCE;
  if (typed !== null && typed !== undefined && Number.isFinite(typed) && !agreesAllowingForDecimalPoint(r.reading, typed, tol)) {
    return { status: 'check_number', reading: r.reading, message: `The photo reads ${fmt(r.reading)} but you typed ${fmt(typed)}. Please check the number.` };
  }
  return { status: 'pass', reading: r.reading, message: `Photo looks clear - reading ${fmt(r.reading)}.` };
}

/** Does a cached jsonb value look like a VisionResult? A malformed row is ignored, not trusted. */
export function asVisionResult(v: unknown): VisionResult | null {
  const o = v as Record<string, unknown> | null;
  if (!o || typeof o !== 'object' || typeof o.is_meter !== 'boolean') return null;
  return o as unknown as VisionResult;
}

/** Auth branch: only this body shape skips the cron secret (and then needs a staff bearer). */
export function isPrecheckBody(body: unknown): boolean {
  return !!body && typeof body === 'object' && (body as Record<string, unknown>).mode === 'precheck';
}
