import { defineConfig, devices } from '@playwright/test';

const PORT = Number(process.env.PW_PORT) || 4173;   /* a second checkout or a parallel run sets its own port; a foreign server on 4173 serves another tree */

export default defineConfig({
  testDir: './tests',
  testMatch: '**/*.spec.mjs',
  timeout: 30000,
  fullyParallel: false,
  workers: 1,
  use: { baseURL: `http://127.0.0.1:${PORT}`, trace: 'retain-on-failure' },
  webServer: { command: `npx serve . -l ${PORT} --no-clipboard`, url: `http://127.0.0.1:${PORT}`, reuseExistingServer: true },
  projects: [
    { name: 'mobile', use: { ...devices['iPhone 13'] } },
    { name: 'desktop', use: { viewport: { width: 1280, height: 720 } } }
  ]
});
