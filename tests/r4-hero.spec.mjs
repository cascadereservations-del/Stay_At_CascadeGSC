import { test, expect } from '@playwright/test';

/* Round R4 (s137): the hero lost its five-star line, the text group sits right above the "Select your dates" card, and the wordmark is a script face.
   Every non-GET request is aborted at the route; nothing is sent. */
test.beforeEach(async ({ page }) => {
  await page.route('**/*', (route) => (route.request().method() !== 'GET' ? route.abort() : route.fallback()));
  await page.route('**/*.supabase.co/**', (route) => (route.request().method() !== 'GET' ? route.abort() : route.fulfill({ status: 200, contentType: 'application/json', body: '[]' })));
});

const SIZES = [{ name: 'phone', w: 390, h: 844, gap: 16 }, { name: 'laptop', w: 1024, h: 768, gap: 24 }, { name: 'desktop', w: 1280, h: 800, gap: 24 }];

for (const sz of SIZES) {
  test(`R4 hero at ${sz.name}: no 97% line, attribution box ${sz.gap}px above the card, Reserve visible, no overlap, no page error`, async ({ page }) => {
    const errors = []; page.on('pageerror', (e) => errors.push(String(e)));
    await page.setViewportSize({ width: sz.w, height: sz.h });
    await page.goto('/?theme-time=midday', { waitUntil: 'load' });
    await expect(page.locator('#heroBookBar')).toBeVisible();
    const m = await page.evaluate(() => {
      const q = (s) => document.querySelector(s).getBoundingClientRect();
      const hero = document.getElementById('hero');
      return {
        heroText: hero.textContent,
        heroProof: !!hero.querySelector('.gs-hero-proof, [data-rating="fiveStar"]'),
        proofText: document.getElementById('proof') ? document.getElementById('proof').textContent : document.body.textContent,
        copy: q('.luxury-hero-copy'), attrib: q('.gs-attrib'), eyebrow: q('.gs-eb--hero'), card: q('#heroBookBar'), logo: q('.site-logo'), logoName: q('.logo-name'),
        reserve: [...document.querySelectorAll('#heroBookBar .hero-bk-cta, #heroBookBar #qbwSubmit')].map((e) => { const r = e.getBoundingClientRect(); return { t: r.top, b: r.bottom, vis: r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden' }; }),
        sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth,
      };
    });
    expect(m.heroText).not.toMatch(/97\s?%|gave five stars/);
    expect(m.heroProof).toBe(false);
    expect(m.proofText).toMatch(/97%/); /* the lower proof line stays */
    const gap = m.card.top - m.attrib.bottom;
    expect(Math.abs(gap - sz.gap), `attribution bottom to card top is ${gap}`).toBeLessThanOrEqual(0.5);
    expect(m.copy.bottom).toBeLessThanOrEqual(m.card.top + 1);
    expect(m.eyebrow.top, 'group clears the wordmark').toBeGreaterThan(m.logo.bottom);
    expect(m.card.bottom).toBeLessThanOrEqual(sz.h);
    const visibleReserve = m.reserve.filter((r) => r.vis && r.t >= 0 && r.b <= sz.h);
    expect(visibleReserve.length, 'Reserve pill in the first viewport').toBeGreaterThanOrEqual(1);
    expect(m.sw).toBeLessThanOrEqual(m.cw);
    expect(errors).toEqual([]);
  });
}

/* R4b: the brand link clips (overflow hidden) on small phones: the whole name must sit inside it at every phone width */
for (const w of [320, 340, 360, 390]) {
  test(`R4b wordmark is not clipped at ${w}px`, async ({ page }) => {
    await page.setViewportSize({ width: w, height: 700 });
    await page.goto('/?theme-time=midday', { waitUntil: 'load' });
    await page.evaluate(() => document.fonts.ready);
    const r = await page.evaluate(() => {
      const e = document.querySelector('.site-header .logo-name'), rg = document.createRange(); rg.selectNodeContents(e);
      const t = rg.getBoundingClientRect(), box = e.getBoundingClientRect(); let clip = Infinity;
      for (let a = e; a && a !== document.body; a = a.parentElement) { const o = getComputedStyle(a).overflowX; if (o !== 'visible') clip = Math.min(clip, a.getBoundingClientRect().right); }
      return { textR: t.right, boxR: box.right, clipR: clip, sw: e.scrollWidth, cw: e.clientWidth, cta: document.querySelector('.header-cta').getBoundingClientRect().left };
    });
    expect(r.sw, 'name text fits its own box').toBeLessThanOrEqual(r.cw);
    expect(r.textR, 'right edge of the text inside every clipping ancestor').toBeLessThanOrEqual(r.clipR + 0.5);
    expect(r.textR, 'name ends before the Book direct link').toBeLessThanOrEqual(r.cta);
  });
}

test('R4 wordmark: computed family starts with Pinyon Script, normal case, tap target kept, other "Cascade Hideaway" text unchanged', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/?theme-time=midday', { waitUntil: 'load' });
  const r = await page.evaluate(() => {
    const cs = getComputedStyle(document.querySelector('.site-header .logo-name'));
    const logo = document.querySelector('.site-header .site-logo').getBoundingClientRect();
    const foot = getComputedStyle(document.querySelector('.footer-brand .fb-name'));
    return { fam: cs.fontFamily, tt: cs.textTransform, ls: cs.letterSpacing, fs: parseFloat(cs.fontSize), logoH: logo.height, token: getComputedStyle(document.documentElement).getPropertyValue('--gs-wordmark-font').trim(), footFam: foot.fontFamily };
  });
  expect(r.fam.replace(/["']/g, '')).toMatch(/^Pinyon Script,/);
  expect(r.token.replace(/["']/g, '')).toBe('Pinyon Script, Snell Roundhand, Apple Chancery, Cormorant Garamond, serif'); /* engines differ on quote style */
  expect(r.tt).toBe('none');
  expect(r.ls).toBe('normal');
  expect(r.fs, 'wordmark is a peer of Book direct, not a headline').toBeGreaterThanOrEqual(24);
  expect(r.fs).toBeLessThanOrEqual(30);
  expect(r.logoH).toBeGreaterThanOrEqual(44);
  expect(r.footFam).not.toMatch(/Pinyon/);
});

/* the three hero lines and the wordmark keep AA on the photo: text hidden, composited pixels measured, MINIMUM contrast asserted (quote is large text: 3:1) */
for (const sz of SIZES) for (const time of ['midday', 'night']) {
  test(`R4 hero text contrast at ${sz.name} ${time}`, async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' }); /* no entrance or drift animation: the photo is still while it is measured */
    await page.setViewportSize({ width: sz.w, height: sz.h });
    await page.goto(`/?theme-time=${time}`, { waitUntil: 'load' });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() => { const imgs = [...document.querySelectorAll('#heroPhoto img')]; return imgs.length > 0 && imgs.every((i) => i.complete && i.naturalWidth > 0); });
    await page.evaluate(() => Promise.all([...document.querySelectorAll('#heroPhoto img')].map((i) => i.decode().catch(() => {}))));
    await page.waitForFunction(() => document.getAnimations().every((an) => an.playState !== 'running' || an.effect?.getComputedTiming().iterations === Infinity) && getComputedStyle(document.getElementById('heroPhoto')).opacity === '1'); /* the photo and the page reveals have finished */
    const info = await page.evaluate(() => {
      const o = {};
      for (const [k, s] of [['eyebrow', '.gs-eb--hero'], ['quote', '.hero-title'], ['attrib', '.gs-attrib'], ['wordmark', '.logo-name'], ['bookdirect', '.header-cta']]) {
        const e = document.querySelector(s), rg = document.createRange(); rg.selectNodeContents(e);
        o[k] = { rects: [...rg.getClientRects()].filter((r) => r.width > 2 && r.height > 2).map((r) => ({ x: r.left, y: r.top, w: r.width, h: r.height })), color: getComputedStyle(e).color.match(/\d+/g).map(Number) };
      }
      return o;
    });
    /* hide the glyphs (boxes keep their place, rects were read above); the scrim is a pseudo-element of the copy block, so hide only its text children */
    await page.evaluate(() => document.querySelectorAll('.luxury-hero-copy *, .logo-name, .header-cta').forEach((e) => { e.style.setProperty('visibility', 'hidden', 'important'); }));
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))); /* let the hidden glyphs paint out before the shot (the first shot after a style change can show the old frame) */
    const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
    const b64 = (await page.screenshot()).toString('base64'); /* one shot of the viewport, cropped in the page (WebKit is slow per clipped shot) */
    const res = await page.evaluate(async ({ data, info, w, h }) => {
      const im = new Image(); im.src = 'data:image/png;base64,' + data; await im.decode();
      const c = document.createElement('canvas'); c.width = im.width; c.height = im.height; const x = c.getContext('2d'); x.drawImage(im, 0, 0);
      const sc = im.width / innerWidth; const out = {};
      const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
      const lum = (r, g, b) => 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
      for (const [k, i] of Object.entries(info)) {
        const fl = lum(...i.color); let worst = Infinity;
        for (const r of i.rects) {
          const x0 = Math.max(0, Math.floor(r.x * sc)), y0 = Math.max(0, Math.floor(r.y * sc)), w0 = Math.max(1, Math.min(im.width - x0, Math.ceil(r.w * sc))), h0 = Math.max(1, Math.min(im.height - y0, Math.ceil(r.h * sc)));
          const d = x.getImageData(x0, y0, w0, h0).data;
          for (let j = 0; j < d.length; j += 4) { const l = lum(d[j], d[j + 1], d[j + 2]); worst = Math.min(worst, (Math.max(fl, l) + 0.05) / (Math.min(fl, l) + 0.05)); }
        }
        out[k] = worst;
      }
      return out;
    }, { data: b64, info, w: sz.w, h: sz.h });
    console.log(`CONTRAST ${sz.name} ${time} ` + JSON.stringify(Object.fromEntries(Object.entries(res).map(([k, v]) => [k, +v.toFixed(2)]))));
    for (const [k, worst] of Object.entries(res)) {
      expect(worst, `${k} contrast at ${sz.name} ${time}`).toBeGreaterThanOrEqual(k === 'quote' ? 3 : 4.5);
    }
  });
}
