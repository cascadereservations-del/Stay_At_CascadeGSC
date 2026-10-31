// s103 W2: a meter photo should be from the checkout day (+-1). Judged against the STAY, never the day the report was sent.
// taken_at is written into cleaning_sessions.drive_files by submit-cleaning (drive-archive.ts tagTakenAt). Unknown = no line.

const MANILA = { timeZone: 'Asia/Manila' } as const;
const fmt = (key: string) => new Date(`${key}T00:00:00+08:00`).toLocaleDateString('en-PH', { ...MANILA, month: 'short', day: 'numeric' });

/** One line per meter photo whose Manila date is more than a day from `checkoutDate` (YYYY-MM-DD). Meter files in order:
 *  first = electric, second = water (the order Code.gs files them). Never changes a verdict; the caller decides about noise. */
export function photoDateLines(driveFiles: unknown, checkoutDate: unknown): string[] {
  if (!Array.isArray(driveFiles) || typeof checkoutDate !== 'string' || !/^\d{4}-\d{2}-\d{2}/.test(checkoutDate)) return [];
  const co = checkoutDate.slice(0, 10);
  const meter = driveFiles.filter((f) => typeof f?.section === 'string' && /meter/i.test(f.section));
  const out: string[] = [];
  meter.slice(0, 2).forEach((f, k) => {
    const t = typeof f.taken_at === 'string' ? Date.parse(f.taken_at) : NaN;
    if (!Number.isFinite(t)) return;
    const day = new Date(t).toLocaleDateString('en-CA', MANILA);
    const gap = Math.abs(Date.parse(`${day}T00:00:00Z`) - Date.parse(`${co}T00:00:00Z`)) / 86_400_000;
    if (gap > 1) out.push(`${k === 0 ? 'Electric' : 'Water'} photo taken ${fmt(day)}, checkout ${fmt(co)}`);
  });
  return out;
}
