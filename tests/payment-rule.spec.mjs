import { test, expect } from '@playwright/test';

/* s138 payment rule (D-428/D-429/D-430) on the live booking sheet. Every Supabase endpoint is mocked; nothing reaches a real function.
   The mock rate-card answers like the server deployed before this change (deposit = half, last_minute false): the page must still show
   and send the full stay amount. 1 night = 1,691; 5 nights = 8,455 (hand computed). */
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const plus = (n) => { const d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() + n); return iso(d); };
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');

/* opts.hold: 'granted' (default: hold true + 24 h expiry), 'refused' (hold false, no expiry: the server's real answer for a check-in under 5 days, or an older server), 'noExpiry' (hold true but no expiry).
   opts.rate: extra top-level fields on the rate-card answer (security_deposit, long_stay). */
async function mock(page, opts = {}) {
  const posts = [], uploads = [];
  await page.route('**/*.supabase.co/**', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
  await page.route('**/functions/v1/availability**', (route) => route.fulfill({ contentType: 'application/json', body: '[]' }));
  await page.route('**/functions/v1/rate-card**', (route) => {
    const u = new URL(route.request().url()); const n = Math.round((new Date(u.searchParams.get('checkout')) - new Date(u.searchParams.get('checkin'))) / 86400000);
    const total = 1691 * n;
    route.fulfill({ contentType: 'application/json', body: JSON.stringify({ card: { base: 1780, deposit_pct: 50, tiers: [], promotions: [] }, quote: { n, total, deposit: Math.ceil(total / 2), last_minute: false }, ...(opts.rate || {}) }) });
  });
  await page.route('**/functions/v1/submit-booking', (route) => {
    posts.push(route.request().postDataJSON());
    const mode = opts.hold || 'granted';
    const ans = mode === 'granted' ? { hold: true, hold_expires_at: new Date(Date.now() + 86400000).toISOString() } : mode === 'refused' ? { hold: false, hold_expires_at: null } : { hold: true };
    route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, ref: 'CH-RULE' + posts.length, ...ans, receipt_upload_token: 'tok' + posts.length }) });
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

/* ---- fix round 1: the FLOW split (hold-first from 5 days out, pay-first under 5) is independent of the amount ---- */
const HELD_WORDS = /\bheld\b|holding|hold my|24 hours/i;
async function toContact(page, ci, co) {
  await toStep1(page, ci, co);
  await expect(page.locator('#bsTotal')).toContainText('₱');
  await expect(page.locator('#bsNext1')).toBeEnabled();
  await page.locator('#bsNext1').click();
  await expect(page.locator('#bsH2')).toBeVisible();
  await page.locator('#bsName').fill('Demo Guest'); await page.locator('#bsPhone').fill('917 123 4567');
}

test('2 days out is pay-first: no request is posted before the guest pays, nothing says the dates are held, the amount is still the full stay + the same P800 line', async ({ page }) => {
  const { posts, uploads } = await mock(page);
  await toContact(page, plus(2), plus(4));
  await expect(page.locator('#bsNext2')).toHaveText('Continue to payment');
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toHaveText('Pay and confirm');
  await expect(page.locator('#bsFee')).toHaveText('₱3,382');
  await expect(page.locator('#bsPayTotal')).toHaveText('Security deposit ₱800');
  await expect(page.locator('#bsHeld')).toBeHidden();
  expect(await page.locator('#bookSheet').innerText()).not.toMatch(HELD_WORDS);
  expect(posts.length).toBe(0);                                              /* no hold POST before payment */
  /* a bare tap asks for a reference or a screenshot, and the reference path is open (no mandatory screenshot) */
  await page.locator('#bsNext3').click();
  await expect(page.locator('#bsErr3')).toContainText('reference number');
  expect(posts.length).toBe(0);
  await page.locator('#bsRef').fill('1234567890');
  await page.locator('#bsNext3').click();
  await expect(page.locator('#bsH4')).toBeVisible();
  expect(posts.length).toBe(1);
  expect(posts[0].hold).toBeUndefined();                                     /* the POST carries no hold */
  expect(posts[0].total_amount).toBe(3382); expect(posts[0].deposit_amount).toBe(3382); expect(posts[0].pay_full).toBe(true);
  expect(uploads.length).toBe(0);
});

test('2 days out with a screenshot: the request is posted after payment, with no hold, and the receipt uploads', async ({ page }) => {
  const { posts, uploads } = await mock(page);
  await toContact(page, plus(2), plus(3));
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toHaveText('Pay and confirm');
  expect(posts.length).toBe(0);
  await page.locator('#bsFile').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: PNG });
  await page.locator('#bsNext3').click();
  await expect(page.locator('#bsH4')).toBeVisible();
  expect(posts.length).toBe(1); expect(posts[0].hold).toBeUndefined();
  expect(uploads.length).toBe(1); expect(uploads[0]['x-pay-full']).toBe('true');
});

test('10 days out is hold-first: the request is posted with hold:true at Continue, the dates are shown as held with the timer, then the receipt reuses that hold (one POST)', async ({ page }) => {
  const { posts, uploads } = await mock(page);
  await toContact(page, plus(10), plus(12));
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toHaveText('Your dates are held');
  expect(posts.length).toBe(1); expect(posts[0].hold).toBe(true);
  expect(posts[0].deposit_amount).toBe(3382);
  await expect(page.locator('#bsHeld')).toBeVisible();
  await expect(page.locator('#bsFee')).toHaveText('₱3,382');
  await expect(page.locator('#bsHoldLine')).toContainText('24 hours');
  await page.locator('#bsFile').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: PNG });
  await page.locator('#bsNext3').click();
  await expect(page.locator('#bsH4')).toBeVisible();
  expect(posts.length).toBe(1); expect(uploads.length).toBe(1);
});

test('the boundary: 4 days out is pay-first (HOLD_MIN_DAYS_OUT = 5)', async ({ page }) => {
  const a = await mock(page);
  await toContact(page, plus(4), plus(5));
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toHaveText('Pay and confirm'); expect(a.posts.length).toBe(0);
});
test('the boundary: 5 days out is hold-first', async ({ page }) => {
  const a = await mock(page);
  await toContact(page, plus(5), plus(6));
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toHaveText('Your dates are held'); expect(a.posts.length).toBe(1); expect(a.posts[0].hold).toBe(true);
});

for (const mode of ['refused', 'noExpiry']) {
  test(`server answer without a hold (${mode}): no "held" wording anywhere and the reference-number fallback works`, async ({ page }) => {
    const { posts, uploads } = await mock(page, { hold: mode });
    await toContact(page, plus(10), plus(11));
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsS3')).toBeVisible();                       /* #bsH3 reads right even while hidden: wait for the step itself */
    await expect(page.locator('#bsH3')).toHaveText('Pay and confirm');
    expect(posts.length).toBe(1);                                            /* the hold-first POST was made once */
    await expect(page.locator('#bsHeld')).toBeHidden();
    /* editing a contact field must not produce "Your dates are held under ..." */
    await page.locator('#bsBack').click(); await page.locator('#bsName').fill('Another Guest'); await page.locator('#bsNext2').click();
    await expect(page.locator('#bsS3')).toBeVisible();                       /* the second hold request has answered and the sheet has moved on */
    await expect(page.locator('#bsH3')).toHaveText('Pay and confirm');
    await expect(page.locator('#bsHeldNote')).toBeHidden();
    expect(await page.locator('#bookSheet').innerText()).not.toMatch(/\bheld\b|holding|hold my/i);
    /* reference fallback: no screenshot is demanded */
    await page.locator('#bsRef').fill('9876543210');
    await page.locator('#bsNext3').click();
    await expect(page.locator('#bsH4')).toBeVisible();
    expect(posts[posts.length - 1].hold).toBeUndefined();
    expect(uploads.length).toBe(0);
  });
  test(`server answer without a hold (${mode}): the screenshot upload uses the fresh request's token, never the earlier short-lived one`, async ({ page }) => {
    const { posts, uploads } = await mock(page, { hold: mode });
    await toContact(page, plus(10), plus(11));
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsH3')).toHaveText('Pay and confirm');
    await page.locator('#bsFile').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: PNG });
    await page.locator('#bsNext3').click();
    await expect(page.locator('#bsH4')).toBeVisible();
    expect(posts.length).toBe(2); expect(posts[1].hold).toBeUndefined();
    expect(uploads.length).toBe(1);
    expect(uploads[0].authorization).toBe('Bearer tok2');                    /* the second request's token (the mock numbers them), not tok1 */
  });
}

test('rate-card carrying security_deposit: the page uses the server figure', async ({ page }) => {
  await mock(page, { rate: { security_deposit: 900 } });
  await toPayment(page, plus(30), plus(32));
  await expect(page.locator('#bsPayTotal')).toHaveText('Security deposit ₱900');
  await expect(page.locator('#bsDepLine')).toContainText('₱900');
  await expect(page.locator('#bsDepLine')).not.toContainText('₱800');
});
test('rate-card long_stay:true on a 10-night stay: Continue stays off and the host note shows', async ({ page }) => {
  await mock(page, { rate: { long_stay: true } });
  await toStep1(page, plus(40), plus(50));
  await expect(page.locator('#bsQuoteNote')).toContainText('arranged with the host');
  await expect(page.locator('#bsNext1')).toBeDisabled();
});
test('rate-card without security_deposit or long_stay: the local P800 constant applies (the 28-night fallback is the existing 28 and 27 night tests)', async ({ page }) => {
  await mock(page);
  await toPayment(page, plus(30), plus(32));
  await expect(page.locator('#bsPayTotal')).toHaveText('Security deposit ₱800');
  await expect(page.locator('#bsDepLine')).toContainText('₱800');
});

test('at 375 px the amount due comes before the deposit text, and the deposit text is short (at most 4 lines)', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await mock(page);
  await toPayment(page, plus(30), plus(32));
  const fee = await page.locator('#bsFee').boundingBox(), dep = await page.locator('#bsDepLine').boundingBox();
  expect(fee.y).toBeLessThan(dep.y);
  const lh = await page.locator('#bsDepLine').evaluate((el) => parseFloat(getComputedStyle(el).lineHeight) || parseFloat(getComputedStyle(el).fontSize) * 1.4);
  expect(Math.round(dep.height / lh)).toBeLessThanOrEqual(4);
  expect(fee.y).toBeLessThan(500);                                           /* the amount is above the fold on a phone */
});

test('the done card promises the door code only on the payment + IDs + P800 condition', async ({ page }) => {
  await mock(page);
  await toPayment(page, plus(30), plus(31));
  await page.locator('#bsFile').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: PNG }); await page.locator('#bsNext3').click();
  await expect(page.locator('#bsH4')).toBeVisible();
  const t = await page.locator('#bsS4').innerText();
  expect(t).toContain('Your door code is sent by the host once your payment, your IDs and the ₱800 deposit are in.');
  expect(t).not.toContain('arrive before check-in');
});

/* Polish N1 N2 */
test('pay-first sheet 2 days out: the line says we confirm once we have checked the payment, and never says dates are reserved on receipt', async ({ page }) => {
  await mock(page);
  await toContact(page, plus(2), plus(4));
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toHaveText('Pay and confirm');
  await expect(page.locator('#bsHoldLine')).toContainText('We confirm your booking once we have checked your payment.');
  expect(await page.locator('#bookSheet').innerText()).not.toContain('reserved when we receive');
});
test('rate-card security_deposit 900: the done card door-code line shows 900, not 800', async ({ page }) => {
  await mock(page, { rate: { security_deposit: 900 } });
  await toContact(page, plus(2), plus(4));
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toHaveText('Pay and confirm');
  await page.locator('#bsRef').fill('1234567890');
  await page.locator('#bsNext3').click();
  await expect(page.locator('#bsH4')).toBeVisible();
  await expect(page.locator('#bsDoneCode')).toContainText('₱900 deposit');
  await expect(page.locator('#bsDoneCode')).not.toContainText('₱800');
  await expect(page.locator('#bsDoneDep')).toContainText('₱900');
});
