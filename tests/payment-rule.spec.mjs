import { test, expect } from '@playwright/test';

/* s138 payment rule (D-428/D-429/D-430) on the live booking sheet. Every Supabase endpoint is mocked; nothing reaches a real function.
   The mock rate-card answers like the server deployed before this change (deposit = half, last_minute false): the page must still show
   and send the full stay amount. 1 night = 1,691; 5 nights = 8,455 (hand computed). */
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const plus = (n) => { const d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() + n); return iso(d); };
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');

async function mock(page) {
  const posts = [], uploads = [];
  await page.route('**/*.supabase.co/**', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
  await page.route('**/functions/v1/availability**', (route) => route.fulfill({ contentType: 'application/json', body: '[]' }));
  await page.route('**/functions/v1/rate-card**', (route) => {
    const u = new URL(route.request().url()); const n = Math.round((new Date(u.searchParams.get('checkout')) - new Date(u.searchParams.get('checkin'))) / 86400000);
    const total = 1691 * n;
    route.fulfill({ contentType: 'application/json', body: JSON.stringify({ card: { base: 1780, deposit_pct: 50, tiers: [], promotions: [] }, quote: { n, total, deposit: Math.ceil(total / 2), last_minute: false } }) });
  });
  await page.route('**/functions/v1/submit-booking', (route) => {
    posts.push(route.request().postDataJSON());
    route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, ref: 'CH-RULE1', hold: true, hold_expires_at: new Date(Date.now() + 86400000).toISOString(), receipt_upload_token: 'tok' }) });
  });
  await page.route('**/functions/v1/upload-booking-receipt', (route) => { uploads.push(route.request().headers()); route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' }); });
  return { posts, uploads };
}
async function pickDay(page, ds) {
  await expect(page.locator('#bsAvailNote')).not.toHaveText('Checking availability…');
  const day = page.locator(`#bsGrid [data-d="${ds}"]`);
  for (let i = 0; i < 6 && !(await day.count()); i++) {
    const shown = (await page.locator('#bsGrid [data-d]').first().getAttribute('data-d')).slice(0, 7);
    await page.locator(ds.slice(0, 7) < shown ? '#bsPrev' : '#bsNext').click();
    await day.waitFor({ state: 'attached', timeout: 4000 }).catch(() => {});
  }
  await day.click();
}
async function toStep1(page, ci, co) {
  await page.goto('/index.html'); await page.locator('a.header-cta[data-gs-book]').click();
  await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
  await pickDay(page, ci); await pickDay(page, co);
}
async function toPayment(page, ci, co) {
  await toStep1(page, ci, co);
  await expect(page.locator('#bsTotal')).toContainText('₱');
  await expect(page.locator('#bsNext1')).toBeEnabled();
  await page.locator('#bsNext1').click();
  await expect(page.locator('#bsH2')).toBeVisible();
  await page.locator('#bsName').fill('Demo Guest'); await page.locator('#bsPhone').fill('917 123 4567');
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toBeVisible();
  await expect(page.locator('#bsFee')).not.toHaveText('…');
}

for (const [nights, total] of [[1, '₱1,691'], [5, '₱8,455']]) {
  test(`${nights}-night quote: the payment step shows the stay total due now, a separate P800 deposit line, and none of the old words`, async ({ page }) => {
    await mock(page);
    await toPayment(page, plus(30), plus(30 + nights));
    await expect(page.locator('#bsFee')).toHaveText(total);
    await expect(page.locator('#bsPayLbl')).toHaveText('Your stay, paid in full to confirm');
    await expect(page.locator('#bsPayTotal')).toHaveText('Security deposit ₱800');
    await expect(page.locator('#bsPayLater')).toHaveText('Refundable, paid separately');
    const text = await page.locator('#bsS3').innerText();
    expect(text).not.toMatch(/50% reservation|reservation fee|balance|1,000|pay in full|Pay now \(/i);
    expect(text).toContain('Free cancellation until 5 days before check-in');
    /* the deposit is never added silently into the stay amount: Copy amount carries the stay total only */
    await page.evaluate(() => { window.__copied = ''; navigator.clipboard.writeText = (s) => { window.__copied = s; return Promise.resolve(); }; });
    await page.locator('#bsCopyAmt').click();
    expect(await page.evaluate(() => window.__copied)).toBe(String(1691 * nights));
  });
}

test('the client POST carries deposit_amount = the stay total with pay_full, and the receipt carries X-Pay-Full (correct against the old and the new server)', async ({ page }) => {
  const { posts, uploads } = await mock(page);
  await toPayment(page, plus(30), plus(32));
  expect(posts.length).toBe(1);
  expect(posts[0].total_amount).toBe(3382);
  expect(posts[0].deposit_amount).toBe(3382);
  expect(posts[0].pay_full).toBe(true);
  expect(posts[0].hold).toBe(true);
  await page.locator('#bsFile').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: PNG });
  await page.locator('#bsNext3').click();
  await expect(page.locator('#bsH4')).toBeVisible();
  expect(uploads.length).toBe(1);
  expect(uploads[0]['x-pay-full']).toBe('true');
  expect(posts.length).toBe(1);
});

test('28 nights or more is never auto-quoted: Continue stays off, the guest is pointed to the host, 27 nights still quotes', async ({ page }) => {
  await mock(page);
  await toStep1(page, plus(40), plus(68));                                  /* 28 nights */
  await expect(page.locator('#bsRange')).toContainText('28 nights');
  await expect(page.locator('#bsTotal')).toHaveText('');
  await expect(page.locator('#bsNext1')).toBeDisabled();
  await expect(page.locator('#bsQuoteNote')).toContainText('arranged with the host');
  await expect(page.locator('#bsQuoteNote')).toContainText('cascadereservations@gmail.com');
  await expect(page.locator('#bsQuoteMsgr')).toBeVisible();
  await expect(page.locator('#bsQuoteMsgr')).toHaveAttribute('href', /messenger\.com\/t\/699640026568720/);
});

test('27 nights is still quoted on the sheet (control for the 28-night rule)', async ({ page }) => {
  await mock(page);
  await toStep1(page, plus(40), plus(67));
  await expect(page.locator('#bsRange')).toContainText('27 nights');
  await expect(page.locator('#bsTotal')).toHaveText('₱45,657');             /* 27 x 1,691 */
  await expect(page.locator('#bsNext1')).toBeEnabled();
});
