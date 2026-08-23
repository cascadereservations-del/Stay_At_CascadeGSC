import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  use: { baseURL: 'http://127.0.0.1:4173', trace: 'retain-on-failure' },
  webServer: { command: 'npm run serve', url: 'http://127.0.0.1:4173', reuseExistingServer: true },
  projects: [
    { name: 'mobile', use: { ...devices['iPhone 13'] } },
    { name: 'desktop', use: { viewport: { width: 1280, height: 720 } } }
  ]
});
