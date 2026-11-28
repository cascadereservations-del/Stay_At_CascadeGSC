import { test, expect } from '@playwright/test';

/* Booking-site audit 2026-11-28: QR weight, greeting, the bar stepping aside, chat inside the bar.
   Every Supabase endpoint is stubbed: a test must never reach production or write a booking. */
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const plus = (n) => { const d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() + n); return iso(d); };
const CI = plus(30), CO = plus(32);

async function stub(page) {
  const json = (body) => (route) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  await page.route('**/*.supabase.co/**', json([]));
  await page.route('**/functions/v1/availability**', json([]));
  await page.route('**/functions/v1/rate-card**', json({ card: { base: 1780, deposit_pct: 50, tiers: [{ min_nights: 2, pct: 5 }], promotions: [] }, quote: { n: 2, total: 3382, deposit: 1691, last_minute: false } }));
  await page.route('**/functions/v1/submit-booking', json({ ok: true, ref: 'CH-TEST1', hold: true, hold_expires_at: new Date(Date.now() + 86400000).toISOString(), receipt_upload_token: 'hold-token-1' }));
}
const qrLog = (page) => { const log = []; page.on('request', (r) => { if (/\/qr-[a-z]+\.png/.test(r.url())) log.push(r.url().split('/').pop()); }); return log; };
const BOTH = ['qr-gcash.png', 'qr-unionbank.png'];
/* open the sheet on the test dates and fill the details; `pay` = go on to the payment step */
async function toPayStep(page, pay = true) {
  await page.evaluate(([ci, co]) => window.CascadeSheet.open({ ci, co }), [CI, CO]);
  await expect(page.locator('#bsTotal')).toContainText('₱');
  await page.locator('#bsNext1').click();
  await expect(page.locator('#bsH2')).toBeVisible();
  await page.locator('#bsName').fill('Maria Santos'); await page.locator('#bsPhone').fill('917 123 4567');
  if (!pay) return;
  await page.locator('#bsNext2').click();
  await expect(page.locator('#bsS3')).toBeVisible();
}
/* the QR files drop until `up` is set */
async function qrNetwork(page) {
  const net = { up: false, asked: 0, failed: [] };
  await page.route('**/assets/images/qr-*.png', (route) => { net.asked++; return net.up ? route.continue() : route.abort(); });
  page.on('requestfailed', (r) => { if (/\/qr-[a-z]+\.png/.test(r.url())) net.failed.push(r.url()); });
  return net;
}
const decoded = (page) => page.locator('#bsQr').evaluate((i) => (i.complete ? i.naturalWidth : 0));
async function expectQr(page, file, alt) {
  await expect(page.locator('#bsQr')).toBeVisible();
  await expect(page.locator('#bsQr')).toHaveAttribute('src', `assets/images/${file}`);
  await expect(page.locator('#bsQr')).toHaveAttribute('alt', alt);
  await expect.poll(() => decoded(page)).toBeGreaterThan(0);
}
/* put `selector` at `at` px from the top of the viewport, with no smooth scrolling */
const park = (page, selector, at) => page.evaluate(([s, y]) => scrollBy({ top: document.querySelector(s).getBoundingClientRect().top - y, behavior: 'instant' }), [selector, at]);
/* a place with neither Reserve button on screen and the hero gone */
const between = (page) => park(page, '#hospitality', 0);
const bar = (page) => page.locator('#stickyBookCta');
async function expectBarHidden(page) {
  await expect(bar(page)).toHaveAttribute('aria-hidden', 'true');
  await expect(bar(page)).toHaveCSS('visibility', 'hidden');
  await expect(bar(page)).toHaveCSS('pointer-events', 'none');
  const focused = await page.evaluate(() => { const b = document.getElementById('stickyBookCtaBtn'); b.focus({ preventScroll: true }); return document.activeElement === b; });
  expect(focused, 'a hidden bar takes no focus').toBe(false);
}
async function expectBarShown(page) {
  await expect(bar(page)).toHaveAttribute('aria-hidden', 'false');
  await expect(bar(page)).toHaveCSS('visibility', 'visible');
  await expect(bar(page)).toHaveCSS('opacity', '1');
}

test.describe('audit: payment QR weight', () => {
  test('no QR is requested until the sheet opens, then GCash and UnionBank both decode, also after a restore', async ({ page }) => {
    await stub(page);
    const log = qrLog(page);
    await page.goto('/index.html', { waitUntil: 'networkidle' });
    await page.evaluate(async () => { for (let y = 0; y < document.body.scrollHeight; y += 600) { scrollTo({ top: y, behavior: 'instant' }); await new Promise((r) => setTimeout(r, 30)); } scrollTo({ top: 0, behavior: 'instant' }); });
    await page.waitForLoadState('networkidle');
    expect(log, 'fresh load').toEqual([]);

    await page.evaluate(([ci, co]) => window.CascadeSheet.open({ ci, co }), [CI, CO]);
    await expect(page.locator('#bsTotal')).toContainText('₱');
    await page.locator('#bsNext1').click();
    await expect(page.locator('#bsH2')).toBeVisible();
    await expect.poll(() => [...new Set(log)].sort(), 'both preloaded before the payment step').toEqual(BOTH);
    await page.locator('#bsName').fill('Maria Santos'); await page.locator('#bsPhone').fill('917 123 4567');
    await page.locator('#bsNext2').click();
    await expectQr(page, 'qr-gcash.png', /^GCash QR code for \S/);
    await page.locator('#bsB').click();
    await expectQr(page, 'qr-unionbank.png', 'UnionBank InstaPay QR code');

    await page.reload();                         /* restored from sessionStorage cascade.sheet.v1, bank still chosen */
    await expect(page.locator('#bsH3')).toBeVisible();
    await expectQr(page, 'qr-unionbank.png', 'UnionBank InstaPay QR code');
    await page.locator('#bsG').click();
    await expectQr(page, 'qr-gcash.png', /^GCash QR code for \S/);
  });

  test('a slow UnionBank file was fetched when the sheet opened, so it is already decoded at the toggle', async ({ page }) => {
    await stub(page);
    await page.route('**/assets/images/qr-unionbank.png', async (route) => { await new Promise((r) => setTimeout(r, 4000)); await route.continue(); });
    await page.goto('/index.html');
    const arrived = page.waitForEvent('requestfinished', { predicate: (r) => r.url().endsWith('qr-unionbank.png'), timeout: 12000 });
    await toPayStep(page);
    await arrived;
    await expectQr(page, 'qr-gcash.png', /^GCash QR code for \S/);
    await page.locator('#bsB').click();
    expect(await decoded(page), 'decoded with no further waiting').toBeGreaterThan(0);
    await expect(page.locator('#bsQr')).toHaveAttribute('src', 'assets/images/qr-unionbank.png');
  });

  test('while UnionBank is still on its way, the UnionBank label never sits over the GCash code', async ({ page }) => {
    await stub(page);
    let release; const held = new Promise((r) => { release = r; });
    await page.route('**/assets/images/qr-unionbank.png', async (route) => { await held; await route.continue(); });
    await page.goto('/index.html');
    await toPayStep(page);
    await expectQr(page, 'qr-gcash.png', /^GCash QR code for \S/);
    await page.locator('#bsB').click();
    await expect(page.locator('#bsQr')).toHaveAttribute('alt', 'UnionBank InstaPay QR code');
    expect(await page.locator('#bsQr').getAttribute('src')).toBeNull();
    expect(await decoded(page)).toBe(0);
    release();
    await expectQr(page, 'qr-unionbank.png', 'UnionBank InstaPay QR code');
  });

  test('the first QR requests drop: the retry fills both once the network is back, with no tap needed', async ({ page }) => {
    await stub(page);
    const net = await qrNetwork(page);
    await page.goto('/index.html');
    await toPayStep(page);
    await expect.poll(() => net.failed.length).toBeGreaterThanOrEqual(2);
    expect(await decoded(page)).toBe(0);
    net.up = true;
    await expect(page.locator('#bsQr'), 'the longest wait between retries is 8 s').toHaveAttribute('src', /qr-gcash/, { timeout: 15000 });
    await expectQr(page, 'qr-gcash.png', /^GCash QR code for \S/);
    await page.locator('#bsB').click();
    await expectQr(page, 'qr-unionbank.png', 'UnionBank InstaPay QR code');
  });

  for (const recover of ['online event', 'method toggle']) {
    test(`retries stop after three; the ${recover} fetches both again`, async ({ page }) => {
      await stub(page);
      const net = await qrNetwork(page);
      await page.clock.install();
      await page.goto('/index.html');
      await toPayStep(page, false);
      /* 1 try + 3 retries for each of the 2 files; the clock is fast-forwarded past each wait */
      await expect.poll(async () => { await page.clock.runFor(8100); return net.failed.length; }, { timeout: 15000 }).toBe(8);
      await page.clock.runFor(60000);
      await page.waitForLoadState('networkidle');
      expect(net.asked, 'bounded').toBe(8);
      await page.locator('#bsNext2').click();
      await expect(page.locator('#bsS3')).toBeVisible();
      await expect.poll(async () => { await page.clock.runFor(8100); return net.failed.length; }, { message: 'painting the payment step starts one more bounded round', timeout: 15000 }).toBe(16);
      await page.clock.runFor(60000);
      await page.waitForLoadState('networkidle');
      expect(net.asked, 'bounded again').toBe(16);
      expect(await decoded(page)).toBe(0);
      net.up = true;
      if (recover === 'online event') await page.evaluate(() => dispatchEvent(new Event('online')));
      else await page.locator('#bsG').click();
      await expectQr(page, 'qr-gcash.png', /^GCash QR code for \S/);
      await page.locator('#bsB').click();
      await expectQr(page, 'qr-unionbank.png', 'UnionBank InstaPay QR code');
    });
  }
});

test.describe('audit: greeting', () => {
  for (const [time, words, tod] of [['10:00', 'Good morning', 'midday'], ['11:59', 'Good morning', 'midday'], ['12:00', 'Good afternoon', 'midday'], ['15:59', 'Good afternoon', 'midday'], ['09:59', 'Good morning', 'morning']]) {
    test(`${time} says ${words} and keeps the ${tod} look`, async ({ page }) => {
      await stub(page);
      await page.clock.setFixedTime(new Date(`2026-11-28T${time}:00`));
      await page.goto('/index.html');
      await expect(page.locator('#gsGreet')).toHaveText(new RegExp(`^${words} from GenSan`));
      await expect(page.locator('html')).toHaveAttribute('data-tod', tod);
      await expect(page.locator('html')).toHaveAttribute('data-theme', 'sand');
    });
  }
});

test.describe('audit: the booking bar steps aside', () => {
  for (const size of [{ width: 390, height: 844 }, { width: 1280, height: 720 }]) {
    test(`${size.width}: hidden beside each booking card, shown between them`, async ({ page }) => {
      await stub(page);
      await page.setViewportSize(size);
      await page.goto('/index.html');
      await expectBarHidden(page);                                   /* cover */
      /* the hero card's button near the top edge: the hero itself is mostly gone, so the button is what hides the bar */
      await park(page, '#qbwSubmit', 8);
      await expect(page.locator('body')).not.toHaveClass(/gs-hero-in/);
      await expect(page.locator('#qbwSubmit')).toBeInViewport();
      await expectBarHidden(page);
      await between(page);
      await expectBarShown(page);
      await park(page, '#book-direct .iv-primary', size.height / 2);  /* pricing card */
      await expect(page.locator('#book-direct .iv-primary')).toBeInViewport();
      await expectBarHidden(page);
      await between(page);
      await expectBarShown(page);
    });
  }
});

/* geometry of the docked bar, read from the rendered page */
const dock = (page) => page.evaluate(() => {
  const box = (e) => { const r = e.getBoundingClientRect(); return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, h: r.height }; };
  const t = document.getElementById('conciergeTrigger'), c = document.getElementById('stickyBookCta'), btn = document.getElementById('stickyBookCtaBtn');
  const text = [];
  const walk = document.createTreeWalker(c.querySelector('.sticky-book-cta-rate'), NodeFilter.SHOW_TEXT);
  for (let n; (n = walk.nextNode());) { if (!n.textContent.trim() || n.parentElement.closest('[hidden]')) continue; const range = document.createRange(); range.selectNodeContents(n); for (const r of range.getClientRects()) text.push({ r: r.right }); }
  const hits = (el) => { const r = el.getBoundingClientRect(); return [[0.5, 0.5], [0.5, 0.1], [0.5, 0.9], [0.1, 0.5], [0.9, 0.5]].every(([x, y]) => { const h = document.elementFromPoint(r.left + r.width * x, r.top + r.height * y); return !!h && (h === el || el.contains(h)); }); };
  const cs = getComputedStyle(t);
  return { t: box(t), bar: box(c), btn: box(btn), textRight: Math.max(...text.map((x) => x.r)), triggerHit: hits(t), btnHit: hits(btn),
    icons: [...t.querySelectorAll('svg')].filter((s) => getComputedStyle(s).display !== 'none').map((s) => `${s.getAttribute('class')} ${s.clientWidth || s.getBoundingClientRect().width}`),
    shadow: cs.boxShadow, border: cs.borderTopWidth, over: document.documentElement.scrollWidth - document.documentElement.clientWidth };
});

test.describe('audit: chat inside the booking bar', () => {
  for (const width of [320, 375, 390, 768, 1023]) {
    for (const dates of [false, true]) {
      test(`${width}${dates ? ' with dates' : ''}: seated left of Reserve, clear of the text, and it opens and closes`, async ({ page, browserName }) => {
        await stub(page);
        await page.setViewportSize({ width, height: 700 });
        /* the longest summary: a stay across two months */
        if (dates) await page.addInitScript(() => sessionStorage.setItem('cascade.sheet.v1', JSON.stringify({ step: 1, open: false, ci: '2099-09-28', co: '2099-10-12' })));
        await page.goto('/index.html');
        await between(page);
        await expectBarShown(page);
        await expect(page.locator('#stickyBookCtaBtn')).toHaveText(dates ? 'See my total' : 'Reserve');
        await expect(page.locator('#conciergeFloat')).toHaveCSS('opacity', '1');
        await expect.poll(async () => { const d = await dock(page); return d.triggerHit && d.btnHit; }).toBe(true);
        const d = await dock(page);
        expect([Math.round(d.t.w), Math.round(d.t.h)]).toEqual([44, 44]);
        expect(d.icons).toEqual(['icon-chat 20']);
        expect(d.shadow).toBe('none'); expect(d.border).toBe('1px'); expect(d.over).toBeLessThanOrEqual(1);
        expect(d.t.t).toBeGreaterThanOrEqual(d.bar.t); expect(d.t.b).toBeLessThanOrEqual(d.bar.b);
        expect(Math.abs((d.t.t + d.t.b) / 2 - (d.bar.t + d.bar.b) / 2)).toBeLessThanOrEqual(1.5);
        expect(d.btn.l - d.t.r, 'gap to Reserve').toBeGreaterThanOrEqual(6);
        expect(d.btn.l - d.t.r).toBeLessThanOrEqual(10);
        expect(d.t.l - d.textRight, 'gap to the bar text').toBeGreaterThanOrEqual(2);
        expect(d.bar.h, 'the bar stays a bar').toBeLessThanOrEqual(90);

        const trigger = page.locator('#conciergeTrigger'), panel = page.locator('#conciergePanel');
        await trigger.click();
        await expect(trigger).toHaveAttribute('aria-expanded', 'true');
        await expect(panel).toHaveCSS('opacity', '1');
        await expect.poll(() => panel.evaluate((p) => new DOMMatrix(getComputedStyle(p).transform).a)).toBe(1);
        const p = await panel.boundingBox(), open = await dock(page);
        expect(p.x).toBeGreaterThanOrEqual(0); expect(p.y).toBeGreaterThanOrEqual(0);
        expect(p.x + p.width).toBeLessThanOrEqual(width);
        expect(p.y + p.height, 'panel ends above the bar').toBeLessThanOrEqual(open.bar.t);
        expect(open.icons).toEqual(['icon-close 20']);
        await trigger.click();
        await expect(trigger).toHaveAttribute('aria-expanded', 'false');
        await expect(panel).toBeHidden();

        /* Tab order follows the docked layout: chat, then Reserve */
        expect(await page.evaluate(() => Boolean(document.getElementById('conciergeTrigger').compareDocumentPosition(document.getElementById('stickyBookCtaBtn')) & Node.DOCUMENT_POSITION_FOLLOWING))).toBe(true);
        if (browserName === 'webkit') return;   /* WebKit on Windows never tabs to a link, so the keys are driven in Chromium */
        await trigger.focus();
        await page.keyboard.press('Tab');
        await expect(page.locator('#stickyBookCtaBtn')).toBeFocused();
        await page.keyboard.press('Shift+Tab');
        await expect(trigger).toBeFocused();
      });
    }
  }

  test('390: when the bar steps aside the chat goes back to its own auto-hide', async ({ page }) => {
    await stub(page);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/index.html');
    await between(page);
    await expect(page.locator('body')).toHaveClass(/gs-dock-chat/);
    await park(page, '#book-direct .iv-primary', 400);
    await expectBarHidden(page);
    await expect(page.locator('body')).not.toHaveClass(/gs-dock-chat/);
    await expect(page.locator('#conciergeFloat')).toHaveClass(/is-hidden/);
    await expect(page.locator('#conciergeFloat')).toHaveCSS('visibility', 'hidden');
    await between(page);
    await expect(page.locator('body')).toHaveClass(/gs-dock-chat/);
    await expect(page.locator('#conciergeFloat')).toHaveCSS('visibility', 'visible');
  });

  for (const width of [1024, 1280]) {
    test(`${width}: the chat keeps its corner and does not touch the bar`, async ({ page }) => {
      await stub(page);
      await page.setViewportSize({ width, height: 720 });
      await page.goto('/index.html');
      await between(page);
      await expectBarShown(page);
      await expect(page.locator('body')).not.toHaveClass(/gs-dock-chat/);
      await expect(page.locator('#conciergeFloat')).toHaveCSS('opacity', '1');
      await expect.poll(async () => (await dock(page)).triggerHit).toBe(true);
      const d = await dock(page);
      expect(d.t.l - d.bar.r).toBeGreaterThanOrEqual(8);
      expect(d.t.w).toBeGreaterThan(50);
    });
  }
});
