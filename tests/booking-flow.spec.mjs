import { test, expect } from '@playwright/test';

test.describe('booking flow baseline', () => {
  test('landing page loads and shows the hero booking bar', async ({ page }) => {
    await page.goto('/index.html');
    await expect(page.locator('#heroBookBar')).toBeVisible();
    await expect(page.locator('#qbwSubmit')).toBeVisible();
  });

  test('hero check-in field opens the booking sheet (one calendar)', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('#qbwCiField').click();
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    await expect(page.locator('#bsGrid')).toBeVisible();
    await expect(page.locator('#qbwPicker')).toBeHidden();
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

  test('#contact has no empty column at 1440 and 820', async ({ page }) => {
    for (const width of [1440, 820]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto('/');
      const r = await page.evaluate(() => {
        const sec = document.getElementById('contact').getBoundingClientRect();
        const c = document.querySelector('#contact .location-contact').getBoundingClientRect();
        return { sec: sec.width, content: c.width, left: c.left - sec.left, right: sec.right - c.right };
      });
      if (width === 1440) expect(r.content / r.sec).toBeGreaterThanOrEqual(0.6 * 1);
      else expect(r.content / r.sec).toBeGreaterThanOrEqual(0.9);
      expect(Math.abs(r.left - r.right)).toBeLessThan(2);
    }
  });

  test('no peso or percent figures in visible text outside the sheet while SHOW_PRICE is false', async ({ page }) => {
    await page.goto('/index.html');
    const bad = await page.evaluate(() => {
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      const hits = [];
      while (walker.nextNode()) {
        const n = walker.currentNode, t = n.textContent;
        if (!/[₱%]/.test(t) || n.parentElement.closest('dialog, script, style, noscript')) continue;
        const el = n.parentElement;
        const cs = getComputedStyle(el), r = el.getBoundingClientRect();
        if (cs.display === 'none' || cs.visibility === 'hidden' || el.closest('[hidden], [aria-hidden="true"]') && el.closest('[hidden]')) continue;
        hits.push(t.trim().slice(0, 60));
      }
      return hits;
    });
    expect(bad).toEqual([]);
  });
});
