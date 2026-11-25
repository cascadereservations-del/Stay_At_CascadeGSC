import { test, expect } from '@playwright/test';

/* Round R3: calm nudges, the event layer and the transparency fallbacks.
   Every non-GET request is aborted at the route and Supabase GETs return an empty list: nothing is sent, nothing is booked. */
test.beforeEach(async ({ page }) => {
  await page.route('**/*', (route) => (route.request().method() !== 'GET' ? route.abort() : route.fallback()));
  await page.route('**/*.supabase.co/**', (route) => (route.request().method() !== 'GET' ? route.abort() : route.fulfill({ status: 200, contentType: 'application/json', body: '[]' })));
});
const infinite = (page) => page.evaluate(() => document.getAnimations().filter((a) => a.effect && a.effect.getTiming().iterations === Infinity && a.playState === 'running').length);
const nudgeClasses = (page) => page.evaluate(() => [...document.querySelectorAll('[class*="gs-n1"],[class*="gs-n2"]')].map((e) => e.id || e.className));
const dates = (page, ci, co) => page.evaluate(([a, b]) => document.dispatchEvent(new CustomEvent('cascade:sheet', { detail: { ci: a, co: b } })), [ci, co]);
const day = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
const once = (name) => test.skip(test.info().project.name !== name, 'logic is engine independent; run once');

test.describe('R3 nudges', () => {
  test('motion allowed: idle hint plays once and is finite, ready cue replays only when the dates change, nothing loops', async ({ page }) => {
    once('desktop');
    await page.clock.install();
    await page.goto('/');
    await expect(page.locator('#heroBookBar')).toBeVisible();
    await page.clock.runFor(8300);
    await expect(page.locator('#qbwSubmit')).toHaveClass(/gs-n2/);
    expect(await infinite(page)).toBe(0);
    await page.clock.runFor(2500);
    await expect.poll(() => nudgeClasses(page)).toEqual([]);
    expect(await page.evaluate(() => sessionStorage.getItem('cascade.nudge.n2'))).toBe('1');
    await dates(page, day(30), day(32));
    await expect(page.locator('#qbwSubmit')).toHaveClass(/gs-n1/);
    await page.clock.runFor(2500);
    await expect.poll(() => nudgeClasses(page)).toEqual([]);
    await dates(page, day(30), day(32));
    expect(await nudgeClasses(page)).toEqual([]);
    await dates(page, day(30), day(33));
    await expect(page.locator('#qbwSubmit')).toHaveClass(/gs-n1/);
    expect(await infinite(page)).toBe(0);
  });

  test('any interaction cancels the idle hint for the visit', async ({ page }) => {
    once('desktop');
    await page.clock.install();
    await page.goto('/');
    await page.mouse.move(200, 200);
    await page.mouse.down();
    await page.mouse.up();
    await page.clock.runFor(9000);
    expect(await nudgeClasses(page)).toEqual([]);
  });

  test('reduced motion: no nudge class is ever set and nothing loops', async ({ page }) => {
    once('desktop');
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.clock.install();
    await page.goto('/');
    await page.clock.runFor(9000);
    await dates(page, day(30), day(32));
    await page.clock.runFor(1000);
    expect(await nudgeClasses(page)).toEqual([]);
    expect(await infinite(page)).toBe(0);
  });
});

test.describe('R3 event layer', () => {
  test('cascadeTrack events carry only nights, guests, value, currency and campaign keys; typed personal data never appears', async ({ page }) => {
    once('desktop');
    await page.goto('/?utm_source=facebook&utm_medium=paid&utm_campaign=nov&fbclid=abc123');
    await page.evaluate(() => { window.dataLayer = []; });
    await page.evaluate(() => {
      document.getElementById('bsName').value = 'Zed Testperson';
      document.getElementById('bsPhone').value = '9171234567';
      document.getElementById('bsEmail').value = 'zed.test@example.invalid';
      document.getElementById('bsRef').value = 'REF987654';
      document.getElementById('bsSumTotal2').textContent = '₹3,382';
      document.getElementById('bsDoneTotal').textContent = '₹3,382';
    });
    await dates(page, day(30), day(32));
    await page.locator('#qbwSubmit').click();
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    await page.evaluate(() => { document.getElementById('bsS3').hidden = false; });
    await page.evaluate(() => { document.getElementById('bsS3').hidden = true; document.getElementById('bsS4').hidden = false; });
    await expect.poll(() => page.evaluate(() => window.dataLayer.map((e) => e.event))).toEqual(['select_dates', 'begin_checkout', 'add_payment_info', 'generate_lead']);
    const layer = await page.evaluate(() => window.dataLayer);
    const allowed = new Set(['event', 'nights', 'guests', 'value', 'currency', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'gclid', 'fbclid']);
    for (const e of layer) {
      for (const k of Object.keys(e)) expect(allowed.has(k), `${e.event} carries ${k}`).toBe(true);
      expect(e.currency).toBe('PHP');
      expect(e.utm_source).toBe('facebook');
      expect(e.fbclid).toBe('abc123');
    }
    const blob = JSON.stringify(layer);
    for (const secret of ['Zed', 'Testperson', '9171234567', 'zed.test', 'example.invalid', 'REF987654']) expect(blob).not.toContain(secret);
  });

  test('view_item fires on load and the campaign is kept from the first touch', async ({ page }) => {
    once('desktop');
    await page.addInitScript(() => { window.dataLayer = window.dataLayer || []; });
    await page.goto('/?utm_source=google&gclid=g1');
    await expect.poll(() => page.evaluate(() => window.dataLayer.map((e) => e.event))).toContain('view_item');
    await page.goto('/?utm_source=other');
    expect(await page.evaluate(() => JSON.parse(sessionStorage.getItem('cascade_utm')))).toEqual({ utm_source: 'google', gclid: 'g1' });
  });
});

test.describe('R3 structured data', () => {
  test('both JSON-LD blocks parse; no rating markup; FAQ answers equal the visible answers', async ({ page }) => {
    once('desktop');
    await page.goto('/');
    const r = await page.evaluate(() => {
      const blocks = [...document.querySelectorAll('script[type="application/ld+json"]')].map((s) => JSON.parse(s.textContent));
      const faq = blocks.find((b) => b['@type'] === 'FAQPage');
      const visible = [...document.querySelectorAll('.faq-answer')].map((e) => e.textContent.replace(/\s+/g, ' ').trim());
      return { types: blocks.map((b) => b['@type']), raw: JSON.stringify(blocks), answers: faq.mainEntity.map((q) => q.acceptedAnswer.text.replace(/\s+/g, ' ').trim()), visible };
    });
    expect(r.types).toEqual(['LodgingBusiness', 'FAQPage']);
    expect(r.raw).not.toMatch(/aggregateRating|"review"/);
    expect(r.answers.length).toBeGreaterThan(5);
    const all = r.visible.join(' ');
    for (const a of r.answers) expect(all, a.slice(0, 50)).toContain(a);
  });
});

test.describe('R3 transparency fallbacks', () => {
  for (const [name, theme, opaque] of [['day', 'midday', 'rgb(249, 246, 240)'], ['night', 'night', 'rgb(31, 25, 18)']]) {
    test(`high contrast gives an opaque hero card (${name}); the default card is translucent and blurred`, async ({ page }) => {
      once('desktop');
      await page.goto(`/?theme-time=${theme}`);
      const card = () => page.evaluate(() => { const c = getComputedStyle(document.getElementById('heroBookBar')); return { bg: c.backgroundColor, img: c.backgroundImage, bf: c.backdropFilter }; });
      const normal = await card();
      expect(normal.bg).toMatch(/rgba\(/);
      expect(normal.bf).toContain('blur(22px)');
      await page.emulateMedia({ contrast: 'more' });
      await expect.poll(async () => (await card()).bg).toBe(opaque);
      const solid = await card();
      expect(solid.bf).toBe('none');
      expect(solid.img).toBe('none');
    });
  }
});
