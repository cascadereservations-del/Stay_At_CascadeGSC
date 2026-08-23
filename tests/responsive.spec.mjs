import { test, expect } from '@playwright/test';

const widths = [390, 640, 768, 1024, 1440];

test.describe('responsive contract', () => {
  for (const width of widths) {
    test(`no horizontal overflow at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await page.goto('/index.html');
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow).toBeLessThanOrEqual(1);
    });

    test(`hero and booking bar stay inside the viewport at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await page.goto('/index.html');
      const hero = page.locator('.luxury-hero-grid');
      const booking = page.locator('#heroBookBar');
      await expect(hero).toBeVisible();
      await expect(booking).toBeVisible();

      const box = await booking.boundingBox();
      expect(box).not.toBeNull();
      expect(box.x).toBeGreaterThanOrEqual(-1);
      expect(box.x + box.width).toBeLessThanOrEqual(width + 1);
    });
  }

  test('body background uses the quiet-luxury bone token', async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 900 });
    await page.goto('/index.html');
    await expect(page.locator('body')).toHaveCSS('background-color', 'rgb(251, 248, 242)');
  });

  test('submit control uses the restrained radius token', async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 900 });
    await page.goto('/index.html');
    await expect(page.locator('#qbwSubmit')).toHaveCSS('border-radius', '4px');
  });

  test('no visible interactive target under 44x44 in the booking section (mobile)', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await page.locator('#booking').scrollIntoViewIfNeeded();
    const undersized = await page.evaluate(() => {
      const selectors = '#bookingStep1 button, #bookingStep1 a, #bookingStep1 [role="button"]';
      const bad = [];
      document.querySelectorAll(selectors).forEach(el => {
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return; // not rendered
        if (r.width < 44 || r.height < 44) bad.push({ id: el.id, w: r.width, h: r.height });
      });
      return bad;
    });
    expect(undersized, JSON.stringify(undersized)).toEqual([]);
  });

  test('section nav is hidden below 768px', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await expect(page.locator('#sectionNav')).toBeHidden();
  });

  test('concierge is hidden while the booking section is in view', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await page.locator('#booking').scrollIntoViewIfNeeded();
    await page.waitForTimeout(150);
    await expect(page.locator('#conciergeFloat')).toHaveClass(/is-hidden/);
  });

  test('sticky bottom booking CTA is visible on mobile before the booking section', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await expect(page.locator('#stickyBookCta')).toBeVisible();
  });
});
