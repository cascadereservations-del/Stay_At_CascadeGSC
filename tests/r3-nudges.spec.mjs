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
/* the sheet owns the dates: it restores them from sessionStorage and announces its own state on open, so a test that wants dates presets that store */
const presetDates = (page, ci, co) => page.addInitScript(([a, b]) => { try { sessionStorage.setItem('cascade.sheet.v1', JSON.stringify({ ci: a, co: b, guests: 2 })); } catch (e) { /* none */ } }, [ci, co]);
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

  test('N2 does not fire while the booking sheet is open', async ({ page }) => {
    once('desktop');
    await page.clock.install();
    await page.goto('/');
    await expect(page.locator('#heroBookBar')).toBeVisible();
    /* opened with the open attribute (no focus, no pointer or key event), so nothing counts as an interaction: only the open sheet can hold the hint back */
    await page.evaluate(() => document.getElementById('bookSheet').setAttribute('open', ''));
    await page.clock.runFor(9500);
    expect(await nudgeClasses(page)).toEqual([]);
    expect(await page.evaluate(() => sessionStorage.getItem('cascade.nudge.n2'))).toBeNull();
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
    await presetDates(page, day(30), day(32)); // the sheet restores two nights from the session
    await page.goto('/?utm_source=facebook&utm_medium=paid&utm_campaign=nov&fbclid=abc123');
    await page.evaluate(() => { window.dataLayer = []; });
    await page.evaluate(() => {
      document.getElementById('bsName').value = 'Zed Testperson';
      document.getElementById('bsPhone').value = '9171234567';
      document.getElementById('bsEmail').value = 'zed.test@example.invalid';
      document.getElementById('bsRef').value = 'REF987654';
      document.getElementById('bsSumTotal2').textContent = '₱3,382.5';
      document.getElementById('bsDoneTotal').textContent = '₱3,382.5';
    });
    /* a new three-night selection announced on the page: one select_dates with nights and nothing else */
    await page.evaluate(([a, b]) => document.dispatchEvent(new CustomEvent('cascade:sheet', { detail: { ci: a, co: b } })), [day(40), day(43)]);
    await page.evaluate(() => document.getElementById('bookSheet').showModal());
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    await page.evaluate(() => { document.getElementById('bsS3').hidden = false; });
    await page.evaluate(() => { document.getElementById('bsS3').hidden = true; document.getElementById('bsS4').hidden = false; });
    /* picking a range can announce an intermediate selection first; consecutive repeats of select_dates are collapsed, the order of the funnel is what is asserted */
    await expect.poll(() => page.evaluate(() => window.dataLayer.map((e) => e.event).filter((n, i, all) => n !== all[i - 1]))).toEqual(['select_dates', 'begin_checkout', 'add_payment_info', 'generate_lead']);
    const layer = await page.evaluate(() => window.dataLayer);
    const allowed = new Set(['event', 'nights', 'guests', 'value', 'currency', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'gclid', 'fbclid']);
    for (const e of layer) {
      for (const k of Object.keys(e)) expect(allowed.has(k), `${e.event} carries ${k}`).toBe(true);
      expect(e.currency).toBe('PHP');
      expect(e.utm_source).toBe('facebook');
      expect(e.fbclid).toBe('abc123');
    }
    /* hand-computed: three nights (day 40 to day 43); the total is the page's own 3,382.50, not 33,825 */
    const by = Object.fromEntries(layer.map((e) => [e.event, e]));
    expect(by.select_dates.nights).toBe(3);
    expect(by.begin_checkout.nights).toBe(3);
    expect(by.add_payment_info).toMatchObject({ nights: 3, value: 3382.5, currency: 'PHP' });
    expect(by.generate_lead).toMatchObject({ nights: 3, value: 3382.5, currency: 'PHP' });
    expect(by.select_dates.value).toBeUndefined();
    const blob = JSON.stringify(layer);
    for (const secret of ['Zed', 'Testperson', '9171234567', 'zed.test', 'example.invalid', 'REF987654']) expect(blob).not.toContain(secret);
  });

  test('begin_checkout fires once per date selection, not on every sheet open', async ({ page }) => {
    once('desktop');
    await presetDates(page, day(30), day(32));
    await page.addInitScript(() => { window.dataLayer = window.dataLayer || []; });
    await page.goto('/');
    const events = () => page.evaluate(() => window.dataLayer.filter((e) => e.event === 'begin_checkout').map((e) => e.nights));
    const openClose = async () => { await page.evaluate(() => document.getElementById('bookSheet').showModal()); await page.evaluate(() => document.getElementById('bookSheet').close()); };
    await openClose();
    await expect.poll(events).toEqual([2]);
    await openClose();
    await openClose();
    await page.waitForTimeout(200);
    expect(await events()).toEqual([2]);
    /* a new date selection is a new checkout: the next visit to the sheet with three nights fires once more (a fresh page, so a fresh data layer) */
    await presetDates(page, day(30), day(33));
    await page.reload();
    await openClose();
    await expect.poll(events).toEqual([3]);
    await openClose();
    await page.waitForTimeout(200);
    expect(await events()).toEqual([3]);
  });

  test('analytics never throws into a caller when storage is blocked, so a booking can still be submitted', async ({ page }) => {
    once('desktop');
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.addInitScript(() => {
      const boom = () => { throw new DOMException('blocked', 'SecurityError'); };
      for (const k of ['sessionStorage', 'localStorage']) Object.defineProperty(window, k, { get: boom, configurable: true });
    });
    await page.goto('/');
    await page.waitForFunction(() => !!window.CascadeAnalytics && typeof window.cascadeTrack === 'function');
    const r = await page.evaluate(() => {
      const out = {};
      for (const [k, f] of [['track', () => window.CascadeAnalytics.track('x')], ['trackWithProps', () => window.CascadeAnalytics.track('x', { a: 1 })], ['cascadeTrack', () => window.cascadeTrack('x', {})]]) {
        try { f(); out[k] = 'ok'; } catch (e) { out[k] = String(e); }
      }
      return out;
    });
    expect(r).toEqual({ track: 'ok', trackWithProps: 'ok', cascadeTrack: 'ok' });
    expect(errors.filter((e) => /analytics|CascadeAnalytics|cascadeTrack|SecurityError/i.test(e))).toEqual([]);
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

test.describe('R3 hero card: clear dark glass, light text', () => {
  const card = (page) => page.evaluate(() => {
    const el = document.getElementById('heroBookBar'), c = getComputedStyle(el), b = getComputedStyle(el, '::before');
    const col = (sel) => getComputedStyle(document.querySelector(sel)).color;
    return {
      bg: c.backgroundColor, img: c.backgroundImage, bf: c.backdropFilter, border: c.borderTopColor,
      heading: col('#heroBookBar .hero-bk-eyebrow'), label: col('#heroBookBar .hero-bk-label'), placeholder: col('#qbwCiVal'),
      pill: getComputedStyle(document.getElementById('qbwSubmit')).backgroundColor, pillInk: col('#qbwSubmit'),
      before: { img: b.backgroundImage, pe: b.pointerEvents, display: b.display, iter: b.animationIterationCount, z: b.zIndex },
    };
  });
  for (const [name, theme, tint, pill] of [['day', 'midday', 'rgba(20, 14, 8, 0.42)', 'rgba(244, 233, 210, 0.92)'], ['night', 'night', 'rgba(20, 14, 8, 0.4)', 'rgb(201, 150, 58)']]) {
    test(`${name}: tinted clear glass, no brightness boost, no white scrim, light text, ${name === 'day' ? 'cream' : 'gold'} Reserve`, async ({ page }) => {
      once('desktop');
      await page.goto(`/?theme-time=${theme}`);
      const c = await card(page);
      expect(c.bg).toBe(tint);
      expect(c.bf).toContain('blur(10px)');
      expect(c.bf).toMatch(/saturate\((1\.4|140%)\)/);
      expect(c.bf).not.toContain('brightness');
      expect(c.border).toBe('rgba(255, 244, 222, 0.22)');
      /* the dimming layer under the card is dark and at most 35 percent; the old white radial scrim is gone */
      expect(c.img).toContain('rgba(8, 5, 2, 0.35)');
      expect(c.img).not.toContain('252, 249, 243');
      expect(c.img).not.toContain('radial-gradient');
      expect(c.heading).toBe('rgb(247, 242, 232)');
      expect(c.label).toBe('rgb(233, 223, 204)');
      expect(c.placeholder).toBe('rgb(233, 223, 204)');
      expect(c.pill).toBe(pill);
      if (name === 'day') expect(c.pillInk).toBe('rgb(28, 16, 6)');
      /* G4 the gradient layer: above the tint, never captures the pointer, finite */
      expect(c.before.img).toContain('rgba(255, 236, 200, 0.16)');
      expect(c.before.img).toContain('rgba(201, 150, 58, 0.1)');
      expect(c.before.pe).toBe('none');
      expect(c.before.display).toBe('block');
      expect(c.before.iter).not.toContain('infinite');
    });
  }

  test('the light follows a fine pointer over the card and is removed when it leaves', async ({ page }) => {
    once('desktop');
    await page.goto('/?theme-time=midday');
    const box = await page.locator('#heroBookBar').boundingBox();
    const px = () => page.evaluate(() => document.getElementById('heroBookBar').style.getPropertyValue('--gs-px'));
    await page.mouse.move(box.x + 40, box.y + 30);
    await page.mouse.move(box.x + 60, box.y + 40);
    await expect.poll(px).toMatch(/^\d+px$/);
    await page.mouse.move(2, 2);
    await expect.poll(px).toBe('');
  });
});

test.describe('R3 transparency fallbacks', () => {
  for (const [name, theme] of [['day', 'midday'], ['night', 'night']]) {
    test(`high contrast gives an opaque dark hero card with the same light text (${name}); the default card is translucent and blurred`, async ({ page }) => {
      once('desktop');
      await page.goto(`/?theme-time=${theme}`);
      const card = () => page.evaluate(() => {
        const c = getComputedStyle(document.getElementById('heroBookBar')), b = getComputedStyle(document.getElementById('heroBookBar'), '::before');
        return { bg: c.backgroundColor, img: c.backgroundImage, bf: c.backdropFilter, before: b.display, label: getComputedStyle(document.querySelector('#heroBookBar .hero-bk-label')).color, pill: getComputedStyle(document.getElementById('qbwSubmit')).backgroundColor };
      });
      const normal = await card();
      expect(normal.bg).toMatch(/rgba\(/);
      expect(normal.bf).toContain('blur(10px)');
      await page.emulateMedia({ contrast: 'more' });
      await expect.poll(async () => (await card()).bg).toBe('rgb(31, 25, 18)');
      const solid = await card();
      expect(solid.bf).toBe('none');
      expect(solid.img).toBe('none');
      expect(solid.before).toBe('none');
      expect(solid.label).toBe('rgb(233, 223, 204)');
      if (name === 'day') await expect.poll(async () => (await card()).pill).toMatch(/^rgba?\(244, 233, 210(, 1)?\)$/);
    });
  }

  test('the no-backdrop-filter and reduced-transparency branches exist and turn the card opaque (read from the stylesheet: a browser cannot be made to drop backdrop-filter)', async ({ page }) => {
    once('desktop');
    await page.goto('/');
    const found = await page.evaluate(() => {
      const out = { supports: '', reduced: '' };
      const walk = (rules) => { for (const r of rules) {
        if (r.type === CSSRule.SUPPORTS_RULE && /not/.test(r.conditionText) && /backdrop-filter/.test(r.conditionText) && /--hbk-tint/.test(r.cssText)) out.supports = r.cssText;
        if (r.type === CSSRule.MEDIA_RULE && /prefers-reduced-transparency/.test(r.conditionText) && /--hbk-tint/.test(r.cssText)) out.reduced = r.cssText;
        if (r.cssRules) walk(r.cssRules);
      } };
      for (const sh of document.styleSheets) { try { walk(sh.cssRules); } catch (e) { /* cross-origin sheet */ } }
      return out;
    });
    for (const k of ['supports', 'reduced']) {
      expect(found[k], k).toMatch(/--hbk-tint:\s*#1F1912/i);
      expect(found[k], k).toMatch(/--hbk-filter:\s*none/);
      expect(found[k], k).toMatch(/#heroBookBar[^{]*::before\s*\{\s*display:\s*none\s*!important/);
    }
    expect(found.reduced).toMatch(/prefers-contrast:\s*more/);
  });
});

test.describe('R2 and G8', () => {
  test('the cancellation link has a 44 px tap height and the Cascade mark replaces the CH monogram everywhere on the page', async ({ page }) => {
    once('desktop');
    await page.goto('/');
    await page.evaluate(() => { const d = document.getElementById('bookSheet'); d.showModal(); document.getElementById('bsS3').hidden = false; });
    const link = await page.locator('#bsCancelLine a').boundingBox();
    expect(link.height).toBeGreaterThanOrEqual(44);
    expect(link.width).toBeGreaterThanOrEqual(44);
    await page.evaluate(() => document.getElementById('bookSheet').close());
    const marks = await page.evaluate(() => [...document.querySelectorAll('.iv-mono')].map((e) => ({ tag: e.tagName, src: e.getAttribute('src'), alt: e.getAttribute('alt'), text: e.textContent.trim(), w: e.getAttribute('width') })));
    expect(marks).toHaveLength(2);
    for (const m of marks) expect(m).toEqual({ tag: 'IMG', src: 'assets/images/logo-mark.png', alt: '', text: '', w: '44' });
    const res = await page.request.get('/assets/images/logo-mark.png');
    expect(res.status()).toBe(200);
    expect((await res.body()).length).toBeLessThan(20 * 1024);
  });
});
