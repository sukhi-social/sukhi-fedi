import { test, expect, type Page } from '@playwright/test';

// The join flow, driven in a real browser (Chromium + Firefox) with the
// backend mocked at the network edge via Playwright route interception.
// We never stand up the gateway/api stack — the point is to prove the
// *client* signup orchestration (the /signup form → /check → email code →
// account creation → /timeline) actually runs in each browser, which is
// where "everything was broken in Firefox" would bite.
//
// The real backend behaviour is covered by the gateway's Elixir tests
// (auth_flow_test / local_accounts_test); here we only mock the shapes the
// SPA expects, so the flow can complete deterministically.

const JSON_CT = 'application/json';

type AccountsResponse = { status: number; body: unknown };

const OK_TOKEN = {
  access_token: 'user-token',
  token_type: 'Bearer',
  scope: 'read write follow',
  created_at: 1_750_000_000
};

// Wire up every endpoint the join flow touches. `ensureJsonOrAnubis` in
// auth.ts rejects any response whose content-type isn't JSON (it reads it
// as an Anubis challenge), so every fulfil must be application/json.
async function mockJoinBackend(
  page: Page,
  accounts: AccountsResponse = { status: 200, body: OK_TOKEN }
) {
  const json = (body: unknown, status = 200) =>
    ({ status, contentType: JSON_CT, body: JSON.stringify(body) }) as const;

  // Catch-all for stray reads (the timeline the flow lands on, instance
  // info, …). Registered first so the specific routes below win.
  await page.route('**/api/v1/**', (route) => route.fulfill(json([])));

  await page.route('**/signup/email/request', (route) => route.fulfill(json({})));
  await page.route('**/signup/email/confirm', (route) =>
    route.fulfill(json({ email_proof: 'test-proof' }))
  );
  // Post-signup the SPA trades the proof for a first-party session cookie.
  await page.route('**/signup/session', (route) => route.fulfill(json({ ok: true })));
  await page.route('**/api/v1/apps', (route) =>
    route.fulfill(json({ client_id: 'test-client', client_secret: 'test-secret' }))
  );
  await page.route('**/oauth/token', (route) =>
    route.fulfill(json({ ...OK_TOKEN, access_token: 'app-token' }))
  );
  await page.route('**/api/v1/accounts', (route) =>
    route.fulfill(json(accounts.body, accounts.status))
  );
}

// An uncaught `pageerror` is the shape of "the app is broken in this
// browser". Missing-backend/resource noise is forgiven.
const CONSOLE_NOISE = /favicon|failed to load resource|net::err|err_|\b404\b|version\.json|\/api\//i;

// The one pageerror we forgive (Chromium words it "skipped" or "aborted
// because of invalid state", depending on timing): the browser's own CSS `@view-transition`
// (base.css) gets skipped when the join flow's hard navigation
// (window.location.assign → /check) is interrupted by the next one. The
// navigation still completes; this is a Chromium view-transition artifact,
// not app breakage, and there's no app-level promise to catch.
const PAGEERROR_NOISE = /Transition was (skipped|aborted because of invalid state)/i;

function watchForJsErrors(page: Page) {
  const pageErrors: string[] = [];
  const consoleErrors: string[] = [];
  page.on('pageerror', (err) => {
    if (!PAGEERROR_NOISE.test(err.message)) pageErrors.push(`${err.name}: ${err.message}`);
  });
  page.on('console', (msg) => {
    if (msg.type() === 'error' && !CONSOLE_NOISE.test(msg.text())) consoleErrors.push(msg.text());
  });
  return {
    assertClean() {
      expect(pageErrors, `uncaught JS errors:\n${pageErrors.join('\n')}`).toEqual([]);
      expect(consoleErrors, `console errors:\n${consoleErrors.join('\n')}`).toEqual([]);
    }
  };
}

// Fill the /signup form and submit — leaves the browser on /check.
async function fillSignupAndSubmit(page: Page) {
  await page.goto('/signup');
  await page.locator('input[type="email"]').fill('neko@example.com');
  await page.locator('input[autocomplete="username"]').fill('usagi_05');
  await page.locator('input[autocomplete="off"]').fill('test-invite-code');
  // The "create" button stays disabled until the terms checkbox is ticked.
  await page.locator('input[type="checkbox"]').check();
  await page.locator('form button[type="submit"]').click();
  await expect(page).toHaveURL(/\/check\?intent=signup/);
}

test.describe('cross-browser join flow', () => {
  test('signup runs end to end and lands logged-in on the timeline', async ({ page }) => {
    await mockJoinBackend(page);
    const errors = watchForJsErrors(page);

    await fillSignupAndSubmit(page);

    // /check sent the code (mocked) and is now asking for it.
    const codeInput = page.locator('input[autocomplete="one-time-code"]');
    await expect(codeInput).toBeVisible();
    await codeInput.fill('123456');
    // Submit via Enter rather than clicking the button: the confirm button
    // flips to disabled={busy} the instant the handler fires, and Chromium's
    // click actionability can wedge on that transition.
    await codeInput.press('Enter');

    // Code → proof → app token → account → token saved → /timeline.
    await expect(page).toHaveURL(/\/timeline$/);
    const token = await page.evaluate(() => localStorage.getItem('sf.token'));
    expect(token).toContain('user-token');

    errors.assertClean();
  });

  test('a dead invite at account creation surfaces an error, not a crash', async ({ page }) => {
    await mockJoinBackend(page, { status: 422, body: { error: 'invite_used' } });

    await fillSignupAndSubmit(page);

    const codeInput = page.locator('input[autocomplete="one-time-code"]');
    await expect(codeInput).toBeVisible();
    await codeInput.fill('123456');
    await codeInput.press('Enter');

    // The flow stops on /check and shows the error — it must not throw or
    // wander off to the timeline.
    await expect(page.locator('.error')).toBeVisible();
    await expect(page).toHaveURL(/\/check/);
  });
});
