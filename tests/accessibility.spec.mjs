import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test.describe('accessibility baseline', () => {
  test('landing page has no serious/critical axe violations', async ({ page }) => {
    /* Reduced motion puts every .ch-reveal element in its final, fully opaque state (index.html reduced-motion block).
       Without it axe could sample a heading mid-fade: CI b8369a1 read #gs-bd-h at 1.01:1 during its opacity transition. */
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.goto('/index.html');
    const results = await new AxeBuilder({ page })
      .exclude('#airbnbProofEmbed') // third-party embed content is out of our control
      .analyze();
    const serious = results.violations.filter(v => v.impact === 'serious' || v.impact === 'critical');
    expect(serious, JSON.stringify(serious, null, 2)).toEqual([]);
  });

  test('booking sheet step 1 has no serious/critical axe violations', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('a.header-cta[data-gs-book]').click();
    await expect(page.locator('#bookSheet')).toHaveAttribute('open', '');
    const results = await new AxeBuilder({ page }).include('#bookSheet').analyze();
    const serious = results.violations.filter(v => v.impact === 'serious' || v.impact === 'critical');
    expect(serious, JSON.stringify(serious, null, 2)).toEqual([]);
  });

  test('keyboard can reach the hero check-in field', async ({ page }) => {
    await page.goto('/index.html');
    await page.locator('#qbwCiField').focus();
    await expect(page.locator('#qbwCiField')).toBeFocused();
  });
});
