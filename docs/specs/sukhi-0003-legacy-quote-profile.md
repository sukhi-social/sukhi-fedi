<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-0003: Quote compatibility profile

- Status: Draft. Implemented in `fedi/builders.ex:347-364` and `ap/instructions/extract.ex:46-80`.
- Identifier: `https://sukhi.social/spec/sukhi-0003/1` (provisional).
- Builds on: FEP-e232 (object links), FEP-044f (consent-respecting quotes).

## 1. Problem

Servers write quotes in different ways: Misskey `quoteUrl` and `_misskey_quote`, a FEP-e232 link, and the newer FEP-044f `quote`. A sender that picks one is invisible to the others. The standards do not say which alias set a server sends or reads while the migration lasts.

## 2. Sending

A quote post SHOULD carry all of these, set to the quoted object URL, so that servers on either convention show it as a quote:

1. `quoteUrl`.
2. `_misskey_quote`.
3. A `tag` entry `{"type": "Link", "href": <url>, "rel": "_misskey_quote"}` (FEP-e232 form).

When FEP-044f is implemented (not yet; see `FEDERATION.md` §11), the post SHOULD also carry `quote`. The `@context` terms MUST be present before the object is signed, or the signature will not cover what is sent.

## 3. Reading

A reader SHOULD take the quoted URL from one of: `quoteUrl`, `quoteUri`, `_misskey_quote`, a `tag` Link whose `rel` contains `_misskey_quote` or `e232`. The reading MAY live in one function; sukhi does it that way. When FEP-044f is implemented, `quote` joins this list; the current code does not read it.

## 4. Consent

Until `QuoteRequest` and `QuoteAuthorization` are handled, a sender cannot honour an interaction policy. A quote of a post that has such a policy renders as "legacy" at receivers that need it.

## 5. End of life

Each alias SHOULD be removed once no server in the fediverse that sukhi federates with needs it. Removal is a new major version of this profile.
