const { chromium } = require('../../../node_modules/playwright');

const root = 'file:///C:/Users/Lloyd/Claude/Projects/Cascade/';

async function blockSideEffects(page) {
  await page.route('**/*', async (route) => {
    const url = route.request().url();
    if (url.includes('supabase.co') || url.includes('/functions/v1/') || url.includes('google-analytics.com')) {
      await route.abort();
      return;
    }
    await route.continue();
  });
}

(async () => {
  const browser = await chromium.launch({ headless: true });

  const booking = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  await blockSideEffects(booking);
  await booking.goto(`${root}direct-booking-waves-0-1-sol/index.html`, { waitUntil: 'domcontentloaded' });
  await booking.waitForTimeout(3000);
  await booking.screenshot({ path: 'docs/mockups/audit/current-direct-booking-desktop.png', fullPage: false });

  const bookingMobile = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  await blockSideEffects(bookingMobile);
  await bookingMobile.goto(`${root}direct-booking-waves-0-1-sol/index.html`, { waitUntil: 'domcontentloaded' });
  await bookingMobile.waitForTimeout(3000);
  await bookingMobile.screenshot({ path: 'docs/mockups/audit/current-direct-booking-mobile.png', fullPage: false });

  const cleaner = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  await blockSideEffects(cleaner);
  await cleaner.goto(`${root}cleaners-auth-sol/index.html`, { waitUntil: 'domcontentloaded' });
  await cleaner.waitForTimeout(1000);
  await cleaner.screenshot({ path: 'docs/mockups/audit/current-cleaner-auth.png', fullPage: false });
  await cleaner.evaluate(() => {
    document.querySelector('#auth-gate')?.setAttribute('hidden', '');
    document.querySelectorAll('.phase').forEach((phase) => phase.classList.remove('active'));
    document.querySelector('#phase-0')?.classList.add('active');
  });
  await cleaner.waitForTimeout(300);
  await cleaner.screenshot({ path: 'docs/mockups/audit/current-cleaner-setup.png', fullPage: false });

  console.log(JSON.stringify({
    bookingTitle: await booking.title(),
    bookingOverflow: await booking.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth),
    bookingMobileOverflow: await bookingMobile.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth),
    cleanerTitle: await cleaner.title(),
    cleanerOverflow: await cleaner.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth),
  }));
  await browser.close();
})();
