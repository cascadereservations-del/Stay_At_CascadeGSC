import { test, expect } from '@playwright/test';

/* T6 booking sheet. Every Supabase endpoint is mocked: the sandbox cannot reach the real host and a test must never write a booking. */
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const plus = (n) => { const d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() + n); return iso(d); };
const CI = plus(30), CO = plus(32), BLOCK_FROM = plus(34), BLOCK_TO = plus(36), CLASH_CI = plus(32), CLASH_CO = plus(37);

async function mock(page, { submit } = {}) {
  const posts = [], uploads = [];
  await page.route('**/*.supabase.co/**', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
  await page.route('**/functions/v1/availability**', (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify([{ checkin_date: BLOCK_FROM, checkout_date: BLOCK_TO }]) }));
  await page.route('**/functions/v1/rate-card**', (route) => {
    const u = new URL(route.request().url()); const a = new Date(u.searchParams.get('checkin')), b = new Date(u.searchParams.get('checkout'));
    const n = Math.round((b - a) / 86400000); const total = 1691 * n;
    route.fulfill({ contentType: 'application/json', body: JSON.stringify({ card: { base: 1780, deposit_pct: 50, tiers: [{ min_nights: 2, pct: 5 }], promotions: [] }, quote: { n, total, deposit: Math.ceil(total / 2), last_minute: false } }) });
  });
  await page.route('**/functions/v1/submit-booking', async (route) => {
    posts.push(route.request().postDataJSON());
    if (submit) return submit(route);
    route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, ref: 'CH-TEST1', hold: true, hold_expires_at: new Date(Date.now() + 86400000).toISOString(), receipt_upload_token: 'hold-token-1' }) });
  });
  await page.route('**/functions/v1/upload-booking-receipt', (route) => { uploads.push({ auth: route.request().headers()['authorization'] }); route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' }); });
  posts.uploads = uploads;
  return posts;
}
async function pickDay(page, ds) {
  for (let i = 0; i < 3 && !(await page.locator(`#bsGrid [data-d="${ds}"]`).count()); i++) await page.locator('#bsNext').click();
  await page.locator(`#bsGrid [data-d="${ds}"]`).click();
}
async function step1(page, ci = CI, co = CO) {
  await pickDay(page, ci); await pickDay(page, co);
  await expect(page.locator('#bsTotal')).toContainText('₱');
  await page.locator('#bsNext1').click();
  await expect(page.locator('#bsH2')).toBeVisible();
}
async function step2(page, name = 'Maria Santos') {
  await page.locator('#bsName').fill(name); await page.locator('#bsPhone').fill('917 123 4567');
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsH3')).toBeVisible();
}
const openHeader = async (page) => { await page.goto('/index.html'); await page.locator('a.header-cta[data-gs-book]').click(); await expect(page.locator('#bookSheet')).toHaveAttribute('open', ''); };

test.describe('booking sheet', () => {
  test('opens from the header link, the Book-direct card and the cover dock; Esc closes and focus returns', async ({ page }) => {
    await mock(page);
    await page.goto('/index.html');
    for (const sel of ['a.header-cta[data-gs-book]', '#book-direct [data-gs-book]']) {
      const opener = page.locator(sel).first();
      await opener.evaluate((el) => el.scrollIntoView({ block: 'center', behavior: 'instant' }));
      await opener.focus(); await opener.click();
      await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
      await expect(page.locator('#bsH1')).toBeFocused();
      await page.keyboard.press('Escape');
      await expect(page.locator('#bookSheet')).not.toHaveAttribute('open', '');
      await expect(opener).toBeFocused();
    }
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.locator('#qbwCiField').click();
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    await expect(page.locator('#qbwPicker')).toBeHidden();
    await expect.poll(() => page.evaluate(() => !!(window._bkState && window._bkState.loaded))).toBe(true);
    await pickDay(page, CI); await pickDay(page, CO);
    await expect(page.locator('#bsRange')).toContainText('2 nights');
    await expect(page.locator('#bsNext1')).toBeEnabled();
  });

  test('a stay that crosses a booked night is blocked with an inline message', async ({ page }) => {
    await mock(page); await openHeader(page);
    await expect.poll(() => page.evaluate(() => !!(window._bkState && window._bkState.loaded))).toBe(true);
    await pickDay(page, CLASH_CI); await pickDay(page, CLASH_CO);
    await expect(page.locator('#bsErr1')).toContainText('crosses a booked night');
    await expect(page.locator('#bsNext1')).toBeDisabled();
  });

  test('reload mid-flow restores the step and the fields; no navigation on a validation error', async ({ page }) => {
    await mock(page); await openHeader(page);
    await step1(page);
    await page.locator('#bsNext2').click();                                   /* empty: inline errors, still step 2 */
    await expect(page.locator('#bsNameE')).toContainText('full name');
    await expect(page.locator('#bsH2')).toBeVisible();
    await page.locator('#bsName').fill('Maria Santos'); await page.locator('#bsPhone').fill('917 123 4567');
    await page.reload();
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    await expect(page.locator('#bsH2')).toBeVisible();
    await expect(page.locator('#bsName')).toHaveValue('Maria Santos');
    await expect(page.locator('#bsPhone')).toHaveValue('917 123 4567');
    await expect(page.locator('#bsCc')).toHaveAttribute('aria-label', 'Country code, Philippines +63');
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsH3')).toBeVisible();
    await page.reload();
    await expect(page.locator('#bsH3')).toBeVisible();
  });

  test('a 20 s timeout shows the submit-error state with nothing lost, then Try again works', async ({ page }) => {
    test.setTimeout(70000);
    let n = 0;
    const posts = await mock(page, { submit: async (route) => { n++; if (n === 1) { await new Promise((r) => setTimeout(r, 24000)); return route.abort(); } route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, ref: 'CH-TEST1', hold: true, hold_expires_at: new Date(Date.now() + 86400000).toISOString() }) }); } });
    await openHeader(page); await step1(page);
    await page.locator('#bsName').fill('Maria Santos'); await page.locator('#bsPhone').fill('917 123 4567');
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsSE')).toBeVisible({ timeout: 30000 });
    await expect(page.locator('#bsHE')).toHaveText('We didn’t hear back in time');
    await expect(page.locator('#bsSE')).toContainText('Nothing was charged, and your dates and details are saved.');
    await expect(page.locator('#bsEWho')).toContainText('Maria Santos');
    await expect(page.locator('#bsEMsgr')).toHaveAttribute('href', /^https:\/\/www\.messenger\.com\/t\/699640026568720/);
    await expect(page.locator('#bsSE')).toContainText('cascadereservations@gmail.com');
    await page.locator('#bsRetry').click();
    await expect(page.locator('#bsH3')).toBeVisible();
    expect(posts.length).toBe(2);
  });

  test('same dates and same contact reuse the hold without a second POST', async ({ page }) => {
    const posts = await mock(page); await openHeader(page);
    await step1(page); await step2(page, 'Maria Santos');
    await page.locator('#bsBack').click();
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsH3')).toBeVisible();
    await expect(page.locator('#bsHeldNote')).toBeHidden();
    expect(posts.length).toBe(1);
    expect(posts[0].hold).toBe(true);
  });

  test('editing the name or phone after a hold makes no second POST and shows the held-under notice', async ({ page }) => {
    const posts = await mock(page); await openHeader(page);
    await step1(page); await step2(page, 'Maria Santos');
    await page.locator('#bsBack').click();
    await page.locator('#bsName').fill('Maria S. Santos');
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsH3')).toBeVisible();
    await expect(page.locator('#bsHeldNote')).toBeVisible();
    await expect(page.locator('#bsHeldNote')).toContainText('Your dates are held under Maria Santos · •••• 4567. To change these details, message us on Messenger.');
    await expect(page.locator('#bsHeldNoteA')).toHaveAttribute('href', /^https:\/\/www\.messenger\.com\/t\/699640026568720/);
    expect(posts.length).toBe(1);
    await page.locator('#bsBack').click();
    await page.locator('#bsName').fill('Maria Santos'); await page.locator('#bsPhone').fill('917 999 0000');
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsHeldNote')).toContainText('held under Maria Santos · •••• 4567');
    expect(posts.length).toBe(1);
    await page.locator('#bsRef').fill('1234567890');
    await page.locator('#bsNext3').click();
    await expect(page.locator('#bsH4')).toBeVisible();
    expect(posts.length).toBe(1);                                              /* payment still rides the existing hold */
  });

  test('changed dates take a new hold', async ({ page }) => {
    const posts = await mock(page); await openHeader(page);
    await step1(page); await step2(page);
    await page.locator('#bsBack').click(); await page.locator('#bsBack').click();
    await expect(page.locator('#bsGrid')).toBeVisible();
    await pickDay(page, plus(40)); await pickDay(page, plus(42));
    await page.locator('#bsNext1').click();
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsH3')).toBeVisible();
    await expect.poll(() => posts.length).toBe(2);
  });

  const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');

  test('payment with a receipt after a name edit uploads once with the hold token and makes no second submit', async ({ page }) => {
    const posts = await mock(page); await openHeader(page);
    await step1(page); await step2(page, 'Maria Santos');
    await page.locator('#bsBack').click();
    await page.locator('#bsName').fill('Maria S. Santos');
    await page.locator('#bsNext2').click();
    await expect(page.locator('#bsHeldNote')).toBeVisible();
    await page.locator('#bsFile').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: PNG });
    await expect(page.locator('#bsFileName')).toContainText('receipt.png');
    await page.locator('#bsNext3').click();
    await expect(page.locator('#bsH4')).toBeVisible();
    expect(posts.uploads).toEqual([{ auth: 'Bearer hold-token-1' }]);
    expect(posts.length).toBe(1);
  });

  test('WMO codes classify to rain, cloudy and clear', async ({ page }) => {
    await mock(page);
    await page.goto('/index.html');
    const got = await page.evaluate(() => [61, 63, 80, 95, 3, 45, 0, 1].map((code) => window.CascadeTheme.classify({ current: { code } })));
    expect(got).toEqual(['rain', 'rain', 'rain', 'rain', 'cloudy', 'cloudy', 'clear', 'clear']);
    expect(await page.evaluate(() => window.CascadeTheme.classify({ current: { description: 'Light rain' } }))).toBe('rain');   /* no code: text rules */
  });

  test('a fresh weather cache (under 15 min) skips the fetch', async ({ page }) => {
    await mock(page);
    let hits = 0;
    await page.route('**/functions/v1/weather-proxy', (route) => { hits++; route.fulfill({ contentType: 'application/json', body: '{"current":{"code":0}}' }); });
    const t = Date.now() - 60000;
    await page.addInitScript((t0) => { try { sessionStorage.setItem('cascade.wx.v1', JSON.stringify({ t: t0, wx: 'rain' })); } catch (e) { /* blocked */ } }, t);
    await page.goto('/index.html');
    await expect(page.locator('html')).toHaveAttribute('data-wx', 'rain');
    expect(hits).toBe(0);
  });

  test('an expired weather cache (16 min old) fetches again', async ({ page }) => {
    await mock(page);
    let hits = 0;
    await page.route('**/functions/v1/weather-proxy', (route) => { hits++; route.fulfill({ contentType: 'application/json', body: '{"current":{"code":0}}' }); });
    const t = Date.now() - 16 * 60 * 1000;
    await page.addInitScript((t0) => { try { sessionStorage.setItem('cascade.wx.v1', JSON.stringify({ t: t0, wx: 'rain' })); } catch (e) { /* blocked */ } }, t);
    await page.goto('/index.html');
    await expect.poll(() => hits).toBe(1);
    await expect(page.locator('html')).toHaveAttribute('data-wx', 'clear');
  });

  test('step 3 requires a reference or a receipt, then reports payment and offers calendar and Messenger', async ({ page }) => {
    await mock(page); await openHeader(page); await step1(page); await step2(page);
    await expect(page.locator('#bsHeld')).toContainText('Held');
    await page.locator('#bsNext3').click();
    await expect(page.locator('#bsErr3')).toContainText('reference number');
    await expect(page.locator('#bsH3')).toBeVisible();
    await page.locator('#bsRef').fill('1234567890');
    await page.locator('#bsNext3').click();
    await expect(page.locator('#bsH4')).toHaveText('Request sent, Maria.');
    await expect(page.locator('#bsDoneKicker')).toHaveText('Payment reported');
    const [dl] = await Promise.all([page.waitForEvent('download'), page.locator('#bsIcs').click()]);
    expect(dl.suggestedFilename()).toBe('cascade-hideaway-stay.ics');
    await expect(page.locator('#bsMsgr')).toHaveAttribute('href', /^https:\/\/www\.messenger\.com\/t\/699640026568720/);
  });

  test('a shared link with ?checkin=&checkout= opens the sheet on those dates', async ({ page }) => {
    await mock(page);
    await page.goto(`/?checkin=${CI}&checkout=${CO}`);
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    await expect(page.locator('#bsRange')).toContainText('2 nights');
  });

  test('contact options are Messenger then a call button fed by app_settings; no WhatsApp; chat hook is hidden', async ({ page }) => {
    await mock(page);
    await page.route('**/rest/v1/app_settings**', (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify([{ key: 'onground_name', value: 'Ana' }, { key: 'onground_phone', value: '0917 000 1111' }]) }));
    await page.goto('/index.html');
    const links = page.locator('#contact .loc-cta-btn');
    await expect(links.nth(0)).toHaveAttribute('href', /messenger\.com\/t\/699640026568720/);
    await expect(links.nth(1)).toHaveAttribute('href', 'tel:+639170001111');
    await expect(links.nth(1)).toContainText('Ask for Ana');
    await expect(page.locator('#siteChatEntry')).toBeHidden();
    expect(await page.content()).not.toMatch(/wa\.me|api\.whatsapp/);
    expect(await page.locator('a[href="#"], a[href=""]').count()).toBe(0);
  });

  test('cover CTA without dates opens the sheet, never the old inline picker', async ({ page }) => {
    await mock(page);
    await page.goto('/index.html');
    await page.locator('#qbwSubmit').click();
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    await expect(page.locator('#bsH1')).toBeFocused();
    await expect(page.locator('#qbwPicker')).toBeHidden();
  });

  test('step 3 labels: heading, button amount, reference copy, short placeholder', async ({ page }) => {
    await mock(page); await openHeader(page);
    await step1(page); await step2(page);
    await expect(page.locator('#bsH3')).toHaveText('Hold your dates');
    await expect(page.locator('#bsNext3')).toHaveText(/^I.ve sent ₱[\d,]+$/);
    await expect(page.locator('#bsAcctB')).toContainText('Put your name in the message or notes');
    await expect(page.locator('#bsRef')).toHaveAttribute('placeholder', 'Reference no.');
  });

  test('quote failing twice shows the Messenger fallback', async ({ page }) => {
    await mock(page);
    await page.route('**/functions/v1/rate-card**', (route) => route.abort());
    await openHeader(page);
    await pickDay(page, CI); await pickDay(page, CO);
    await expect(page.locator('#bsQuoteNote')).toContainText('could not confirm');
    await page.locator('#bsNext1').click();
    await expect(page.locator('#bsQuoteNote')).toContainText('Prices are not loading. Message us and we will quote you.');
    await expect(page.locator('#bsQuoteMsgr')).toHaveAttribute('href', /messenger\.com/);
  });
});
