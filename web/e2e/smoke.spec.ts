import { test, expect, type Page } from '@playwright/test';

// What we never tolerate: a `pageerror` (an uncaught exception). That is
// exactly the shape of "the whole app was broken in Firefox" — a module
// that fails to evaluate, or a render that throws, wedges the SPA.
//
// What we forgive: resource loads that fail because there's no backend
// behind `vite preview` (no /api, no gateway-served pages), plus favicons
// and the version poll. Those are environment noise, not app breakage.
const CONSOLE_NOISE = /favicon|failed to load resource|net::err|err_|\b404\b|version\.json|\/api\//i;

function watchForJsErrors(page: Page) {
  const pageErrors: string[] = [];
  const consoleErrors: string[] = [];

  page.on('pageerror', (err) => pageErrors.push(`${err.name}: ${err.message}`));
  page.on('console', (msg) => {
    if (msg.type() === 'error' && !CONSOLE_NOISE.test(msg.text())) {
      consoleErrors.push(msg.text());
    }
  });

  return {
    assertClean() {
      expect(pageErrors, `uncaught JS errors:\n${pageErrors.join('\n')}`).toEqual([]);
      expect(consoleErrors, `console errors:\n${consoleErrors.join('\n')}`).toEqual([]);
    }
  };
}

test.describe('cross-browser smoke — the SPA boots and runs', () => {
  test('landing mounts and offers both doors', async ({ page }) => {
    const errors = watchForJsErrors(page);

    await page.goto('/');

    // The hero heading rendering at all means Svelte mounted and ran.
    await expect(page.locator('.hero h1')).toBeVisible();
    await expect(page.locator('a[href="/signup"]').first()).toBeVisible();
    await expect(page.locator('a[href="/login"]').first()).toBeVisible();

    errors.assertClean();
  });

  test('signup form renders and its inputs bind', async ({ page }) => {
    const errors = watchForJsErrors(page);

    await page.goto('/');
    await page.locator('a[href="/signup"]').first().click();
    await expect(page).toHaveURL(/\/signup$/);

    // Typing into the inputs and seeing the value reflect back exercises
    // Svelte 5 runes reactivity — the part most likely to silently break
    // on a browser the build doesn't support.
    const email = page.locator('input[type="email"]');
    await expect(email).toBeVisible();
    await email.fill('neko@example.com');
    await expect(email).toHaveValue('neko@example.com');

    const handle = page.locator('input[autocomplete="username"]');
    await handle.fill('usagi_05');
    await expect(handle).toHaveValue('usagi_05');

    errors.assertClean();
  });

  test('railway map draws its tracks even with no backend', async ({ page }) => {
    const errors = watchForJsErrors(page);

    await page.goto('/');
    await page.locator('a[href="/map"]').first().click();
    await expect(page).toHaveURL(/\/map$/);

    // The SVG map is static — it must render even when /api/map is
    // unreachable (the board then says it couldn't fetch the numbers).
    // (Playwright reports stroke-only <path> elements as hidden, so we
    // assert on the map itself and the departure board instead.)
    await expect(page.getByRole('img')).toBeVisible();
    await expect(page.locator('.board-list li')).toHaveCount(4);

    errors.assertClean();
  });

  test('login method switch toggles the inputs (client reactivity)', async ({ page }) => {
    const errors = watchForJsErrors(page);

    await page.goto('/');
    await page.locator('a[href="/login"]').first().click();
    await expect(page).toHaveURL(/\/login$/);

    // Email is the default method — its input is shown.
    await expect(page.locator('input[type="email"]')).toBeVisible();

    // Switching to the password method (the second tab) must reveal the
    // password input — a reactive branch flip.
    await page.getByRole('tab').nth(1).click();
    await expect(page.locator('input[type="password"]')).toBeVisible();

    errors.assertClean();
  });
});
