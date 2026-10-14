1. **Update API Types and updateCredentials:**
   - Add `bot?: boolean` to `CredentialsUpdate` type in `web/src/lib/api.ts`.
   - Update `updateCredentials` function in `web/src/lib/api.ts` to include the `bot` parameter in the `FormData`.

2. **Add Bot Switch to Settings Page:**
   - In `web/src/routes/settings/+page.svelte`, add a `let bot = $state(false);` variable.
   - Initialize `bot` from `me.bot` during load.
   - Add `bot` to the `updateCredentials` call in `save()`.
   - Add a UI checkbox for the `bot` switch, similar to the `locked`, `discoverable`, and `indexable` checkboxes.

3. **Add Bot Label to Localizations:**
   - In `web/src/lib/locales/ja.ts` and `web/src/lib/locales/ko.ts`, add the translation for the bot setting (`'settings.bot': 'BOTアカウントであることを明記する'` and `'settings.bot': '봇 계정임을 명시하기'`).

4. **Implement Bot Token Management API and UI:**
   - Add method `createBot(username: string, display_name: string)` using `POST /api/v1/sukhi/bots` endpoint and `rotateBotToken(id: string)` using `POST /api/v1/sukhi/bots/${id}/token` to `web/src/lib/api.ts`. Note: The API accepts `{"username": ..., "display_name": ...}`.
   - Both of these endpoints respond with `{ account, token }`. Add an interface `BotTokenResponse { account: Account; token: string }` in `web/src/lib/api.ts`.
   - Add a new route `web/src/routes/settings/bot/+page.svelte`. It should contain an input form for `username` and `display_name`, a submit button to create a bot account. When successfully created, it displays the token.
   - It should also have an input form for the bot `id` and a submit button to rotate token. Upon rotation, it displays the newly rotated token.
   - In `web/src/routes/settings/+page.svelte`, around line 384, add a link `<a class="chip" href="/settings/bot">{$t('settings.botManagement')}</a>` alongside the cleanup link.
   - Add the translation `'settings.botManagement': 'BOTアカウントの管理'` and `'settings.botManagement': '봇 계정 관리'` to `web/src/lib/locales/ja.ts` and `web/src/lib/locales/ko.ts` respectively.

5. **Verify Bot Implementation:**
   - Use `cat` command to read `web/src/routes/settings/bot/+page.svelte`, `web/src/routes/settings/+page.svelte`, and `web/src/lib/api.ts` to ensure modifications and file creations are correct.

6. **Run tests**
   - Run tests using `npm run check` in the `web` directory.
   - Run tests using `npm run test:e2e` in the `web` directory.

7. **Complete pre commit steps**
   - Complete pre-commit steps to ensure proper testing, verification, review, and reflection are done.

8. **Submit Changes:**
   - Submit the modifications with an appropriate commit message.
