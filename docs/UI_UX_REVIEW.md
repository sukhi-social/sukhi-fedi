# UI/UX review — `web/` (SvelteKit SPA)

> A review of the web client's design system and its rendered screens,
> with the changes it led to. The design intent it works from is in
> `web/src/styles/tokens.css` ("ink on warm paper, colour is functional").
> This document checks the code and the screens against that intent and
> against WCAG 2.2 / platform touch-target guidance.

## Method

- **Read** the tokens, base and app stylesheets, the nav, the status row
  (`StatusActions.svelte`), the language switch and the landing page.
- **Rendered** the mocked screens (`web/shots` harness, fixed clock) at
  1280 px and 390 px, before and after, in Chrome.
- **Measured** the contrast of every token pair in the palette.
- **Not done:** user testing, or a live comparison with other clients.
  The findings rest on the code, the rendered screens and the guidelines.

## Findings

| # | Problem | Evidence | Status |
|---|---|---|---|
| 1 | **Pressed chips became illegible.** The favourited star and the active language both showed light text on a light grey fill. | `.chip[aria-pressed]` sets light text; `.active` overrode only the fill. Measured ≈1.3:1. | Fixed |
| 2 | **Colour emoji as UI chrome** (⭐ 🔁 ＋ ⋯ 🏷 🔖 📌 🗑 🚩). This broke the rule that colour is functional and clashed with the monochrome nav icons. | Visible in the action row of every status. | Fixed in the status row |
| 3 | **Unbookmarked state used a price tag (🏷).** Its meaning was unclear. | Icon choice in `StatusActions`. | Fixed (outline / filled bookmark) |
| 4 | **Pressed state was tint only.** Pale grey is not enough on its own (WCAG 1.4.1). | Only `fill-active` marked a pressed chip. | Fixed: filled icon, bold label, stronger edge |
| 5 | **Control edges failed 3:1.** Chips, buttons, inputs and the composer capsule had a 1.8:1 edge. | `--color-border-strong` on `--color-bg`. | Fixed: new `--color-control` (3.3:1 on both paper tones) |
| 6 | **Focus was inconsistent.** Inputs removed their outline; other controls had no unified ring. | `input:focus { outline: none }`; no global `:focus-visible`. | Fixed: one ring for all (`:focus-visible`, 2 px ink) |
| 7 | **Small touch targets on phones.** The action chips were 28.6 px tall. | Measured in a touch emulation at 390 px. | Fixed: 44 px on coarse pointers |
| 8 | **Icon-only controls had weak names.** The "＋" react button had no label; the favourite count was not announced with its label. | Markup in `StatusActions`. | Fixed (`reaction.pick`; visually-hidden label) |
| 9 | **Build lane text was 4.3:1.** Used for small text on the landing doors. | `--color-build` on `--color-bg`. | Fixed: deepened to 5.1:1, same hue |
| 10 | **Landing duplicated the lane door markup** by hand, so the two doors could drift. | `+page.svelte` inline `<a class="lane-door">`. | Fixed: uses `LaneDoor` |

Contrast after the change (text on paper): ink 13.2:1, muted 4.75:1,
lane use 5.2:1, lane build 5.1:1, danger 5.8:1; control edge 3.3:1.

## Kept on purpose

- **Hairline borders on the status row.** The row is deliberately quiet
  (`StatusActions`: "余計な線を消し"). Each control is still identified by
  its icon, which is ink on paper, so the faint edge is not the only cue.
- **🔁 and similar in the post body.** Colour is allowed in content, not
  in chrome.
- **Reaction emoji.** These are user content and render as Twemoji.

## Next, in order of value

1. **Status metadata markers** still use colour emoji: boosted-by 🔁,
   reply-to ↩️, external ↗️ (`Status.svelte`), and the pinned label 📌 on
   the profile. They are chrome. Move them to `NavIcon`, at small size.
2. **Composer and DM menus** still use 😃 📌 📋 (`Composer.svelte`,
   `DmMessage.svelte`). Same treatment.
3. **Notification glyph.** The ambient "○ / w / Λ / 木" glyph carries
   meaning that nothing explains. Decide whether to keep a count-based
   signal with a text equivalent, and check it with screen readers.
4. **Two tab implementations.** `.tabs` and the profile's `.tab` drift
   apart (`@[acct]/+page.svelte`). Fold them into one.
5. **Lane colour as the only distinction.** The doors carry text labels,
   so this is fine today. Keep it that way for any new lane-coded UI.

## Files changed

- `web/src/styles/tokens.css`: `--color-control`, `--color-focus`,
  deeper `--color-build`.
- `web/src/styles/base.css`: global `:focus-visible` ring.
- `web/src/styles/app.css`: control edges use `--color-control`; input
  focus keeps only the border change; 44 px chip height on coarse pointers.
- `web/src/lib/components/NavIcon.svelte`: action icons (plus, repeat,
  quote, reply, more, pin, trash, flag) and a `filled` prop.
- `web/src/lib/components/StatusActions.svelte`: monochrome icons, labels,
  filled pressed state, pressed-chip contrast fix.
- `web/src/lib/components/LangSwitch.svelte`: dropped the conflicting
  `.active` override; pressed state comes from `aria-pressed`.
- `web/src/routes/+page.svelte`: landing uses `LaneDoor` for both doors.

Verification: `svelte-check` reports 0 errors (one pre-existing warning
in `FollowButton.svelte`, not touched); production build passes; the
`node --test` unit suites pass; a Tab press shows the focus ring with the
accessible name "お気に入り 4" on the favourite button.
