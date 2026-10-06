import { test, expect } from '@playwright/test';

// SPEC-42 s4b: the "Before you arrive" section on the booking status page. Both Edge Functions are mocked; the token rules, photo
// checks, the 12 a day limit and the writes are covered by the deno and pgTAP suites. Here: the section shows only for a confirmed
// booking with a usable context, the form posts one multipart request with the token in the body only, results are shown honestly,
// and the page holds at 375 px with no console errors.
const TOKEN = 'B'.repeat(43);
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const confirmed = {
  ok: true,
  status: {
    state: 'confirmed', ref: 'E9200001', checkin_date: '2026-10-16', checkout_date: '2026-10-18', nights: 2, pax: 2,
    checkin_time: '2:00 PM', checkout_time: '12:00 PM', hold_expires_at: null,
    money: { total: 4000, reservation_payment: 2000, balance_due_date: '2099-01-01', security_deposit: 1000 },
    timeline: [{ key: 'requested', done: true }, { key: 'paid', done: true }, { key: 'confirmed', done: true }, { key: 'arrival', done: false }],
    can_upload_receipt: false, receipt_upload_token: null, receipt_upload_expires_at: null, server_now: new Date().toISOString(),
  },
};
const context = (over = {}) => ({ ok: true, intake: { ref: 'E9200001', checkin_date: '2026-10-16', checkout_date: '2026-10-18', pax: 2, guest_name: 'Ben Cruz', can_save: true, max_uploads_per_day: 12, uploads_today: 0, people: [], ...over } });

async function mock(page, { status = confirmed, intake = context(), intakeStatus = 200, post = (r) => ({ ok: true, results: [] }) } = {}) {
  const seen = { context: [], submit: [], errors: [] };
  page.on('console', (m) => { if (m.type() === 'error') seen.errors.push(m.text()); });
  page.on('pageerror', (e) => seen.errors.push(String(e)));
  await page.route('**/functions/v1/guest-access', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(status) }));
  await page.route('**/functions/v1/guest-intake', async (route) => {
    const req = route.request();
    if ((req.headers()['content-type'] || '').startsWith('multipart/form-data')) {
      seen.submit.push({ url: req.url(), token: req.headers()['x-guest-token'], body: req.postDataBuffer().toString('latin1') });
      const body = post(seen.submit.length);
      return route.fulfill({ status: body.status || 200, contentType: 'application/json', body: JSON.stringify(body) });
    }
    seen.context.push({ url: req.url(), body: req.postDataJSON() });
    return route.fulfill({ status: intakeStatus, contentType: 'application/json', body: JSON.stringify(intake) });
  });
  return seen;
}

test.describe('guest intake form', () => {
  test('confirmed: the section shows one card per guest, the booker first with their name, and the context call keeps the token out of the URL', async ({ page }) => {
    const seen = await mock(page);
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Before you arrive' })).toBeVisible();
    await expect(page.locator('.ai-person')).toHaveCount(2);
    await expect(page.locator('.ai-person').first().locator('legend')).toHaveText('Guest 1 (you)');
    await expect(page.locator('.ai-person').first().locator('input[type="text"]')).toHaveValue('Ben Cruz');
    await expect(page.locator('#stArrive')).toContainText('we never record the ID number');
    await expect(page.locator('#stArrive a[href="privacy.html"]')).toBeVisible();
    expect(seen.context).toHaveLength(1);
    expect(seen.context[0].body).toEqual({ token: TOKEN, action: 'context' });
    expect(seen.context[0].url).not.toContain(TOKEN);
    expect(seen.errors).toEqual([]);
  });

  test('a guest already on file shows ID received with the name locked; the booker is matched by name, not duplicated', async ({ page }) => {
    await mock(page, { intake: context({ people: [{ id: 'c1', name: 'Ben Cruz', has_id: true, id_type: 'passport' }] }) });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.locator('.ai-person')).toHaveCount(2);
    const first = page.locator('.ai-person').first();
    await expect(first.locator('legend')).toHaveText('Guest 1 (you)');
    await expect(first.locator('.ai-got')).toBeVisible();
    await expect(first.locator('input[type="text"]')).toHaveAttribute('readonly', '');
    await expect(first.locator('select')).toHaveValue('passport');
    await expect(page.locator('.ai-person').nth(1).locator('.ai-got')).toBeHidden();
  });

  test('sending: one multipart request, token and photo in the body, then a thank-you and a fresh read', async ({ page }) => {
    const seen = await mock(page, { post: () => ({ ok: true, results: [{ name: 'Ben Cruz', ok: true, photo: true }] }) });
    await page.goto(`/stay.html#t=${TOKEN}`);
    const first = page.locator('.ai-person').first();
    await first.locator('input[type="tel"]').fill('0917 000 1111');
    await first.locator('select').selectOption('passport');
    await first.locator('input[type="file"]').setInputFiles({ name: 'id.png', mimeType: 'image/png', buffer: PNG });
    await page.getByRole('button', { name: 'Send to Cascade' }).click();
    await expect(page.locator('#stArrive')).toContainText('Thank you. We have your details');
    expect(seen.submit).toHaveLength(1);
    const body = seen.submit[0].body;
    expect(seen.submit[0].url).not.toContain(TOKEN);
    expect(body).not.toContain(TOKEN);
    expect(seen.submit[0].token).toBe(TOKEN);
    expect(body).toContain('name="photo_0"');
    expect(body).toContain('"name":"Ben Cruz"');
    expect(body).toContain('"id_type":"passport"');
    expect(body).toContain('"self":true');
    expect(seen.context).toHaveLength(2); // the first read and the one after saving
    expect(seen.errors).toEqual([]);
  });

  test('a photo with no name is stopped before anything is sent', async ({ page }) => {
    const seen = await mock(page);
    await page.goto(`/stay.html#t=${TOKEN}`);
    await page.locator('.ai-person').nth(1).locator('input[type="file"]').setInputFiles({ name: 'id.png', mimeType: 'image/png', buffer: PNG });
    await page.getByRole('button', { name: 'Send to Cascade' }).click();
    await expect(page.locator('#stArrive [role="status"]')).toContainText('add a name for each ID photo');
    expect(seen.submit).toHaveLength(0);
  });

  test('a refused photo is shown by name with its reason, and the button works again', async ({ page }) => {
    await mock(page, { post: () => ({ ok: true, results: [{ name: 'Ben Cruz', ok: false, photo: false, reason: 'photo_type' }] }) });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await page.locator('.ai-person').first().locator('input[type="file"]').setInputFiles({ name: 'id.png', mimeType: 'image/png', buffer: PNG });
    await page.getByRole('button', { name: 'Send to Cascade' }).click();
    await expect(page.locator('#stArrive [role="status"]')).toContainText('Ben Cruz: Please send a JPG, PNG or WebP photo.');
    await expect(page.getByRole('button', { name: 'Send to Cascade' })).toBeEnabled();
  });

  test('a link that is no longer active, or a server error, shows a plain message and keeps the form usable', async ({ page }) => {
    await mock(page, { post: () => ({ status: 404, error: 'invalid_guest_access' }) });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await page.locator('.ai-person').first().locator('input[type="file"]').setInputFiles({ name: 'id.png', mimeType: 'image/png', buffer: PNG });
    await page.getByRole('button', { name: 'Send to Cascade' }).click();
    await expect(page.locator('#stArrive [role="status"]')).toContainText('no longer active');
  });

  test('no section when the context says the guest cannot be saved', async ({ page }) => {
    const a = await mock(page, { intake: context({ can_save: false }) });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.locator('.st-state', { hasText: 'Your booking is confirmed' })).toBeVisible();
    await expect(page.locator('#stArrive')).toBeEmpty();
    expect(a.context).toHaveLength(1);
  });

  test('a neutral 404 from guest-intake leaves the status page alone', async ({ page }) => {
    await mock(page, { intakeStatus: 404, intake: { error: 'invalid_guest_access' } });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.locator('.st-state', { hasText: 'Your booking is confirmed' })).toBeVisible();
    await expect(page.locator('#stArrive')).toBeEmpty();
  });

  test('held or under review: guest-intake is never called', async ({ page }) => {
    const held = { ...confirmed, status: { ...confirmed.status, state: 'under_review', timeline: confirmed.status.timeline } };
    const seen = await mock(page, { status: held });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.getByText('We have your receipt')).toBeVisible();
    expect(seen.context).toHaveLength(0);
  });

  test('375 px: nothing scrolls sideways, fields are full width and tall enough to tap', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await mock(page);
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.locator('.ai-person')).toHaveCount(2);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    const box = await page.locator('.ai-person').first().locator('input[type="text"]').boundingBox();
    expect(box.height).toBeGreaterThanOrEqual(44);
    expect(box.width).toBeGreaterThan(250);
    const btn = await page.getByRole('button', { name: 'Send to Cascade' }).boundingBox();
    expect(btn.height).toBeGreaterThanOrEqual(44);
  });
});
