// inventory-report / pdf.ts (s84 lane I-fn): Report -> PDF bytes with pdf-lib. Standard Helvetica only (WinAnsi), so every cell goes
// through safeText(); no font file, no fontkit, no file system.
import { PDFDocument, type PDFFont, type PDFPage, rgb, StandardFonts } from 'npm:pdf-lib@1.17.1';
import type { Report } from './report.ts';

const W = 595, H = 842, M = 40, BODY = 10, LINE = 13, PAD = 4;

// The characters WinAnsi (and so Helvetica in pdf-lib) can encode, besides ASCII 0x20-0x7E and Latin-1 0xA0-0xFF.
const WIN_EXTRA = new Set([0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x017D, 0x2018, 0x2019, 0x201C, 0x201D,
  0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x017E, 0x0178]);
const encodable = (cp: number) => (cp >= 0x20 && cp <= 0x7E) || (cp >= 0xA1 && cp <= 0xFF && cp !== 0xAD) || WIN_EXTRA.has(cp);

/** Text Helvetica can draw. The peso sign becomes "PHP ", the multiplication sign "x", anything else it cannot encode "?". Never throws. */
export function safeText(input: unknown): string {
  let out = '';
  for (const ch of String(input ?? '')) {
    const cp = ch.codePointAt(0)!;
    if (cp === 0x20B1) out += 'PHP ';
    else if (cp === 0xD7) out += 'x';
    else if (cp === 0xA0 || cp === 0x09 || cp === 0x0A || cp === 0x0D) out += ' ';
    else out += encodable(cp) ? ch : cp < 0x20 ? ' ' : '?';
  }
  return out;
}

/** Wrap to at most `maxLines` lines of width `w`; the last line is cut with "..." when text remains. */
export function wrap(text: string, font: PDFFont, size: number, w: number, maxLines = 2): string[] {
  const fits = (s: string) => font.widthOfTextAtSize(s, size) <= w;
  const words = text.split(' ').filter(Boolean);
  const lines: string[] = [];
  let cur = '';
  let i = 0;
  for (; i < words.length; i++) {
    let word = words[i];
    const tryLine = cur ? `${cur} ${word}` : word;
    if (fits(tryLine)) { cur = tryLine; continue; }
    if (cur) {
      if (lines.length === maxLines - 1) break;
      lines.push(cur); cur = '';
    }
    while (!fits(word) && word.length > 1) { // a single word wider than the cell
      let n = word.length;
      while (n > 1 && !fits(word.slice(0, n))) n--;
      if (lines.length === maxLines - 1) { word = word.slice(0, n); break; }
      lines.push(word.slice(0, n)); word = word.slice(n);
    }
    cur = word;
  }
  const truncated = i < words.length || (cur !== '' && lines.length >= maxLines);
  if (cur) lines.push(cur);
  const out = lines.slice(0, maxLines);
  if (truncated || lines.length > maxLines) {
    let last = out[out.length - 1] ?? '';
    while (last.length > 0 && !fits(last + '...')) last = last.slice(0, -1);
    out[out.length - 1] = last.trimEnd() + '...';
  }
  return out.length ? out : [''];
}

export async function renderPdf(r: Report, now: Date): Promise<{ bytes: Uint8Array; pages: number }> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  doc.setTitle(safeText(r.title)); doc.setCreationDate(now); doc.setModificationDate(now);
  doc.setAuthor('Cascade Hideaway'); doc.setProducer('Cascade Hideaway'); doc.setCreator('Cascade Hideaway');
  const ink = rgb(0.12, 0.12, 0.12), soft = rgb(0.4, 0.4, 0.4), rule = rgb(0.82, 0.82, 0.82);
  const pages: PDFPage[] = [];
  let page!: PDFPage, y = 0;
  const colW = r.widths.map((f) => f * (W - 2 * M));
  const colX = colW.map((_, k) => M + colW.slice(0, k).reduce((a, b) => a + b, 0));

  const newPage = () => { page = doc.addPage([W, H]); pages.push(page); y = H - M; };
  const text = (s: string, x: number, yy: number, f: PDFFont, size: number, color = ink) => page.drawText(safeText(s), { x, y: yy, size, font: f, color });
  const heading = (name: string, cont: boolean) => {
    text(cont ? `${name} (continued)` : name, M, y - 12, bold, 12);
    y -= 17;
    page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.6, color: rule });
    y -= 4;
    r.columns.forEach((c, k) => text(c, colX[k] + PAD, y - 10, bold, 9, soft));
    y -= 15;
  };

  newPage();
  text(r.title, M, y - 16, bold, 16); y -= 24;
  text(r.subtitle, M, y - 9, font, 9, soft); y -= 13;
  if (r.financeLine) { text(r.financeLine, M, y - 9, bold, 9, soft); y -= 13; }
  y -= 8;

  if (r.empty) text(r.empty, M, y - BODY, font, 11);
  for (const g of r.groups) {
    const wrapped = (row: string[]) => row.map((c, k) => wrap(safeText(c), font, BODY, colW[k] - 2 * PAD));
    const need = (row: string[]) => Math.max(...wrapped(row).map((l) => l.length)) * LINE + 3;
    if (y - 36 - need(g.rows[0]) < M + 20) newPage();
    heading(g.heading, false);
    for (const row of g.rows) {
      const cellLines = wrapped(row);
      const h = Math.max(...cellLines.map((l) => l.length)) * LINE + 3;
      if (y - h < M + 20) { newPage(); heading(g.heading, true); }
      cellLines.forEach((ls, k) => ls.forEach((l, n) => text(l, colX[k] + PAD, y - 10 - n * LINE, font, BODY)));
      y -= h;
      page.drawLine({ start: { x: M, y: y + 1 }, end: { x: W - M, y: y + 1 }, thickness: 0.3, color: rgb(0.92, 0.92, 0.92) });
    }
    y -= 8;
  }
  if (r.totals.length) {
    if (y - r.totals.length * 15 < M + 20) newPage();
    y -= 4;
    for (const t of r.totals) { text(t, M, y - 11, bold, 11); y -= 15; }
  }
  pages.forEach((p, n) => p.drawText(`Page ${n + 1} of ${pages.length}`, { x: W - M - 60, y: M - 14, size: 8, font, color: soft }));
  return { bytes: await doc.save(), pages: pages.length };
}
