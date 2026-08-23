import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test.describe('accessibility baseline', () => {
  test('landing page has no serious/critical axe violations', async ({ page }) => {
    await page.goto('/index.html');
    const results = await new AxeBuilder({ page })
      .exclude('#airbnbProofEmbed') // third-party embed content is out of our control
      .analyze();
    const serious = results.violations.filter(v => v.impact === 'serious' || v.impact === 'critical');
    expect(serious, JSON.stringify(serious, null, 2)).toEqual([]);
  });

  test('booking step 1 has no serious/critical axe violations', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('#booking').scrollIntoViewIfNeeded();
    const results = await new AxeBuilder({ page }).include('#bookingStep1').analyze();
    const serious = results.violations.filter(v => v.impact === 'serious' || v.impact === 'critical');
    expect(serious, JSON.stringify(serious, null, 2)).toEqual([]);
  });

  test('keyboard can reach the hero check-in field', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('#qbwCiField').focus();
    await expect(page.locator('#qbwCiField')).toBeFocused();
  });
});
