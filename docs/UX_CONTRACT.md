# UX contract — `web/`

What the web client promises about *behaviour*, per platform. The visual
side (colour, shape, density) is `tokens.css` and `UI_UX_REVIEW.md`; this
page is the other half: what a press, a key, a back gesture does.

Two rules:

1. **Break nothing the browser and the OS already do.** Links are links,
   buttons are buttons, history works, selection and translation work.
   Most of "matching the platform" is not reimplementing it.
2. **Change only what is known to differ by platform**, and only where a
   primary source says so. Where we have no source, we do not claim a
   contract (⚠ below).

The code is one place, as `CODE_STYLE.md` §0 asks: `web/src/lib/ux/`.
Every component routes through it; none re-types a number or a key.

| File | Does |
|---|---|
| `ux/platform.ts` | A coarse hint (mac / windows / android / ios / other) → `<html data-platform>`. Also: which modifier is primary, the `aria-keyshortcuts` spelling. User-overridable (`localStorage` `sf.platform`). |
| `ux/escape.ts` | One Esc listener, one stack. Only the top-most transient UI closes. |
| `ux/dismiss.ts` | `{@attach dismissable(…)}` — a small menu closes on outside click and Esc. |
| `ux/overlay.svelte.ts` | `useOverlay(isOpen, close)` — a modal closes on Esc **and on Back**, and takes its history entry with it. |
| `tokens.css` `--tap-min` | The press-size default (44px; 48px on Android). |

## The contract

Marks: ✓ read in a primary source · ⚠ not confirmed · ✗ was wrong earlier, corrected.

### A. Press size

| Source | Says | |
|---|---|---|
| [WCAG 2.2 SC 2.5.8](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html) (AA) | 24×24 CSS px; exceptions for spacing, an equivalent control, links in a sentence, user-agent defaults, essential presentation | ✓ floor |
| Apple HIG, Accessibility | iOS/iPadOS default 44×44 pt, **minimum 28×28**; macOS 28/20; visionOS 60/28 | ✓ (✗ "44 is Apple's minimum") |
| [Google accessibility help](https://support.google.com/accessibility/android/answer/7101858) | 48×48 dp, 8 dp between targets | ✓ |
| [Microsoft, Targeting](https://learn.microsoft.com/en-us/windows/apps/design/input/guidelines-for-targeting) | about 7.5 mm square (40×40 px at 135 PPI, 1.0×) | ✓ |

→ `--tap-min` is 44px, 48px on Android. On a coarse pointer, `.chip`,
`.btn`, `.nav-link`, `.follow-btn`, `.reaction-chip`, `.account-row-link`,
tabs and text fields do not go below it (`app.css`). Mouse screens keep
their compact heights.

### B. Back and Esc

| | Says | |
|---|---|---|
| Android | The system back gesture goes through the back stack; keep touch targets out from under the gesture inset | ✓ [Predictive back](https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back) |
| Windows | Esc cancels **transient** UI (dialog, dropdown). It does not close or navigate back through app UI | ✓ [Keyboard interactions](https://learn.microsoft.com/en-us/windows/apps/design/input/keyboard-interactions) |
| iOS | Provide a visible Back button; an edge swipe is a shortcut, never the only way; do not define gestures that collide with system ones | ✓ Apple HIG, Gestures (✗ "the edge swipe is defined by HIG") |

→ Esc closes the top transient UI only (`escape.ts`). A modal adds one
shallow history entry when it opens (same URL, `page.state.ux`), so the
Android back gesture closes the modal instead of leaving the timeline; on
a normal close it takes the entry back. No custom edge gestures anywhere.

### C. Keyboard

| | Says | |
|---|---|---|
| macOS | ⌘ is the primary modifier; do not repurpose the standard ⌘ shortcuts; avoid Control as a modifier (the system uses it) | ✓ Apple HIG, Keyboards |
| Windows | Accelerators are Ctrl+letter; Alt+letter are access keys; initial focus must not be on a destructive control | ✓ [Keyboard interactions](https://learn.microsoft.com/en-us/windows/apps/design/input/keyboard-interactions) |

→ ⌘+Enter (Apple) / Ctrl+Enter (others) posts, in the composer and in DMs,
on screens where plain Enter is a newline too. The send button carries
`aria-keyshortcuts`. The wrong modifier does nothing.

### D. Detecting the platform

`navigator.userAgentData.platform` is experimental and not Baseline
([MDN](https://developer.mozilla.org/en-US/docs/Web/API/NavigatorUAData/platform));
it is the same low-entropy hint as `Sec-CH-UA-Platform`. So: a fallback to
the user-agent string, iPadOS-in-desktop-mode counted as iOS (touch points
> 1), nothing sent off the device, and a user override.

## Checking it

```sh
cd web && pnpm run ux-check     # real Chrome as macOS / Windows / Android
node --test src/lib/ux/platform.test.ts
```

`ux-check` drives the mocked app (`shots/mock.mjs`): menus close on Esc and
outside click, a toggle does not reopen, a lightbox closes on Esc and on
Back without leaving the page and without a leftover history entry, ⌘/Ctrl
+Enter posts (the other modifier does not), `--tap-min` is 44/48. Its last
section lists what is still under 44px on Android — an inventory, not a
pass/fail.

## Not done, not known

- ⚠ **Material 3 text** could not be read (JS shell only). Bottom-bar
  placement is sukhi's own judgement, not a quoted guideline; HIG does not
  mention thumb reach either.
- ⚠ **Alt+← for back on Windows**, console button assignment (PlayStation,
  Nintendo) and `inputmode` / `enterkeyhint` details: no primary source read.
- **Windows forced-colours (High Contrast)** not checked at all.
- **Still under 44px on Android:** the legal footer links, names inside a
  notification sentence, two unlabelled 22px fields in settings.
- No settings UI for the platform override yet.
- Touch screens now carry larger controls (the notification "×" is a 48px
  circle). That is the cost of 48 dp; look at it.
- Consoles and Linux are not covered. `web-natadeco` is not covered.
