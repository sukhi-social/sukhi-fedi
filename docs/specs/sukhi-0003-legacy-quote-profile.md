<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0003: Quote compatibility profile

- Status: Draft. Implemented in `fedi/builders.ex:347-364` and `ap/instructions/extract.ex:46-80`.
- Identifier: `https://sukhi.social/spec/sukhi-0003/1`
- Builds on: FEP-e232 (object links), FEP-044f (consent-respecting quotes).
- Type: `QuoteNote`, the three forms under "Sending" ([quote.md](misskey/quote.md) prints it).
- Terms, and what MUST / SHOULD / MAY mean: [README](README.md#how-to-read-the-specifications). Japanese: [README.ja.md](README.ja.md).

## In one paragraph

"This post quotes that post" is written differently by different servers. So when sending a quote, **write it in all three ways**, and when receiving, **accept any of them**. When the migration is over, remove the old ways one by one.

## The problem

There are at least four ways to write a quote.

| Way | Used by |
| --- | --- |
| `quoteUrl` | Misskey and its forks |
| `_misskey_quote` | Misskey and its forks |
| a `Link` inside `tag` (FEP-e232) | servers that implement FEP-e232 |
| `quote` (FEP-044f) | the newer form, read by Mastodon and others |

If you write only one, servers that do not read it show your post as an ordinary post, not as a quote. Misskey reads only the first two (`_misskey_quote` and `quoteUrl`). It reads neither a `tag` `Link` nor `quoteUri`. The standards do not say which ones to send or read while servers are moving from one to another.

## Sending

A quote post SHOULD carry all of the following, each set to the URL of the quoted post.

1. `quoteUrl`
2. `_misskey_quote`
3. A `tag` entry `{"type": "Link", "href": <url>, "rel": "_misskey_quote"}` (the FEP-e232 form)

When FEP-044f is implemented (not yet; see `FEDERATION.md` §11), the post SHOULD also carry `quote`. The `@context` terms it needs MUST be present **before** the object is signed. A term added afterwards is not covered by the signature.

## Reading

A reader SHOULD take the quoted URL from any of these:

`quoteUrl`, `quoteUri`, `_misskey_quote`, or a `tag` `Link` whose `rel` contains `_misskey_quote` or `e232`.

The reading MAY live in one function. sukhi does it that way. When FEP-044f is implemented, `quote` joins this list. The current code does not read it.

## Consent

The mechanism by which the quoted author agrees to be quoted (`QuoteRequest` and `QuoteAuthorization` of FEP-044f) is not handled yet. A quote of a post that has such a policy is shown as a "legacy" quote at servers that need the policy.

## When to remove each way

Each way SHOULD be removed once no server that sukhi federates with needs it. Removal is published as a new major version (`/2`) of this profile.
