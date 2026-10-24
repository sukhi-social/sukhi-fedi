<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Misskey: MFM (Misskey Flavored Markdown)

- Part of [the Misskey specification](README.md); source tags and terms are explained there.
- Type: `#Note`, defined in [objects](objects.md) (`_misskey_content` and `source` are two of its properties)

## In one paragraph

MFM is Misskey's own markup for note text. ActivityPub has no place for it, so Misskey sends the source text beside the HTML, in two properties that always come together. It does so only when the HTML would lose something: when the text uses more than plain text, mentions, hashtags, URLs, and emoji, or when Misskey appended extra HTML (a quote). A receiver that wants the formatting reads the source; one that does not reads `content`.

**Reading flow for a receiver.** Take the text of a note from the first of these that is present: `source.content` (only if `source.mediaType` is `text/x.misskeymarkdown`), `_misskey_content`, then `content` (HTML, converted to MFM). If neither MFM property is there, `content` is complete.

A note whose text has MFM (type `#Note`):
```json
{
  "id": "https://misskey.example/notes/9abc",
  "type": "Note",
  "attributedTo": "https://misskey.example/users/a1",
  "content": "<p><b>Hello</b></p>",
  "_misskey_content": "**Hello**",
  "source": {
    "content": "**Hello**",
    "mediaType": "text/x.misskeymarkdown"
  },
  "published": "2026-10-23T09:00:00.000Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1/followers"],
  "inReplyTo": null,
  "attachment": [],
  "sensitive": false,
  "tag": []
}
```

A note with plain text carries neither property (type `#Note`):
```json
{
  "id": "https://misskey.example/notes/9abd",
  "type": "Note",
  "attributedTo": "https://misskey.example/users/a1",
  "content": "<p>Hello</p>",
  "published": "2026-10-23T09:01:00.000Z",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://misskey.example/users/a1/followers"],
  "inReplyTo": null,
  "attachment": [],
  "sensitive": false,
  "tag": []
}
```

## 1. The syntax

From the user documentation. **[src]** `misskey-hub.net/en/docs/for-users/features/mfm/` (the page lists syntax only; it says nothing about how other servers show MFM).

- Block: fenced code with an optional language, quote (`>`), center (`<center>`).
- Inline: mention (`@user`, `@user@host`), hashtag, URL, link `[text](url)` (a `?` before it hides the preview), custom emoji `:name:`, bold `**x**`, small `<small>`, inline code, plain `<plain>`, search.
- Functions, `$[name args content]`: `unixtime`, `ruby`, `flip`, `font`, `blur`, `fg`, `bg`, `border`, `rotate`, `position`, `scale`, `x2` `x3` `x4`, the animations `jelly` `tada` `jump` `bounce` `spin` `shake` `twitch`, `rainbow`, `sparkle`. Many take arguments, for example `$[fg.color=f00 text]`.

## 2. When Misskey sends the source

**[src]** `core/activitypub/ApMfmService.ts`, `getNoteHtml`; `ApRendererService.ts`, `renderNote`

`renderNote` appends extra HTML only when the note quotes another: `<br><br><span class="quote-inline">RE: <a href="URI">URI</a></span>` ([quote](quote.md)). `getNoteHtml` then parses the note text with `mfm-js` and sets `noMisskeyContent` to true only when both hold:

1. there is no extra HTML to append, and
2. every top-level node of the parsed text is one of `text`, `unicodeEmoji`, `emojiCode`, `mention`, `hashtag`, `url`.

An empty text also gives true. When `noMisskeyContent` is true, `_misskey_content` and `source` are left out; otherwise both are written.

| What arrives | Meaning |
| --- | --- |
| `_misskey_content` and `source` present | The text uses at least one MFM node outside the six (bold, quote, code, a function, and so on), or the note quotes another. The `content` HTML is a lossy copy. |
| neither present | The text is plain text, mentions, hashtags, URLs, and emoji only, and the note quotes nothing. The `content` HTML is a complete copy. |

## 3. Reading the source

The two properties are typed in `#Note` ([objects](objects.md)): both present with the same text, or neither. The order in which Misskey takes the text of an incoming note is in the reading flow at the top. **[src]** `ApNoteService.ts`

Whatever text a server puts in `_misskey_content` is read by Misskey as MFM, so a server that sends it should send MFM.

## 4. The HTML Misskey writes: MFM to HTML

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

## 5. The HTML Misskey reads: HTML to MFM

**[src]** `core/MfmService.ts`, `fromHtml`. Used when a note has no `source` and no `_misskey_content`.

- `<b>`, `<strong>` become `**`; `<s>`, `<del>` become `~~`; `<i>`, `<em>` and `<small>` stay as the MFM tags; `<code>` becomes backticks; `<pre><code>` becomes a fenced block; `<blockquote>` prefixes each line with `> `; `<h1>` becomes 【 】; `<p>` and `<h2>` to `<h6>` get a blank line before them; `<br>` becomes a newline.
- `<a>` whose text starts with `@` and whose `rel` does not start with `me ` is a mention. `@user` with an `href` gets the host from the `href`. A hashtag link is emitted bare when its text is among the note's hashtags. Other links become `[text](href)`.
- `<ruby>` becomes `$[ruby base reading]` when it is simple.
- Unknown tags pass their children through.

## 6. Not researched

- The grammar of `mfm-js` (which text counts as which node).
- How Misskey escapes a `$[` in text that is not meant as a function.
