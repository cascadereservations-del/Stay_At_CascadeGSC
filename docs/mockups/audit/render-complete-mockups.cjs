const { chromium } = require('../../../node_modules/playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const url = 'file:///C:/Users/Lloyd/Claude/Projects/Cascade/direct-booking-waves-0-1-sol/docs/mockups/cascade-experience-mockups.html';
  const page = await browser.newPage({ viewport: { width: 1440, height: 1050 }, deviceScaleFactor: 1 });
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.screenshot({ path: 'docs/mockups/cascade-command-center-complete-overview.png', fullPage: true });

  await page.getByRole('button', { name: 'Analytics' }).click();
  await page.screenshot({ path: 'docs/mockups/cascade-command-center-analytics.png', fullPage: true });
  await page.getByRole('button', { name: 'Bookings & stays' }).click();
  await page.screenshot({ path: 'docs/mockups/cascade-command-center-bookings.png', fullPage: true });
  await page.getByRole('button', { name: 'Guest relationships' }).click();
  await page.screenshot({ path: 'docs/mockups/cascade-command-center-guests.png', fullPage: true });

  await page.getByRole('button', { name: /Cleaner flow/ }).click();
  await page.screenshot({ path: 'docs/mockups/cascade-cleaner-checklist-briefing.png', fullPage: true });
  await page.getByRole('button', { name: /Begin evidence capture/ }).click();
  await page.screenshot({ path: 'docs/mockups/cascade-cleaner-checklist-evidence.png', fullPage: true });

  await page.getByRole('button', { name: /Direct booking/ }).click();
  await page.screenshot({ path: 'docs/mockups/cascade-direct-booking-landing.png', fullPage: true });
  await page.getByRole('button', { name: /Check availability/ }).click();
  await page.screenshot({ path: 'docs/mockups/cascade-direct-booking-journey.png', fullPage: true });

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  await mobile.goto(url, { waitUntil: 'networkidle' });
  await mobile.getByRole('button', { name: 'Analytics' }).click();
  await mobile.screenshot({ path: 'docs/mockups/cascade-command-center-analytics-mobile.png', fullPage: true });
  await mobile.getByRole('button', { name: /Direct booking/ }).click();
  await mobile.screenshot({ path: 'docs/mockups/cascade-direct-booking-mobile.png', fullPage: true });

  const diagnostics = await page.evaluate(() => ({
    title: document.title,
    blankButtonNames: Array.from(document.querySelectorAll('button')).filter((button) => !(button.getAttribute('aria-label') || button.textContent?.trim())).length,
    horizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
    placeholderScreen: document.body.textContent?.includes('Supporting screen'),
  }));
  const mobileDiagnostics = await mobile.evaluate(() => ({ horizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth }));
  console.log(JSON.stringify({ diagnostics, mobileDiagnostics }));
  await browser.close();
})();
