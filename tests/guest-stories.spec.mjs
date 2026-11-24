import { test, expect } from '@playwright/test';

/* Guest Stories refresh (PLAN-refresh section 3 step 2, Fable r6 "tests to add").
   Chromium desktop project only: the checks set their own viewports, and the header checks drive the mouse wheel.
   Every Supabase call is mocked; no test reaches a live endpoint. */
test.beforeEach(async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop', 'viewport-driven checks run once, in the Chromium project');
  page.hosts = new Set();
  page.on('request', (r) => page.hosts.add(new URL(r.url()).hostname));
  await page.route('**/*.supabase.co/**', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: route.request().url().includes('weather-proxy') ? '{"current":{"code":0}}' : '[]' }));
});

const header = (page) => page.evaluate(() => {
  const h = document.querySelector('.site-header'); const r = h.getBoundingClientRect();
  return { hidden: h.classList.contains('gs-hdr-hide'), bottom: Math.round(r.bottom), opacity: +getComputedStyle(h).opacity, duration: getComputedStyle(h).transitionDuration };
});
const wheel = async (page, dy, n = 6) => { for (let k = 0; k < n; k++) { await page.mouse.wheel(0, dy); await page.waitForTimeout(60); } await page.waitForTimeout(450); };

const HERO_VIEWPORTS = [[360, 640], [390, 844], [844, 390], [1440, 900], [1280, 720]];
/* Where the approved mockup puts the dock CTA above the fold. At 360x640 and 844x390 the dock sits just below it and the header CTA is the first-screen booking control. */
const DOCK_ON_FIRST_SCREEN = new Set(['390x844', '1440x900', '1280x720']);

test.describe('Guest stories hero', () => {
  for (const [w, h] of HERO_VIEWPORTS) {
    test(`hero at ${w}x${h}: no overflow, 44px taps, booking CTA on the first screen, date tap opens the sheet`, async ({ page }) => {
      await page.setViewportSize({ width: w, height: h });
      await page.goto('/index.html');
      const r = await page.evaluate(() => {
        const box = (e) => { const b = e.getBoundingClientRect(); return { top: b.top, bottom: b.bottom, left: b.left, right: b.right, w: b.width, h: b.height }; };
        const shown = (e) => { const b = e.getBoundingClientRect(); return b.width > 0 && b.height > 0 && getComputedStyle(e).visibility !== 'hidden'; };
        const taps = [...document.querySelectorAll('#hero button, #hero input, #hero .hero-bk [role="button"], #hero .hero-bk a, .site-header a, .site-header button')]
          .filter(shown).map((e) => ({ id: e.id || e.className.toString().slice(0, 30), ...box(e) }));
        const firstScreenCta = [...document.querySelectorAll('[data-gs-book], #qbwSubmit')].filter(shown).some((e) => { const b = e.getBoundingClientRect(); return b.top >= 0 && b.bottom <= innerHeight && b.left >= 0 && b.right <= innerWidth; });
        return { overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth, taps, dock: box(document.getElementById('qbwSubmit')), firstScreenCta, proof: document.querySelector('.gs-hero-proof').textContent.replace(/\s+/g, ' ').trim(), hasGreet: !!document.querySelector('#hero #gsGreet') };
      });
      expect(r.overflow, 'horizontal overflow').toBeLessThanOrEqual(1);
      for (const t of r.taps) expect(Math.min(t.w, t.h), `tap target ${t.id} ${Math.round(t.w)}x${Math.round(t.h)}`).toBeGreaterThanOrEqual(44);
      expect(r.firstScreenCta, 'a booking CTA is fully visible on the first screen').toBe(true);
      if (DOCK_ON_FIRST_SCREEN.has(`${w}x${h}`)) expect(r.dock.bottom, 'dock CTA above the fold').toBeLessThanOrEqual(h);
      expect(r.dock.h).toBeGreaterThanOrEqual(44);
      expect(r.proof).toBe('★ 4.97 from 64 reviews·97% gave five stars');
      expect(r.hasGreet, '#gsGreet moved out of the hero').toBe(false);

      await page.locator('#qbwCiField').click();
      await expect.poll(() => page.evaluate(() => document.getElementById('bookSheet').open)).toBe(true);
      const after = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(after, 'overflow with the picker (sheet) open').toBeLessThanOrEqual(1);
    });
  }
});

test.describe('Guest stories header auto-hide', () => {
  test('phone 390: hides on scroll down, shows on scroll up, on Tab focus, after the sheet closes, at top', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await page.mouse.move(200, 400);
    expect((await header(page)).hidden).toBe(false);
    await wheel(page, 200);
    let s = await header(page); expect(s.hidden).toBe(true); expect(s.bottom).toBeLessThanOrEqual(0);
    await wheel(page, -120, 2);
    s = await header(page); expect(s.hidden).toBe(false); expect(s.bottom).toBeGreaterThan(0);

    await wheel(page, 200);
    expect((await header(page)).hidden).toBe(true);
    await page.evaluate(() => document.activeElement && document.activeElement.blur());
    for (let i = 0; i < 8 && !(await page.evaluate(() => !!document.activeElement.closest('.site-header'))); i++) await page.keyboard.press('Tab');
    await page.waitForTimeout(400);
    s = await header(page); expect(s.hidden, 'keyboard focus inside shows the header').toBe(false); expect(s.bottom).toBeGreaterThan(0);
    await wheel(page, 200, 3);
    expect((await header(page)).hidden, 'a focused header does not hide').toBe(false);

    await page.evaluate(() => document.activeElement.blur());
    await wheel(page, 200);
    expect((await header(page)).hidden).toBe(true);
    await page.evaluate(() => window.CascadeSheet.open({}));
    await expect.poll(() => page.evaluate(() => document.getElementById('bookSheet').open)).toBe(true);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);
    expect((await header(page)).hidden, 'sheet close shows the header').toBe(false);

    await page.evaluate(() => scrollTo(0, 0)); await page.waitForTimeout(400);
    expect((await header(page)).hidden).toBe(false);
  });

  for (const w of [1440, 1024]) {
    test(`desktop ${w}: the header (the only desktop booking CTA) never hides`, async ({ page }) => {
      await page.setViewportSize({ width: w, height: 900 });
      await page.goto('/index.html');
      await page.mouse.move(400, 400);
      await wheel(page, 350, 6);
      const s = await header(page);
      expect(await page.evaluate(() => scrollY)).toBeGreaterThan(1500);
      expect(s.bottom).toBeGreaterThan(0);
      expect(s.opacity).toBe(1);
      await expect(page.locator('.site-header a.header-cta[data-gs-book]')).toBeInViewport();
    });
  }

  test('reduced motion: the header hides instantly', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await page.mouse.move(200, 400);
    await wheel(page, 200);
    const s = await header(page);
    expect(s.hidden).toBe(true);
    for (const d of s.duration.split(',')) expect(parseFloat(d)).toBeLessThan(0.001);
  });
});

test.describe('Guest stories lightbox', () => {
  test('opens the widest image, arrows step, Esc closes and returns focus', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    const tile = page.locator('#photos .gs-strip-img').first();
    await tile.scrollIntoViewIfNeeded();
    const widest = await tile.evaluate((el) => { let best = '', bw = 0; el.getAttribute('srcset').split(',').forEach((c) => { const [u, w] = c.trim().split(/\s+/); if (parseInt(w, 10) > bw) { bw = parseInt(w, 10); best = new URL(u, document.baseURI).href; } }); return best; });
    await tile.click();
    await expect.poll(() => page.evaluate(() => document.querySelector('.gs-lb').open)).toBe(true);
    expect(await page.locator('.gs-lb-img').getAttribute('src')).toBe(widest);
    const count = async () => parseInt(await page.locator('.gs-lb-count').textContent(), 10);
    const c0 = await count();
    await page.keyboard.press('ArrowRight'); expect(await count()).toBe(c0 + 1);
    await page.keyboard.press('ArrowLeft'); expect(await count()).toBe(c0);
    await page.keyboard.press('Escape');
    await expect.poll(() => page.evaluate(() => document.querySelector('.gs-lb').open)).toBe(false);
    await expect.poll(() => page.evaluate(() => document.activeElement.classList.contains('gs-zoomable'))).toBe(true);
    expect(await page.evaluate(() => document.documentElement.classList.contains('gs-lb-open'))).toBe(false);
  });
});

test.describe('Guest stories motion and network', () => {
  test('reduced motion: 0 running infinite animations and no reveal classes added', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    const H = await page.evaluate(() => document.body.scrollHeight);
    for (let y = 0; y < H; y += 1400) {
      await page.evaluate((v) => scrollTo(0, v), y); await page.waitForTimeout(150);
      const inf = await page.evaluate(() => document.getAnimations().filter((a) => a.effect && a.effect.getTiming().iterations === Infinity && a.playState === 'running').length);
      expect(inf, `infinite animations at y=${y}`).toBe(0);
    }
    expect(await page.evaluate(() => document.querySelectorAll('.gs-rv').length)).toBe(0);
  });

  test('rating renders from RATING; no page errors; only local, font and (mocked) Supabase hosts', async ({ page }) => {
    const errors = []; page.on('pageerror', (e) => errors.push(String(e)));
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto('/index.html', { waitUntil: 'networkidle' });
    expect(await page.locator('[data-rating="fiveStar"]').allTextContents()).toEqual(['97%', '97%']);
    await expect(page.locator('#airbnbProofVerifiedNote')).toContainText('Verified on 24 Nov 2026');
    expect(errors).toEqual([]);
    for (const h of page.hosts) expect(h).toMatch(/^(127\.0\.0\.1|localhost|fonts\.googleapis\.com|fonts\.gstatic\.com|[a-z0-9]+\.supabase\.co)$/);
  });
});
