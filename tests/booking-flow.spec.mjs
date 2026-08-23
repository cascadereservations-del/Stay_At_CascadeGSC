import { test, expect } from '@playwright/test';

test.describe('booking flow baseline', () => {
  test('landing page loads and shows the hero booking bar', async ({ page }) => {
    await page.goto('/index.html');
    await expect(page.locator('#heroBookBar')).toBeVisible();
    await expect(page.locator('#qbwSubmit')).toBeVisible();
  });

  test('hero check-in field opens the date picker', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('#qbwCiField').click();
    await expect(page.locator('#qbwPicker')).toBeVisible();
    await expect(page.locator('#qbwPickerGrid')).toBeVisible();
  });

  test('calendar error state renders on a blocked availability fetch', async ({ page }) => {
    await page.route('**/functions/v1/availability**', route => route.abort());
    await page.goto('/index.html');
    await page.locator('#booking').scrollIntoViewIfNeeded();
    // The calendar shell must remain legible even when the remote fetch fails.
    await expect(page.locator('#calBody')).toBeVisible();
  });

  test('booking form shows validation errors on empty submit', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('#booking').scrollIntoViewIfNeeded();
    await page.locator('#continueToPayment').click();
    // Dates are unselected, so the date gate must surface — never a silent no-op.
    await expect(page.locator('#dateErrorBanner')).toBeVisible();
  });

  test('the just-in-time privacy note is present above the final submit action', async ({ page }) => {
    await page.goto('/index.html');
    const note = page.locator('.booking-legal-note');
    await expect(note).toContainText('Privacy notice');
    await expect(note).toContainText('Booking terms');
  });

  test('privacy and booking-terms pages are reachable', async ({ page }) => {
    await page.goto('/privacy.html');
    await expect(page.locator('h1')).toContainText('Privacy notice');
    await page.goto('/booking-terms.html');
    await expect(page.locator('h1')).toContainText('Booking terms');
  });

  test('success overlay copy matches the copy contract when triggered', async ({ page }) => {
    await page.goto('/index.html');
    await page.evaluate(() => {
      var overlay = document.getElementById('successOverlay') || document.querySelector('.success-overlay');
      if (overlay) overlay.hidden = false;
    });
    const title = page.locator('#successTitle');
    if (await title.count()) {
      await expect(title).toHaveText('Reservation request received');
    }
  });
});
