<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: MFM (Misskey Flavored Markdown)

- Kind: descriptive (what Misskey does), with a last section on how sukhi supports it. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `NoteText`, defined below

## In one paragraph

MFM is Misskey's own markup for note text. ActivityPub has no place for it, so Misskey sends the source text beside the HTML, in two properties that always travel together. It does so only when the text uses something beyond plain text, mentions, hashtags, URLs, and emoji. This page says when, what the HTML looks like, and how sukhi reads and writes it.

A note whose text has MFM, as Misskey sends it (type `NoteText`):
```json
{
  "content": "<p><b>Hello</b></p>",
  "_misskey_content": "**Hello**",
  "source": {
    "content": "**Hello**",
    "mediaType": "text/x.misskeymarkdown"
  }
}
```

A note with plain text carries neither property (type `NoteText`). It passes, because the type only says that the two come together:

```json
{
  "content": "<p>Hello</p>"
}
```

The type, written as JSDoc so the page can be read on its own (the checker compiles it):

```js
/**
 * The text of a Note. The two MFM properties come together or not at all.
 * @typedef {{content?: string} & (NoMfm | WithMfm)} NoteText
 *
 * @typedef {object} NoMfm
 * @property {undefined} [_misskey_content]
 * @property {undefined} [source]
 *
 * @typedef {object} WithMfm
 * @property {string} _misskey_content  MFM source text.
 * @property {{content: string, mediaType: 'text/x.misskeymarkdown'}} source
 */
```

## 1. The syntax

From the user documentation. **[src]** `misskey-hub.net/en/docs/for-users/features/mfm/` (the page lists syntax only; it says nothing about how other servers show MFM).

- Block: fenced code with an optional language, quote (`>`), center (`<center>`).
- Inline: mention (`@user`, `@user@host`), hashtag, URL, link `[text](url)` (a `?` before it hides the preview), custom emoji `:name:`, bold `**x**`, small `<small>`, inline code, plain `<plain>`, search.
- Functions, `$[name args content]`: `unixtime`, `ruby`, `flip`, `font`, `blur`, `fg`, `bg`, `border`, `rotate`, `position`, `scale`, `x2` `x3` `x4`, the animations `jelly` `tada` `jump` `bounce` `spin` `shake` `twitch`, `rainbow`, `sparkle`. Many take arguments, for example `$[fg.color=f00 text]`.

## 2. When Misskey sends the source

**[src]** `core/activitypub/ApMfmService.ts`, `getNoteHtml`

Misskey parses the note text with `mfm-js` and sets `noMisskeyContent` to true only when both hold:

1. there is no extra HTML to append (`extraHtml == null`), and
2. every top-level node of the parsed text is one of `text`, `unicodeEmoji`, `emojiCode`, `mention`, `hashtag`, `url`.

An empty text also gives true.

**[src]** `core/activitypub/ApRendererService.ts`, `renderNote`: when `noMisskeyContent` is true, `_misskey_content` and `source` are left out. Otherwise both are written.

What a receiver can conclude:

| What arrives | Meaning |
| --- | --- |
| `_misskey_content` and `source` present | The text uses at least one MFM node outside the six (bold, quote, code, a function, and so on), or Misskey added extra HTML. The `content` HTML is a lossy copy. |
| neither present | The text is plain text, mentions, hashtags, URLs, and emoji only. The `content` HTML is a complete copy. |

When `extraHtml` is set was **[not seen]** in these files. A quote is the likely case, but that is a guess.

## 3. Wire formats

| Property | Value | Notes |
| --- | --- | --- |
| `_misskey_content` | the MFM source as a string | term `misskey:_misskey_content` |
| `source` | `{ "content": "<source>", "mediaType": "text/x.misskeymarkdown" }` | the same text, in the AS2 `source` form |

When Misskey receives a note it takes text in this order. **[src]** `ApNoteService.ts`
1. `source`, if its `mediaType` is `text/x.misskeymarkdown` and `content` is a string;
2. `_misskey_content`;
3. `content`, converted from HTML to MFM by `htmlToMfm` using the note's tags.

So whatever text a server puts in `_misskey_content` is read by Misskey as MFM.

## 4. What other servers see: MFM to HTML

**[src]** `core/MfmService.ts`, `toHtml`. This is the `content` of a note from Misskey.

| MFM | HTML |
| --- | --- |
| bold | `<b>` |
| italic (`<i>`) | `<i>` |
| strike | `<del>` |
| small | `<small>` |
| center | `<div style="text-align: center;">` |
| quote | `<blockquote>` |
| inline code, inline math | `<code>` |
| code block, math block | `<pre><code>` |
| unicode emoji | the character |
| custom emoji `:name:` | `:name:` between zero-width spaces |
| plain | `<span>` |
| search | `<a>` to a Google search |
| URL | `<a>` with the URL as text |
| link | `<a>` (an invalid URL becomes `[text](url)`) |
| hashtag | `<a rel="tag">` to `<misskey>/tags/...` |
| mention | `<a class="u-url mention">`, no `rel`; the href is the remote user's `url`, then `uri`, else a local URL |
| `$[unixtime ...]` | `<time datetime=...>` |
| `$[ruby base reading]` | `<ruby>base<rp>(</rp><rt>reading</rt><rp>)</rp></ruby>` |
| any other function (`x2`, `fg`, `spin`, ...) | the content inside `<i>` |
| newline | `<br />` |

## 5. What Misskey makes of HTML: HTML to MFM

**[src]** `core/MfmService.ts`, `fromHtml`. Used when a note has no `source` and no `_misskey_content`.

- `<b>`, `<strong>` become `**`; `<s>`, `<del>` become `~~`; `<i>`, `<em>` and `<small>` stay as the MFM tags; `<code>` becomes backticks; `<pre><code>` becomes a fenced block; `<blockquote>` prefixes each line with `> `; `<h1>` becomes 【 】; `<p>` and `<h2>` to `<h6>` get a blank line before them; `<br>` becomes a newline.
- `<a>` whose text starts with `@` and whose `rel` does not start with `me ` is a mention. `@user` with an `href` gets the host from the `href`. A hashtag link is emitted bare when its text is among the note's hashtags. Other links become `[text](href)`.
- `<ruby>` becomes `$[ruby base reading]` when it is simple.
- Unknown tags pass their children through.

## 6. How sukhi handles it

### Receiving **[sukhi]**

- `Extract.extract_mfm/1` takes `_misskey_content` if it is a non-empty string, otherwise `source.content`. Note that it does not check `source.mediaType`. (`ap/instructions/extract.ex`)
- The text is stored in `notes.mfm` for notes, mirrored notes, and DMs. (`ap/instructions/mirror.ex`, `dms.ex`, `schema/note.ex`)
- On an edit of a mirrored note, `mfm` is extracted again. (`mirror.ex`)
- The Mastodon-compatible API passes the source through as an extra key `mfm`. Mastodon clients ignore it. (`api/.../views/mastodon_status.ex`)
- The web client shows `mfm` through `renderMfm` when it is present, and `content` otherwise. (`web/src/lib/components/Status.svelte`)

`renderMfm` (`web/src/lib/mfm.ts`) escapes the whole source first, then applies a static subset:
- kept: fenced code, `<center>`, quote lines, inline code, `<small>`, `<b>`, `<i>`, `<s>`, `**`, `__`, `*`, `_`, `~~`, `[label](http(s) url)`, bare http(s) URLs, mentions, hashtags, custom and unicode emoji;
- functions: every `$[name args content]` is replaced by its content, so motion and decoration are dropped. This is deliberate (calm UX);
- not handled: `<plain>`, `search`, math, and any `$[...]` meaning. `$[ruby 漢字 かな]` shows as `漢字 かな`; `$[unixtime 1700000000]` shows the number.

### Sending **[sukhi]**

- Every note carries `_misskey_content`, set to the author's raw text (the stored text with HTML escapes removed). (`notes/create.ex`, `fedi/builders.ex` `inject_misskey_content`)
- `content` is the HTML rendering of that text (`Note.html`).
- sukhi does not send `source`.

### Effects

1. Misskey reads sukhi's raw text as MFM. If a sukhi user writes `**x**`, `<center>`, or `$[spin x]`, Misskey will show bold, centered, or spinning text. If they write Markdown that MFM does not know (headings, lists), Misskey shows it as plain text.
2. sukhi sends the source even when it is plain text. Misskey's own rule (section 2) would leave it out. This is harmless but not needed.
3. A Misskey note whose text is plain has no `mfm` in sukhi, and the web client falls back to `content`, which is complete in that case.
4. A Misskey note with formatting is shown from the source, so formatting survives. A Mastodon client of sukhi sees the `content` HTML, where functions are italics (section 4).

### Suggested handling **[suggestion, not a statement about Misskey]**

Receive:
1. Keep storing the source verbatim and never put it in a page unescaped. Keep the escape-first order of `renderMfm`.
2. Check `source.mediaType` before using `source.content`, as Misskey does, so that a non-MFM `source` (for example Markdown from another server) is not taken as MFM.
3. Keep dropping motion functions. Add `ruby` and `unixtime` only if they can be done without an animation.
4. For a note with no source, use `content` unchanged.

Send:
1. Keep `_misskey_content` as the raw text.
2. Add `source` with `mediaType: "text/x.misskeymarkdown"`, which Misskey reads first and which names the format. FEP-style servers that know `source` get a labelled format.
3. Decide whether to omit both properties for text that has only the six plain node types, to match Misskey. It is optional.

## 7. Not researched

- The grammar of `mfm-js` (which text counts as which node).
- Whether `extraHtml` is set for quotes or other cases.
- How Misskey escapes a `$[` in text that is not meant as a function.
- Rendering of math in sukhi.
