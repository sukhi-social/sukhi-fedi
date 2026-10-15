# Fonts (subset, self-hosted)

These WOFF2 files are **subsets** of OFL-licensed fonts, containing only the
glyphs used by the legal pages (terms / privacy / licenses). They are embedded as base64
into the served HTML at compile time (see `SukhiFedi.Web.LegalController`) so
the pages make **no external font request** — a Google Fonts `<link>` would
leak the reader's IP, which is the wrong thing to do on a privacy page.

- `bizudpgothic.woff2` — BIZ UDPGothic (Japanese pages). © Morisawa Inc.
- `ibmplexsans-{regular,bold}.woff2` — IBM Plex Sans, Latin only (English
  /licenses page). © IBM Corp. Its license reserves the name "Plex", so these
  subsets are internally renamed "Sukhi Sans" (a subset is a modified version);
  copyright and license text are kept in the files. Made from google/fonts
  `ofl/ibmplexsans/IBMPlexSans[wdth,wght].ttf`: fontTools `instancer` at wght
  400 / 700 (wdth 100), `subset`, then the name table rewritten (IDs 1,2,3,4,6).
- `nanumgothic.woff2`  — Nanum Gothic (Korean pages). © NAVER Corp.

All under the SIL Open Font License 1.1 — see `*-OFL.txt`. Source TTFs:
github.com/google/fonts (ofl/bizudpgothic, ofl/nanumgothic). Re-subset with
`pyftsubset <ttf> --text-file=<chars> --flavor=woff2 --layout-features='*'`,
where `<chars>` is every character the rendered pages use (both flavors, all
languages) plus ASCII. Add a page, re-run this, or its new glyphs fall back to the
system font.
