import { test, expect } from '@playwright/test';

// SPEC-42 s6: the booking status page. The Edge Function is mocked; the server-side rules (state mapping, token checks, allowed
// fields) are covered by the deno and pgTAP suites. Here: each state renders, an unknown token gets the neutral page, a closed
// booking shows no money, and the token travels only in the POST body.
const TOKEN = 'A'.repeat(43);
const NOW = Date.now();
const iso = (ms) => new Date(ms).toISOString();
const manilaDay = (offsetDays) => new Date(NOW + offsetDays * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
const money = { total: 4000, reservation_payment: 2000, balance_due_date: manilaDay(5), security_deposit: 1000 };
const status = (over) => ({
  ok: true,
  status: {
    state: 'held', ref: 'ABCD1234', checkin_date: '2026-10-16', checkout_date: '2026-10-18', nights: 2, pax: 2,
    checkin_time: '2:00 PM', checkout_time: '12:00 PM', hold_expires_at: iso(NOW + 5 * 3600_000), money,
    timeline: [{ key: 'requested', done: true }, { key: 'paid', done: false }, { key: 'confirmed', done: false }, { key: 'arrival', done: false }],
    can_upload_receipt: true, receipt_upload_token: 'receipt-token', receipt_upload_expires_at: iso(NOW + 1800_000), server_now: iso(NOW),
    ...over,
  },
});
async function mock(page, body, code = 200, seen = []) {
  await page.route('**/functions/v1/guest-access', async (route) => {
    seen.push({ method: route.request().method(), body: route.request().postDataJSON(), url: route.request().url() });
    await route.fulfill({ status: code, contentType: 'application/json', body: JSON.stringify(body) });
  });
}

test.describe('booking status page', () => {
  test('held: deadline, amounts, timeline, upload and the policy wording', async ({ page }) => {
    const seen = [];
    await mock(page, status(), 200, seen);
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.getByText('Your dates are held')).toBeVisible();
    await expect(page.locator('.st-hold')).toContainText('Held until');
    await expect(page.locator('#stView')).toContainText('Reference ABCD1234');
    await expect(page.locator('#stView')).toContainText('₱4,000');
    await expect(page.locator('#stView')).toContainText('₱1,000 refundable');
    await expect(page.getByRole('button', { name: 'Upload receipt' })).toBeVisible();
    await expect(page.locator('#stPolicy')).toBeVisible();
    await expect(page.locator('#stPolicy')).toContainText('A 50% reservation fee, reviewed against availability, secures your requested dates once verified.');
    await expect(page.locator('#stPolicy')).toContainText('5 or more days before check-in: the reservation fee is fully refunded.');
    expect(seen).toHaveLength(1);
    expect(seen[0].body).toEqual({ token: TOKEN, view: 'status' });
    expect(seen[0].url).not.toContain(TOKEN);
  });

  test('under review: no upload button, receipt wording', async ({ page }) => {
    await mock(page, status({ state: 'under_review', hold_expires_at: null, can_upload_receipt: false, receipt_upload_token: null,
      timeline: [{ key: 'requested', done: true }, { key: 'paid', done: true }, { key: 'confirmed', done: false }, { key: 'arrival', done: false }] }));
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.getByText('We have your receipt')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Upload receipt' })).toHaveCount(0);
    await expect(page.locator('#stView')).toContainText('under review');
  });

  const confirmed = (over) => status({ state: 'confirmed', hold_expires_at: null, can_upload_receipt: false, receipt_upload_token: null, ...over,
    timeline: [{ key: 'requested', done: true }, { key: 'paid', done: true }, { key: 'confirmed', done: true }, { key: 'arrival', done: false }] });

  test('confirmed: verified payment, "Balance due" while it is still ahead, and the arrival-details promise', async ({ page }) => {
    await mock(page, confirmed());
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.locator('#stView .st-state').first()).toHaveText('Your booking is confirmed');
    await expect(page.locator('.st-steps li.done')).toHaveCount(3);
    await expect(page.locator('#stView')).toContainText('verified');
    await expect(page.locator('#stView dt', { hasText: 'Balance due' })).toBeVisible();
    await expect(page.locator('#stView')).not.toContainText('Remaining balance');
  });

  test('confirmed with the balance due date already past (Manila date): no balance row, a settled guest owes nothing on screen', async ({ page }) => {
    await mock(page, confirmed({ money: { ...money, balance_due_date: manilaDay(-1) } }));
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.locator('#stView .st-state').first()).toHaveText('Your booking is confirmed');
    await expect(page.locator('#stView')).toContainText('Total stay');
    await expect(page.locator('#stView')).not.toContainText('Balance due');
    await expect(page.locator('#stView')).not.toContainText('Remaining balance');
  });

  for (const state of ['cancelled', 'released']) {
    test(`${state}: shows no money anywhere on the page`, async ({ page }) => {
      await mock(page, status({ state, hold_expires_at: null, can_upload_receipt: false, receipt_upload_token: null, money: null, timeline: null }));
      await page.goto(`/stay.html#t=${TOKEN}`);
      await expect(page.locator('#stView .st-state')).toBeVisible();
      await expect(page.locator('#stPolicy')).toBeHidden();
      expect(await page.locator('body').innerText()).not.toContain('₱');
    });
  }

  test('unknown token: the same neutral page, no booking facts', async ({ page }) => {
    await mock(page, { error: 'invalid_guest_access' }, 404);
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.getByText('We could not find this booking').first()).toBeVisible();
    await expect(page.locator('#stPolicy')).toBeHidden();
    expect(await page.locator('body').innerText()).not.toContain('Reference');
  });

  test('no token in the link: neutral page and no request is sent', async ({ page }) => {
    let calls = 0;
    await page.route('**/functions/v1/guest-access', (route) => { calls += 1; route.abort(); });
    await page.goto('/stay.html');
    await expect(page.getByText('We could not find this booking').first()).toBeVisible();
    expect(calls).toBe(0);
  });

  test('a server error offers a retry, not a not-found', async ({ page }) => {
    await mock(page, { error: 'guest_access_unavailable' }, 503);
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.getByRole('button', { name: 'Try again' })).toBeVisible();
  });

  test('a 200 reply with no status is a retry page, not an endless Loading', async ({ page }) => {
    await mock(page, { ok: true });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await expect(page.getByText('We could not load your booking just now')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Try again' })).toBeVisible();
    await expect(page.locator('#stView')).not.toContainText('Loading');
  });

  test('upload sends the receipt token as the bearer and nothing else identifying', async ({ page }) => {
    await mock(page, status());
    let headers = null;
    await page.route('**/functions/v1/upload-booking-receipt', async (route) => {
      headers = route.request().headers();
      await route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    });
    await page.goto(`/stay.html#t=${TOKEN}`);
    await page.locator('input[type=file]').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) });
    await page.getByRole('button', { name: 'Upload receipt' }).click();
    await expect(page.getByText('Receipt received. Thank you.')).toBeVisible();
    expect(headers.authorization).toBe('Bearer receipt-token');
    expect(headers['x-receipt-filename']).toBe('receipt.png');
    expect(JSON.stringify(headers)).not.toContain(TOKEN);
  });
});
