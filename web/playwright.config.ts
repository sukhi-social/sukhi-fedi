import { defineConfig, devices } from '@playwright/test';

// Cross-browser smoke flow (Chromium + Firefox).
//
// We serve the *built* SPA with `vite preview` (adapter-static →
// index.html fallback) and no backend. The point isn't to test
// API-backed features — it's to prove the app actually boots and runs in
// each browser, the net for "everything was broken in Firefox". A single
// uncaught exception that wedges the SPA shows up the same in every page
// of the flow, so a small flow over the unauthenticated routes is enough.
//
// Authenticated, API-backed E2E would need the full gateway stack and is
// deliberately out of scope here.
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['html', { open: 'never' }], ['list']] : 'list',
  use: {
    baseURL: 'http://localhost:4173',
    trace: 'on-first-retry'
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } }
  ],
  webServer: {
    command: 'pnpm run build && pnpm run preview -- --port 4173 --strictPort',
    url: 'http://localhost:4173',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000
  }
});
