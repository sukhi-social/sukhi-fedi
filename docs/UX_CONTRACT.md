# UX contract — the web client

What the web client promises about *behaviour*, per platform. The visual
side (colour, shape, density) is `tokens.css`; this
page is the other half: what a press, a key, a back gesture does.

Two rules:

1. **Break nothing the browser and the OS already do.** Links are links,
   buttons are buttons, history works, selection and translation work.
   Most of "matching the platform" is not reimplementing it.
2. **Change only what is known to differ by platform**, and only where a
   primary source says so. Where we have no source, we do not claim a
   contract (⚠ below).

The code that kept this contract for the Svelte SPA (`web/src/lib/ux/`: one
Esc stack, `dismissable`, `useOverlay`, the platform hint, and
`pnpm run ux-check`) went with the SPA; `git log -- web/src/lib/ux` has it.
What web-next carries today:

| Where | Does |
|---|---|
| `public/js/app.js` | A coarse hint (mac / windows / android / ios / other) → `<html data-platform>`. |
| `public/css/tokens.css` `--tap-min` | The press-size default (44px; 48px under `html[data-platform='android']`). |

Esc, Back-closes-a-modal and the primary-modifier rule (B and C below) have
no handler of their own in web-next. Whether Unpoly's layers already do them
has **not been checked** against this contract.

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

→ Esc closes the top transient UI only. A modal adds one
shallow history entry when it opens (same URL), so the
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

Nothing runs this contract now: `ux-check` (real Chrome as macOS / Windows /
Android, driving the SPA's mocked app) and the platform unit test lived in
the SPA. A check for web-next would drive `web-next/mock/` the same way.

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

## 見える大きさと、押せる領域(指の画面)

人は見える形の真ん中を狙い、指は少し、決まった向きにずれて落ちる(Holz & Baudisch 2011 /
Henze ら 2011)。なので、`StatusActions` の chip は、見た目を 2rem に保ち、`::after` で
押せる領域を `--tap-min` まで広げる。WCAG 2.2 SC 2.5.8 の「対象」は操作を受ける領域で、
見えている絵ではない。

- 領域どうしは重ならない: 横は 見た目の幅 + gap ≥ `--tap-min`、縦は 見た目の高さ + 行の間 ≥ `--tap-min`。
- 六つが一列に入りきらないときは、溢れさせず次の行へ回る。
- `shots/ux-check.mjs` が、412 / 375 / 360px で、領域の大きさ・重なり・溢れを測る。
