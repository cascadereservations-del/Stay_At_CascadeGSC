import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { inflateSync } from 'node:zlib';
import { PDFDocument, StandardFonts } from 'npm:pdf-lib@1.17.1';
import { renderPdf, safeText, wrap } from './pdf.ts';
import { buildReport, type Item } from './report.ts';
import { ITEMS, NOW, SHOP } from './fixtures.ts';

// Byte-exact (TextDecoder('latin1') is windows-1252 and would corrupt 0x80-0x9F).
const latin1 = (b: Uint8Array) => Array.from(b, (c) => String.fromCharCode(c)).join('');
const bin = (s: string) => Uint8Array.from(s, (c) => c.charCodeAt(0));

/** Every drawn string in the PDF: inflate each content stream and decode its hex/literal Tj operands. */
function drawnText(bytes: Uint8Array): string {
  const raw = latin1(bytes);
  let out = '';
  for (const m of raw.matchAll(/stream\r?\n([\s\S]*?)\r?\nendstream/g)) {
    let s: string;
    try { s = latin1(inflateSync(bin(m[1]))); } catch { continue; }
    for (const t of s.matchAll(/<([0-9A-Fa-f]+)>\s*Tj|\(((?:\\.|[^\\)])*)\)\s*Tj/g)) {
      out += (t[1] ? String.fromCharCode(...(t[1].match(/../g) ?? []).map((h) => parseInt(h, 16))) : t[2]) + '\n';
    }
  }
  return out;
}

Deno.test('safeText never throws and always yields something Helvetica can encode (every BMP code point)', async () => {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  for (let cp = 0; cp <= 0xFFFF; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    font.encodeText(safeText(String.fromCodePoint(cp))); // throws if not encodable
  }
  for (const s of ['Hand soap ₱95 × 2', 'Ω ≈ ∞', '🧴 soap', 'Café "quotes" – dash', '\u0000\u0007 control', null, undefined]) font.encodeText(safeText(s));
  assertEquals(safeText('₱95'), 'PHP 95');
  assertEquals(safeText('2 × 3'), '2 x 3');
  assertEquals(safeText('🧴'), '?');
  assertEquals(safeText('Café'), 'Café');
});

Deno.test('wrap: two lines at most, the last cut with "..."', async () => {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  assertEquals(wrap('Hand soap', font, 10, 200), ['Hand soap']);
  const long = wrap('Extra long pillow case set with embroidered border and tassels in cream colour', font, 10, 120);
  assertEquals(long.length, 2);
  assert(long[1].endsWith('...'));
  for (const l of long) assert(font.widthOfTextAtSize(l, 10) <= 120, l);
  const word = wrap('Supercalifragilisticexpialidocious'.repeat(3), font, 10, 90);
  assert(word.length <= 2 && word.every((l) => font.widthOfTextAtSize(l, 10) <= 90));
});

Deno.test('pdf: valid file, right page count, Finance and OPS headers drawn', async () => {
  const ops = await renderPdf(buildReport('low', 'ops', ITEMS.map(({ cost: _c, ...r }) => r), [], NOW, 'Honey'), NOW);
  assertEquals(latin1(ops.bytes.slice(0, 5)), '%PDF-');
  assertEquals(ops.pages, 1);
  const loaded = await PDFDocument.load(ops.bytes);
  assertEquals(loaded.getPageCount(), 1);
  assertEquals(loaded.getTitle(), 'Cascade Hideaway - Low stock');
  const t = drawnText(ops.bytes);
  assertStringIncludes(t, 'Cascade Hideaway - Low stock');
  assertStringIncludes(t, 'Made 15 Oct 2026, 12:30 pm Manila time by Honey');
  assertStringIncludes(t, 'Page 1 of 1');
  assertStringIncludes(t, 'Toilet paper');
  assertFalse(/PHP|Finance copy|cost/i.test(t), 'no money and no finance line in the OPS PDF');

  const fin = await renderPdf(buildReport('order', 'finance', ITEMS, SHOP, NOW, 'Lloyd'), NOW);
  const f = drawnText(fin.bytes);
  assertStringIncludes(f, 'Finance copy - prices included');
  assertStringIncludes(f, 'PHP 1,140.00');
  assertStringIncludes(f, 'Estimated total PHP 1,430.00');
});

Deno.test('pdf: 120 rows run to a second page with "(continued)" and Page n of m', async () => {
  const many: Item[] = Array.from({ length: 120 }, (_, k) => ({
    id: `i${k}`, name: `Item ${String(k).padStart(3, '0')}`, category: 'Kitchen & Dining', unit: 'pc', qty: k, reorder: null, par: null,
    consumable: false, purchaseUnit: null, unitsPer: null,
  }));
  const r = buildReport('all', 'ops', many, [], NOW, 'Honey');
  const { bytes, pages } = await renderPdf(r, NOW);
  // 842 pt page, 40 pt margins, 16 pt rows: about 45 rows on page 1 and 48 later -> 3 pages for 120 rows.
  assertEquals(pages, 3);
  assertEquals((await PDFDocument.load(bytes)).getPageCount(), 3);
  const t = drawnText(bytes);
  assertStringIncludes(t, 'Kitchen & Dining (continued)');
  assertStringIncludes(t, 'Page 3 of 3');
  assertStringIncludes(t, 'Item 119');
});

Deno.test('pdf: an empty report is one page that says so; hostile names do not throw', async () => {
  const e = await renderPdf(buildReport('low', 'ops', [], [], NOW, 'Honey'), NOW);
  assertEquals(e.pages, 1);
  assertStringIncludes(drawnText(e.bytes), 'Nothing to list today');
  const odd: Item[] = [{ id: 'x', name: '🧴 Ω ₱ Soap × 12 ' + 'w'.repeat(200), category: 'Ünïcode ✓', unit: 'pc', qty: 1.239, reorder: 2, par: null, consumable: true, purchaseUnit: null, unitsPer: null }];
  const o = await renderPdf(buildReport('low', 'ops', odd, [], NOW, 'Honey'), NOW);
  assertEquals(latin1(o.bytes.slice(0, 5)), '%PDF-');
});
