import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { PDFDocument } from 'npm:pdf-lib@1.17.1';
import jsQRmod from 'npm:jsqr@1.4.0'; // test-only decoder
const jsQR = jsQRmod as unknown as (d: Uint8ClampedArray, w: number, h: number) => { data: string } | null; // its typings declare a namespace
import { buildLabels, LABELS_PER_PAGE, qrMatrix, renderLabels } from './labels.ts';
import { drawnText, NOW } from './fixtures.ts';

/** Matrix + 4-module quiet zone -> RGBA at 6 px per module -> jsQR. */
function decode(m: boolean[][]): string | null {
  const q = 4, px = 6, size = (m.length + 2 * q) * px, data = new Uint8ClampedArray(size * size * 4).fill(255);
  m.forEach((row, r) => row.forEach((dark, c) => {
    if (!dark) return;
    for (let y = 0; y < px; y++) for (let x = 0; x < px; x++) { const i = (((r + q) * px + y) * size + (c + q) * px + x) * 4; data[i] = data[i + 1] = data[i + 2] = 0; }
  }));
  return jsQR(data, size, size)?.data ?? null;
}

Deno.test('QR round trip: the matrix decodes back to the same CH- code', () => {
  for (const code of ['CH-0123456789', 'CH-ABCDEF1234', 'CH-A1B2C3D4E5']) assertEquals(decode(qrMatrix(code)), code);
});

Deno.test('labels: 21 per page, the 22nd opens page 2; names and codes drawn; no money', async () => {
  const rows = Array.from({ length: 22 }, (_, k) => ({ name: `Item ${String(k).padStart(2, '0')} with a rather long descriptive name that needs two lines`, code: `CH-${String(k).padStart(10, '0')}` }));
  const b = buildLabels(rows, NOW, 'Marifel Santos');
  assertEquals(b.caption, 'Item labels, 22 items. Sent from the staff app by Marifel.');
  assertEquals(b.filename, 'cascade-labels-2026-10-15.pdf');
  const { bytes, pages } = await renderLabels(b.labels, b.title, NOW);
  assertEquals(pages, 2);
  assertEquals(LABELS_PER_PAGE, 21);
  assertEquals((await PDFDocument.load(bytes)).getPageCount(), 2);
  const t = drawnText(bytes);
  assertStringIncludes(t, 'CH-0000000021');
  assertStringIncludes(t, 'Item 00 with a rather');
  assertFalse(/PHP|cost|price/i.test(t));
  assert(b.labels.every((l) => !/PHP/.test(l.name)));
});
