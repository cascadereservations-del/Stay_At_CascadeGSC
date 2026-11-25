import { test, expect } from '@playwright/test';

/* Round R3 fix (R1): WCAG AA text contrast on the glass, measured on composited pixels in BOTH engines (the mobile project is WebKit, the desktop one Chromium).
   The text of the surface under test is hidden, the page is screenshotted, and every pixel inside every glyph rectangle is compared with the text colour:
   the MINIMUM contrast is asserted, not the average. Playwright's WebKit does not paint backdrop-filter, so the dimming layer and tint alone must carry the contrast.
   Every non-GET request is aborted at the route; nothing is sent. */
test.beforeEach(async ({ page }) => {
  await page.route('**/*', (route) => (route.request().method() !== 'GET' ? route.abort() : route.fallback()));
  await page.route('**/*.supabase.co/**', (route) => (route.request().method() !== 'GET' ? route.abort() : route.fulfill({ status: 200, contentType: 'application/json', body: '[]' })));
});

const AA = 4.5;
const rects = (page, sel) => page.evaluate((selector) => {
  const out = [];
  for (const el of document.querySelectorAll(selector)) {
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); let n;
    while ((n = w.nextNode())) {
      if (!n.textContent.trim()) continue;
      const rgb = getComputedStyle(n.parentElement).color.match(/[\d.]+/g).map(Number).slice(0, 3);
      const r = document.createRange(); r.selectNodeContents(n);
      for (const q of r.getClientRects()) if (q.width > 1 && q.height > 1 && q.top >= 0 && q.bottom <= innerHeight && q.left >= 0 && q.right <= innerWidth) out.push({ name: n.textContent.trim().slice(0, 20), x: q.left, y: q.top, w: q.width, h: q.height, rgb });
    }
  }
  return out;
}, sel);

async function minContrast(page, scope, sel) {
  const items = await rects(page, sel);
  const hide = await page.addStyleTag({ content: `${scope} *{color:transparent!important;-webkit-text-fill-color:transparent!important;text-shadow:none!important}` });
  const shot = (await page.screenshot()).toString('base64');
  await hide.evaluate((e) => e.remove());
  return page.evaluate(async ([b64, list]) => {
    const img = new Image(); img.src = 'data:image/png;base64,' + b64; await img.decode();
    const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
    const x = c.getContext('2d', { willReadFrequently: true }); x.drawImage(img, 0, 0);
    const k = img.width / innerWidth;
    const lin = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    const L = (r, g, b) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
    return list.map((it) => {
      const X = Math.max(0, Math.floor(it.x * k)), Y = Math.max(0, Math.floor(it.y * k)), W = Math.min(img.width - X, Math.ceil(it.w * k)), H = Math.min(img.height - Y, Math.ceil(it.h * k));
      if (W <= 0 || H <= 0) return { name: it.name, min: null };
      const d = x.getImageData(X, Y, W, H).data, lt = L(...it.rgb); let min = 99;
      for (let i = 0; i < d.length; i += 4) { const lb = L(d[i], d[i + 1], d[i + 2]); min = Math.min(min, (Math.max(lt, lb) + 0.05) / (Math.min(lt, lb) + 0.05)); }
      return { name: it.name, min: Math.round(min * 100) / 100 };
    });
  }, [shot, items]);
}

for (const theme of ['midday', 'night']) {
  test.describe(`${theme}`, () => {
    test('hero card text: heading, labels, "Add date" values and fine print hold AA on every pixel behind the glyphs', async ({ page }) => {
      await page.goto(`/?theme-time=${theme}`);
      await page.waitForTimeout(4200); // hero settle 2.4 s, card rise, gradient drift: all finished
      await page.evaluate(() => { const r = document.getElementById('heroBookBar').getBoundingClientRect(); window.scrollBy(0, Math.max(0, r.top - 24)); }); // whole card inside the screenshot
      await page.waitForTimeout(500);
      const res = await minContrast(page, '#heroBookBar', '#heroBookBar .hero-bk-eyebrow, #heroBookBar .hero-bk-label, #heroBookBar .hero-bk-date-val, #heroBookBar .gs-dock-sub, #heroBookBar .hero-bk-cta');
      expect(res.length).toBeGreaterThan(5);
      for (const r of res) expect(r.min, `${r.name}: ${r.min}`).toBeGreaterThanOrEqual(AA);
    });

    test('dock title, sub line and Reserve hold AA over the page at several scroll positions', async ({ page }) => {
      await page.goto(`/?theme-time=${theme}`);
      await page.waitForTimeout(1500);
      const height = await page.evaluate(() => document.documentElement.scrollHeight);
      for (const y of [900, 2700, 4500, 6300, Math.min(9000, height - 900)]) {
        await page.evaluate((yy) => window.scrollTo(0, yy), y);
        await expect(page.locator('#stickyBookCta')).toHaveCSS('opacity', '1');
        await page.waitForTimeout(400);
        const res = await minContrast(page, '#stickyBookCta', '#stickyBookCta .sticky-book-cta-rate strong, #stickyBookCta .sticky-book-cta-rate span, #stickyBookCta .sticky-book-cta-btn');
        expect(res.length).toBeGreaterThan(2);
        for (const r of res) expect(r.min, `scrollY ${y}, ${r.name}: ${r.min}`).toBeGreaterThanOrEqual(AA);
      }
    });
  });
}
