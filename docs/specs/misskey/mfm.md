<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: MFM (Misskey Flavored Markdown)

- Kind: descriptive. It says what Misskey does and nothing about any other server. Source tags: [README](README.md).
- Subject: Misskey `develop`, read on 2026-10-23.
- Type: `NoteText`, defined below

## In one paragraph

MFM is Misskey's own markup for note text. ActivityPub has no place for it, so Misskey sends the source text beside the HTML, in two properties. It does so only when the text uses something beyond plain text, mentions, hashtags, URLs, and emoji. This page says when, what the HTML looks like, and how a server that reads it can use it.

A note whose text has MFM, as Misskey sends it (type `#NoteText`):
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

A note with plain text carries neither property (type `#NoteText`):
```json
{
  "content": "<p>Hello</p>"
}
```

The type, in [CUE](https://cuelang.org):

```cue
// The text of a Note. The two MFM properties come together, and say the
// same thing, or neither is present.
#NoteText: {
	content?:            string
	"_misskey_content"?: string
	source?: {
		content:   string
		mediaType: "text/x.misskeymarkdown"
		...
	}
	if source != _|_ {
		"_misskey_content": source.content
	}
	if source == _|_ {
		"_misskey_content"?: _|_
	}
	...
}
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

## 6. Not researched

- The grammar of `mfm-js` (which text counts as which node).
- Whether `extraHtml` is set for quotes or other cases.
- How Misskey escapes a `$[` in text that is not meant as a function.
