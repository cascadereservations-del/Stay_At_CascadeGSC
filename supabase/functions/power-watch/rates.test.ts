import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { ratesFromTable } from './rates.ts';

const VALUES: Array<[string, string]> = [['January', '10.7775'], ['February', '9.5339'], ['March', '10.0517'], ['April', '9.6999'], ['May', '9.7504'], ['June', '9.9983'],
  ['July', '11.1634'], ['August', '9.5944'], ['September', '12.4968'], ['October', '12.6406'], ['November', '12.0508'], ['December', '']];
const row = (m: string, v: string, o = '/kwh') => `<tr><td data-title="Month">${m} 2026</td><td data-title="Residential">${v ? v + o : ''}</td><td data-title="Low Voltage">${v ? '9.1' + o : ''}</td><td data-title="High Voltage"></td></tr>`;
const page = (rows: string) => `<div class="rate-table"><table class="table"><tr><th>Month</th><th>Residential</th></tr>${rows}</table></div>`;

Deno.test('the 2026 table gives 11 rows with exact values and first-of-month dates; empty December is skipped', () => {
  const { rows: got, seen } = ratesFromTable(page(VALUES.map(([m, v]) => row(m, v)).join('\n')));
  assertEquals(got.length, 11);
  assertEquals(seen, 11);
  assertEquals(got[0], { php_per_kwh: 10.7775, effective_from: '2026-01-01' });
  assertEquals(got[10], { php_per_kwh: 12.0508, effective_from: '2026-11-01' });
  assertEquals(got.map((r) => r.php_per_kwh), VALUES.slice(0, 11).map(([, v]) => Number(v)));
  assertEquals(got.map((r) => r.effective_from.slice(5)), ['01-01', '02-01', '03-01', '04-01', '05-01', '06-01', '07-01', '08-01', '09-01', '10-01', '11-01']);
});

Deno.test('attribute order, whitespace, case and a /kWh suffix in any case are tolerated', () => {
  const html = `<table><TR>\n <td class="x" DATA-TITLE='Month' >  november  2026 </td>\n<TD data-title = "Residential" class="y"> <b>12.0508</b> / kWh </TD></TR></table>`;
  assertEquals(ratesFromTable(html).rows, [{ php_per_kwh: 12.0508, effective_from: '2026-11-01' }]);
});

Deno.test('an out-of-range, unparsable or month-less row is skipped', () => {
  assertEquals(ratesFromTable(page(row('March', '120.5') + row('April', '2.1') + row('May', 'n/a', '') + row('June', '9.9983'))).rows, [{ php_per_kwh: 9.9983, effective_from: '2026-06-01' }]);
  assertEquals(ratesFromTable('<table><tr><td data-title="Month">Total</td><td data-title="Residential">12.0/kwh</td></tr></table>').rows, []);
});

Deno.test('HTML with no table gives []', () => {
  const none = { rows: [], seen: 0 };
  assertEquals(ratesFromTable('<html><body><p>Effective rates coming soon</p></body></html>'), none);
  assertEquals(ratesFromTable(''), none);
  assertEquals(ratesFromTable('<tr><td data-title="Month">May 2026</td><td data-title="Residential">9.7504/kwh</td></tr>'), none);
});

Deno.test('&nbsp; and &#160; in cells are read as spaces', () => {
  const html = '<table><tr><td data-title="Month">November&nbsp;2026</td><td data-title="Residential">12.0508&nbsp;/kwh</td></tr><tr><td data-title="Month">October&#160;2026</td><td data-title="Residential">12.6406&#160;/&nbsp;kwh</td></tr></table>';
  assertEquals(ratesFromTable(html).rows.map((r) => r.effective_from), ['2026-11-01', '2026-10-01']);
});

Deno.test('a malformed non-empty cell is counted as seen but not parsed; empty December is not seen', () => {
  const got = ratesFromTable(page(row('January', '10.7775') + row('February', '9.5339') + row('March', '12.0508', ' per kWh') + row('December', '')));
  assertEquals(got.rows.length, 2);
  assertEquals(got.seen, 3);
});
