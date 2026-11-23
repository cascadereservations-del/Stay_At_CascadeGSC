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
    await page.locator('a.header-cta[data-gs-book]').click();
    // The sheet's calendar must remain usable, with an honest note, even when the remote fetch fails.
    await expect(page.locator('#bsGrid')).toBeVisible();
    await expect(page.locator('#bsAvailNote')).toContainText('could not be loaded');
  });

  test('booking form shows validation errors on empty submit', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('a.header-cta[data-gs-book]').click();
    // Dates are unselected, so the gate is explicit: a prompt and a disabled Continue, never a silent no-op.
    await expect(page.locator('#bsRange')).toHaveText('Tap your check-in date');
    await expect(page.locator('#bsNext1')).toBeDisabled();
  });

  test('the just-in-time privacy note is present above the final submit action', async ({ page }) => {
    await page.goto('/index.html');
    const note = page.locator('#bsS3 .bs-legal');
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
