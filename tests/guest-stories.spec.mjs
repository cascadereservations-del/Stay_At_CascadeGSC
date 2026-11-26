import { test, expect } from '@playwright/test';

/* Guest Stories refresh (PLAN-refresh section 3 step 2, Fable r6 "tests to add").
   Chromium desktop project, plus the iPhone (WebKit) project for tests tagged @webkit (phone header, lightbox):
   the checks set their own viewports; desktop drives the mouse wheel, the touch project scrolls with scrollBy.
   Every Supabase call is mocked; no test reaches a live endpoint. */
test.beforeEach(async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop' && !testInfo.tags.includes('@webkit'), 'viewport-driven checks run once, in the Chromium project');
  page.touchScroll = testInfo.project.name === 'mobile';
  page.hosts = new Set();
  page.on('request', (r) => page.hosts.add(new URL(r.url()).hostname));
  await page.route('**/*.supabase.co/**', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: route.request().url().includes('weather-proxy') ? '{"current":{"code":0}}' : '[]' }));
});

const header = (page) => page.evaluate(() => {
  const h = document.querySelector('.site-header'); const r = h.getBoundingClientRect();
  return { hidden: h.classList.contains('gs-hdr-hide'), bottom: Math.round(r.bottom), opacity: +getComputedStyle(h).opacity, duration: getComputedStyle(h).transitionDuration };
});
const wheel = async (page, dy, n = 6) => {
  for (let k = 0; k < n; k++) { if (page.touchScroll) await page.evaluate((v) => scrollBy(0, v), dy); else await page.mouse.wheel(0, dy); await page.waitForTimeout(60); }
  await page.waitForTimeout(450);
};

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
        return { overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth, taps, dock: box(document.getElementById('qbwSubmit')), firstScreenCta, heroProof: !!document.querySelector('#hero .gs-hero-proof'), hasGreet: !!document.querySelector('#hero #gsGreet') };
      });
      expect(r.overflow, 'horizontal overflow').toBeLessThanOrEqual(1);
      for (const t of r.taps) expect(Math.min(t.w, t.h), `tap target ${t.id} ${Math.round(t.w)}x${Math.round(t.h)}`).toBeGreaterThanOrEqual(44);
      expect(r.firstScreenCta, 'a booking CTA is fully visible on the first screen').toBe(true);
      if (DOCK_ON_FIRST_SCREEN.has(`${w}x${h}`)) expect(r.dock.bottom, 'dock CTA above the fold').toBeLessThanOrEqual(h);
      expect(r.dock.h).toBeGreaterThanOrEqual(44);
      expect(r.heroProof, 'R4: the hero five-star line is gone (the rating band keeps the share)').toBe(false);
      expect(r.hasGreet, '#gsGreet moved out of the hero').toBe(false);

      await page.locator('#qbwCiField').click();
      await expect.poll(() => page.evaluate(() => document.getElementById('bookSheet').open)).toBe(true);
      const after = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(after, 'overflow with the picker (sheet) open').toBeLessThanOrEqual(1);
    });
  }
});

test.describe('Guest stories header auto-hide', () => {
  test('phone 390: the wordmark header scrolls away and never returns; the dock is the one persistent CTA', { tag: '@webkit' }, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await page.mouse.move(200, 400);
    expect((await header(page)).bottom, 'header visible at the top').toBeGreaterThan(0);
    await wheel(page, 500, 4);
    await expect.poll(async () => (await header(page)).bottom, { timeout: 1500 }).toBeLessThanOrEqual(0);
    await wheel(page, -120, 2);
    expect((await header(page)).bottom, 'scrolling up does not bring the header back').toBeLessThanOrEqual(0);
    await page.evaluate(() => scrollTo(0, 1200)); /* the dock hides only over the booking section and the hero */
    await expect(page.locator('#stickyBookCta')).toBeInViewport();
  });

  for (const w of [1440, 1024]) {
    test(`desktop ${w}: the header scrolls away and the bottom dock stays as the booking CTA`, async ({ page }) => {
      await page.setViewportSize({ width: w, height: 900 });
      await page.goto('/index.html');
      await page.mouse.move(400, 400);
      await wheel(page, 350, 6);
      const s = await header(page);
      expect(await page.evaluate(() => scrollY)).toBeGreaterThan(1500);
      expect(s.bottom).toBeLessThanOrEqual(0);
      await expect(page.locator('#stickyBookCta')).toBeInViewport();
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
  test('opens the widest image, arrows step, Esc closes and returns focus', { tag: '@webkit' }, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    /* WebKit run: reduced motion takes the no-View-Transition Esc path (native dialog cancel) */
    if (page.touchScroll) await page.emulateMedia({ reducedMotion: 'reduce' });
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
    expect(await page.evaluate(() => document.activeElement === document.querySelector('#photos .gs-strip-img')), 'focus returns to the photo last shown').toBe(true);
    expect(await page.evaluate(() => document.documentElement.classList.contains('gs-lb-open'))).toBe(false);
  });
});

/* Round D (D1): while the concierge auto-hide has it hidden (on the hero, over a CTA), its button must take no taps and no focus */
test.describe('Concierge float while hidden', () => {
  for (const theme of ['midday', 'night']) {
    test(`${theme}: the hidden button is not hit-testable, not focusable, and never steals a tap from the hero Reserve button`, { tag: '@webkit' }, async ({ page }) => {
      await page.goto('/?theme-time=' + theme);
      await expect(page.locator('#conciergeFloat')).toHaveClass(/is-hidden/);
      await expect(page.locator('#conciergeFloat')).toHaveCSS('visibility', 'hidden');
      const spot = await page.evaluate(() => { const b = document.getElementById('conciergeTrigger').getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; });
      const hit = (pt) => page.evaluate(({ x, y }) => { const h = document.elementFromPoint(x, y); return { concierge: !!(h && h.closest('#conciergeTrigger, #conciergePanel')), submit: !!(h && h.closest('#qbwSubmit')) }; }, pt);
      expect((await hit(spot)).concierge).toBe(false);
      /* scroll so the hero Reserve button sits under the (hidden) button's centre, where the button's box reaches it */
      await page.evaluate(async () => {
        window.__reserveClicks = 0;
        document.getElementById('qbwSubmit').addEventListener('click', (e) => { window.__reserveClicks++; e.preventDefault(); e.stopImmediatePropagation(); }, true);
        const s = document.getElementById('qbwSubmit').getBoundingClientRect(), t = document.getElementById('conciergeTrigger').getBoundingClientRect();
        scrollBy({ top: (s.top + s.height / 2) - (t.top + t.height / 2), behavior: 'instant' }); await new Promise((r) => setTimeout(r, 500));
      });
      const over = await page.evaluate(() => { const s = document.getElementById('qbwSubmit').getBoundingClientRect(), t = document.getElementById('conciergeTrigger').getBoundingClientRect(); const x = Math.max(s.left, t.left) + 4, y = t.top + t.height / 2; return { x, y, inside: x >= s.left && x <= s.right && y >= s.top && y <= s.bottom && x >= t.left && x <= t.right }; });
      if (over.inside) {
        expect(await hit(over)).toEqual({ concierge: false, submit: true });
        await page.mouse.click(over.x, over.y);
        expect(await page.evaluate(() => window.__reserveClicks)).toBe(1);
        expect(await page.evaluate(() => document.getElementById('conciergePanel').classList.contains('is-open'))).toBe(false);
      }
      /* Tab from the top of the page never lands on the hidden button */
      await page.evaluate(() => { scrollTo({ top: 0, behavior: 'instant' }); document.activeElement && document.activeElement.blur(); });
      await expect(page.locator('#conciergeFloat')).toHaveClass(/is-hidden/);
      for (let k = 0; k < 12; k++) {
        await page.keyboard.press('Tab');
        const bad = await page.evaluate(() => { const f = document.getElementById('conciergeFloat'); return !!document.activeElement.closest('#conciergeFloat') && getComputedStyle(f).visibility === 'hidden'; });
        expect(bad).toBe(false);
        if (!(await page.evaluate(() => document.getElementById('conciergeFloat').classList.contains('is-hidden')))) break;
      }
    });
  }
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
    expect(await page.locator('[data-rating="fiveStar"]').allTextContents()).toEqual(['97%']); /* R4: the hero line is gone; the rating band keeps the share */
    await expect(page.locator('#airbnbProofVerifiedNote')).toContainText('Verified on 24 Nov 2026');
    expect(errors).toEqual([]);
    /* Chromium keeps the scroll-driven zoom (html.gs-sda); WebKit is gated out (Fable r6 N6) */
    expect(await page.evaluate(() => document.documentElement.classList.contains('gs-sda') && getComputedStyle(document.querySelector('.gs-stage-img')).animationName)).toContain('gs-zoomout');
    for (const h of page.hosts) expect(h).toMatch(/^(127\.0\.0\.1|localhost|fonts\.googleapis\.com|fonts\.gstatic\.com|[a-z0-9]+\.supabase\.co)$/);
  });
});
