// inventory-report / labels.ts (s86 lane D-report): QR item labels, A4, 3 columns x 7 rows. No money, no I/O.
// QR encoder: qrcode-generator (pure JS) -> module matrix -> one drawRectangle per horizontal run of dark modules.
import qrcode from 'npm:qrcode-generator@1.4.4';
import { PDFDocument, rgb, StandardFonts } from 'npm:pdf-lib@1.17.1';
import { safeText, wrap } from './pdf.ts';
import { contactSafe, manilaDate, manilaStamp } from './report.ts';

export interface Label { name: string; code: string }
export const LABELS_PER_PAGE = 21;
const W = 595, H = 842, MX = 20, MY = 12, COLS = 3, ROWS = 7;
const MM = 72 / 25.4;
const QR_SIZE = 30 * MM, QUIET = 4;

/** Dark-module matrix of `text`, error correction M, WITHOUT the quiet zone (the drawing adds 4 modules of white). */
export function qrMatrix(text: string): boolean[][] {
  const q = qrcode(0, 'M');
  q.addData(text, 'Byte');
  q.make();
  const n = q.getModuleCount();
  return Array.from({ length: n }, (_, r) => Array.from({ length: n }, (_, c) => q.isDark(r, c)));
}

export function buildLabels(rows: Array<{ name: string; code: string }>, now: Date, who: string) {
  const first = who.trim().split(/\s+/)[0] || 'the team';
  const n = rows.length;
  return {
    labels: rows.map((r) => ({ name: contactSafe(r.name), code: r.code })) as Label[],
    title: 'Cascade Hideaway - Item labels',
    subtitle: `Made ${manilaStamp(now)} Manila time by ${first}`,
    caption: `Item labels, ${n} ${n === 1 ? 'item' : 'items'}. Sent from the staff app by ${first}.`.slice(0, 200),
    filename: `cascade-labels-${manilaDate(now)}.pdf`,
    rowCount: n,
  };
}

export async function renderLabels(labels: Label[], title: string, now: Date): Promise<{ bytes: Uint8Array; pages: number }> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  doc.setTitle(safeText(title)); doc.setCreationDate(now); doc.setModificationDate(now);
  doc.setAuthor('Cascade Hideaway'); doc.setProducer('Cascade Hideaway'); doc.setCreator('Cascade Hideaway');
  const cw = (W - 2 * MX) / COLS, ch = (H - 2 * MY) / ROWS;
  const ink = rgb(0, 0, 0), cut = rgb(0.85, 0.85, 0.85), soft = rgb(0.2, 0.2, 0.2);
  const pageCount = Math.max(1, Math.ceil(labels.length / LABELS_PER_PAGE));
  for (let p = 0; p < pageCount; p++) {
    const page = doc.addPage([W, H]);
    for (let c = 0; c <= COLS; c++) page.drawLine({ start: { x: MX + c * cw, y: MY }, end: { x: MX + c * cw, y: H - MY }, thickness: 0.4, color: cut });
    for (let r = 0; r <= ROWS; r++) page.drawLine({ start: { x: MX, y: MY + r * ch }, end: { x: W - MX, y: MY + r * ch }, thickness: 0.4, color: cut });
    labels.slice(p * LABELS_PER_PAGE, (p + 1) * LABELS_PER_PAGE).forEach((l, k) => {
      const col = k % COLS, row = Math.floor(k / COLS);
      const x0 = MX + col * cw, yTop = H - MY - row * ch;
      const m = qrMatrix(l.code), mod = QR_SIZE / (m.length + 2 * QUIET);
      const qx = x0 + (cw - QR_SIZE) / 2, qy = yTop - 1; // top of the 30 mm square, quiet zone inside it
      m.forEach((line, r) => {
        for (let c = 0; c < line.length; c++) {
          if (!line[c]) continue;
          let end = c; while (end + 1 < line.length && line[end + 1]) end++;
          page.drawRectangle({ x: qx + (QUIET + c) * mod, y: qy - (QUIET + r + 1) * mod, width: (end - c + 1) * mod, height: mod, color: ink });
          c = end;
        }
      });
      let ty = qy - QR_SIZE - 8;
      for (const line of wrap(safeText(l.name), font, 8, cw - 10, 2)) {
        page.drawText(line, { x: x0 + (cw - font.widthOfTextAtSize(line, 8)) / 2, y: ty, size: 8, font, color: ink }); ty -= 9;
      }
      const code = safeText(l.code);
      page.drawText(code, { x: x0 + (cw - font.widthOfTextAtSize(code, 8)) / 2, y: ty - 1, size: 8, font, color: soft });
    });
  }
  return { bytes: await doc.save(), pages: pageCount };
}
