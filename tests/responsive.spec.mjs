import { test, expect } from '@playwright/test';

const widths = [360, 390, 600, 820, 1024, 1180, 1440, 1920];

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

  for (const width of widths) {
      test(`no horizontal overflow in the booking sheet at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 800 });
      await page.goto('/index.html');
      await page.locator('a.header-cta[data-gs-book]').click();
      const r = await page.evaluate(() => { const p = document.querySelector('.bs-panel').getBoundingClientRect(); const sc = document.querySelector('.bs-scroll'); return { left: p.left, right: p.right, over: sc.scrollWidth - sc.clientWidth, doc: document.documentElement.scrollWidth - document.documentElement.clientWidth }; });
      expect(r.left, `panel left at ${width}`).toBeGreaterThanOrEqual(-1);
      expect(r.right, `panel right at ${width}`).toBeLessThanOrEqual(width + 1);
      expect(r.over, `sheet content overflow at ${width}`).toBeLessThanOrEqual(1);
      expect(r.doc, `document overflow at ${width}`).toBeLessThanOrEqual(1);
  });
  }

  test('no button or CTA label wraps onto a second line at any width', async ({ page }) => {
    for (const width of widths) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto('/index.html');
      const wrapped = await page.evaluate(() => {
        const out = [];
        document.querySelectorAll('button, a.btn, a.gs-btn, .hero-bk-cta, .header-cta, .sticky-book-cta-btn, .loc-cta-btn').forEach(el => {
          const r = el.getBoundingClientRect();
          if (!r.width || !r.height || el.closest('dialog') || el.closest('[hidden]') || getComputedStyle(el).visibility === 'hidden') return;
          const txt = (el.innerText || '').trim();
          if (!txt || txt.length > 32 || txt.indexOf('\n') > -1) return;
          const range = document.createRange(); range.selectNodeContents(el);
          const tops = new Set(Array.from(range.getClientRects()).filter(x => x.width > 1).map(x => Math.round(x.top / 4)));
          if (tops.size > 1) out.push({ txt, id: el.id, cls: el.className.toString().slice(0, 40) });
        });
        return out;
      });
      expect(wrapped, `wrapped labels at ${width}`).toEqual([]);
    }
  });

  test('body background uses the quiet-luxury bone token', async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 900 });
    await page.goto('/index.html');
    await expect(page.locator('body')).toHaveCSS('background-color', 'rgb(249, 246, 240)');
  });

  test('submit control uses the restrained radius token', async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 900 });
    await page.goto('/index.html');
    await expect(page.locator('#qbwSubmit')).toHaveCSS('border-radius', '4px');
  });

  for (const width of [360, 390]) {
  test(`no visible interactive target under 44x44 in the booking sheet at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    await page.goto('/index.html');
    await page.locator('a.header-cta[data-gs-book]').click();
    const undersized = await page.evaluate(() => {
      const selectors = '#bsS1 button, #bsS1 a, #bsS1 [role="button"], #bsClose, #bsBack';
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
  }

  for (const width of [360, 390]) {
    test(`landing nearby chips are at least 44px tall at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await page.goto('/index.html');
      const small = await page.evaluate(() => Array.from(document.querySelectorAll('.nearby-chip')).map(el => el.getBoundingClientRect().height).filter(h => h > 0 && h < 43.5));
      expect(small).toEqual([]);
      expect(await page.evaluate(() => document.querySelectorAll('.nearby-chip').length)).toBeGreaterThan(0);
    });
  }

  test('section nav is hidden below 768px', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await expect(page.locator('#sectionNav')).toBeHidden();
  });

  test('concierge and sticky CTA are hidden while the booking sheet is open', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await page.locator('a.header-cta[data-gs-book]').click();
    await expect(page.locator('#conciergeFloat')).toBeHidden();
    await expect(page.locator('#stickyBookCta')).toBeHidden();
  });

  test('sticky bottom booking CTA is visible on mobile before the booking section', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await expect(page.locator('#stickyBookCta')).toBeVisible();
  });

  test('conversion-critical images decode successfully (Task 6 broken-image guard)', async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 900 });
    await page.goto('/index.html');
    // Only the active hero slide is guaranteed to be loaded eagerly; other
    // slides in the carousel load lazily as the user cycles through them.
    const targets = ['.hero-slide.is-active img', '.gallery-mosaic img'];
    for (const selector of targets) {
      const imgs = page.locator(selector);
      const count = await imgs.count();
      for (let i = 0; i < Math.min(count, 5); i++) {
        const img = imgs.nth(i);
        // Playwright's scrollIntoViewIfNeeded() waits for the element to be
        // "stable". The hero slideshow cross-fades forever, so that wait can
        // never settle and the guard timed out instead of checking anything.
        // Scroll through the DOM directly, then read naturalWidth.
        await img.evaluate(el => el.scrollIntoView({ block: 'center', behavior: 'instant' }));
        await expect.poll(
          () => img.evaluate(el => el.complete ? el.naturalWidth : 0),
          { timeout: 15000, message: `${selector} #${i} failed to decode` },
        ).toBeGreaterThan(0);
      }
    }
  });
});
